#import "SPKStrings.h"
#import "SPKMediaFFmpeg.h"

#import "../../AssetUtils.h"
#import "../../Utils.h"
#import "../SPKResourceBundle.h"
#import "../UI/SPKMediaChrome.h"
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <objc/message.h>

static Class sSPKFFmpegKitClass = Nil;
static Class sSPKReturnCodeClass = Nil;
static BOOL sSPKFFmpegChecked = NO;
static BOOL sSPKFFmpegAvailable = NO;
static NSString *sSPKFFmpegLoadFailureSummary = nil;

static NSString *SPKFFmpegStringPref(NSString *key, NSString *fallback);
static NSInteger SPKFFmpegIntegerPref(NSString *key, NSInteger fallback);

static NSString *const kSPKFFmpegLogsDirectoryName = @"SparkleFFmpegLogs";

static NSString *SPKFFmpegDylibDirectory(void) {
    Dl_info info;
    if (dladdr((void *)SPKFFmpegDylibDirectory, &info) && info.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:info.dli_fname];
        return path.stringByDeletingLastPathComponent;
    }
    return nil;
}

static NSString *SPKFFmpegShellQuote(NSString *value) {
    if (value.length == 0) {
        return @"''";
    }
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    return [NSString stringWithFormat:@"'%@'", escaped];
}

static NSString *SPKFFmpegCommandStringFromArguments(NSArray<NSString *> *arguments) {
    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:arguments.count];
    for (NSString *argument in arguments) {
        if (argument.length == 0) {
            [parts addObject:@"''"];
        } else if ([argument hasPrefix:@"-"]) {
            [parts addObject:argument];
        } else {
            [parts addObject:SPKFFmpegShellQuote(argument)];
        }
    }
    return [parts componentsJoinedByString:@" "];
}

static NSInteger SPKFFmpegConfiguredVideoBitrateKbpsOrZero(void) {
    NSString *value = SPKFFmpegStringPref(@"downloads_encoding_vid_bitrate_kbps", @"");
    NSInteger parsed = value.integerValue;
    return parsed > 0 ? parsed : 0;
}

static NSInteger SPKFFmpegAdvancedDefaultBitrateKbps(NSInteger sourceBitrate) {
    if (sourceBitrate > 0) {
        NSInteger kbps = sourceBitrate / 1000;
        if (kbps < 2500)
            kbps = 2500;
        if (kbps > 50000)
            kbps = 50000;
        return kbps;
    }
    return 8000;
}

// VideoToolbox needs roughly twice libx264's bitrate for the same picture: at
// the source bitrate it scores ~70 VMAF where libx264 scores ~90, and doubling
// it closes the gap. An automatic target is scaled accordingly; a bitrate the
// user typed is used as is.
static NSInteger SPKFFmpegAdvancedTargetBitrateKbps(NSInteger sourceBitrate, BOOL videoToolbox) {
    NSInteger configured = SPKFFmpegConfiguredVideoBitrateKbpsOrZero();
    if (configured > 0) {
        return configured;
    }
    NSInteger automatic = SPKFFmpegAdvancedDefaultBitrateKbps(sourceBitrate);
    return videoToolbox ? MIN(automatic * 2, 50000) : automatic;
}

// libx264 rejects CRF values above 51 and treats 0 as lossless, which the field
// never means; anything outside 1...51 falls back to bitrate mode.
static NSString *SPKFFmpegConfiguredCRFOrNil(void) {
    NSInteger crf = SPKFFmpegStringPref(@"downloads_encoding_crf", @"").integerValue;
    return crf > 0 ? [NSString stringWithFormat:@"%ld", (long)MIN(crf, 51)] : nil;
}

// Max Resolution names the picture's shorter side, as in "720p": a vertical
// 1080x1920 reel at 720 becomes 720x1280. It only ever downscales. Sizing both
// axes to at least N with the aspect ratio kept puts the shorter side at N
// without knowing the orientation, so a crop's quarter turn is handled too.
static NSString *SPKFFmpegMaxResolutionScaleFilter(NSInteger width, NSInteger height) {
    NSString *maxResolution = SPKFFmpegStringPref(@"downloads_encoding_max_resolution", @"original");
    NSInteger target = [maxResolution isEqualToString:@"original"] ? 0 : MAX(maxResolution.integerValue, 0);
    if (target <= 0 || width <= 0 || height <= 0 || MIN(width, height) <= target) {
        return nil;
    }
    return [NSString stringWithFormat:@"scale=%ld:%ld:force_original_aspect_ratio=increase:force_divisible_by=2",
                                      (long)target, (long)target];
}

// Audio bitrate and channel layout only apply with Advanced Encoding on; with
// it off, re-encoded audio uses the defaults the page shows.
static NSInteger SPKFFmpegAudioBitrateKbps(void) {
    if (![SPKUtils getBoolPref:@"downloads_adv_encoding"]) {
        return 128;
    }
    return SPKFFmpegIntegerPref(@"downloads_encoding_audio_bitrate_kbps", 128);
}

static void SPKFFmpegAppendAudioChannelOptions(NSMutableArray<NSString *> *args) {
    if (![SPKUtils getBoolPref:@"downloads_adv_encoding"]) {
        return;
    }
    NSString *channels = SPKFFmpegStringPref(@"downloads_encoding_audio_channels", @"original").lowercaseString;
    if ([channels isEqualToString:@"mono"]) {
        [args addObjectsFromArray:@[ @"-ac", @"1" ]];
    } else if ([channels isEqualToString:@"stereo"]) {
        [args addObjectsFromArray:@[ @"-ac", @"2" ]];
    }
}

static NSString *SPKFFmpegLogsDirectoryPath(void) {
    NSArray<NSURL *> *cacheURLs = [[NSFileManager defaultManager] URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
    NSURL *baseURL = cacheURLs.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSURL *logsURL = [baseURL URLByAppendingPathComponent:kSPKFFmpegLogsDirectoryName isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:logsURL withIntermediateDirectories:YES attributes:nil error:nil];
    return logsURL.path;
}

static NSArray<NSString *> *SPKFFmpegSortedLogFiles(void) {
    return [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:SPKFFmpegLogsDirectoryPath() error:nil] ?: @[]
        sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

static NSString *SPKFFmpegCombinedLogsString(void) {
    NSMutableString *body = [NSMutableString string];
    for (NSString *file in SPKFFmpegSortedLogFiles().reverseObjectEnumerator) {
        NSString *path = [SPKFFmpegLogsDirectoryPath() stringByAppendingPathComponent:file];
        NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (content.length == 0) {
            continue;
        }
        if (body.length > 0) {
            [body appendString:@"\n\n====================\n\n"];
        }
        [body appendFormat:@"File: %@\n\n%@", file, content];
    }
    return body.copy;
}

static NSString *SPKFFmpegExportLogsFile(void) {
    NSString *body = SPKFFmpegCombinedLogsString();
    if (body.length == 0) {
        return nil;
    }
    NSString *exportPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"Sparkle-FFmpeg-Logs.txt"];
    [body writeToFile:exportPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return exportPath;
}

static void SPKFFmpegPersistCommandLog(NSString *identifier, NSString *status, NSString *command, NSString *details) {
    NSString *logsPath = SPKFFmpegLogsDirectoryPath();
    if (logsPath.length == 0) {
        return;
    }

    NSDate *now = [NSDate date];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *timestamp = [formatter stringFromDate:now];
    NSString *safeIdentifier = identifier.length > 0 ? identifier : @"session";
    NSString *safeStatus = status.length > 0 ? status : @"info";
    NSString *fileName = [NSString stringWithFormat:@"%@_%@.txt", timestamp, safeIdentifier];
    NSString *path = [logsPath stringByAppendingPathComponent:fileName];

    NSMutableString *body = [NSMutableString string];
    [body appendFormat:@"Identifier: %@\n", safeIdentifier];
    [body appendFormat:@"Status: %@\n", safeStatus];
    [body appendFormat:@"Date: %@\n\n", [timestamp stringByReplacingOccurrencesOfString:@"_" withString:@" "]];
    if (command.length > 0) {
        [body appendFormat:@"Command:\n%@\n\n", command];
    }
    if (details.length > 0) {
        [body appendFormat:@"Output:\n%@\n", details];
    }
    [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static void SPKFFmpegPersistErrorLog(NSString *identifier, NSString *command, NSString *details) {
    SPKFFmpegPersistCommandLog(identifier, @"failure", command, details);
}

static void SPKFFmpegPersistLoaderFailure(NSArray<NSString *> *details) {
    if (details.count == 0) {
        return;
    }
    sSPKFFmpegLoadFailureSummary = [details componentsJoinedByString:@"\n"];
    SPKFFmpegPersistErrorLog(@"loader", @"dlopen ffmpegkit", sSPKFFmpegLoadFailureSummary);
}

// The FFmpeg frameworks are staged under Sparkle's own names because Instagram
// vendors its own libavutil and libavcodec, and anything sharing those names in
// the app's Frameworks directory would replace them. Dependency order matters:
// each library is opened before the ones that link against it.
static NSArray<NSString *> *SPKFFmpegLibraryNames(void) {
    return @[
        @"spk.avutil",
        @"spk.swresample",
        @"spk.swscale",
        @"spk.avcodec",
        @"spk.avformat",
        @"spk.avfilter",
        @"spk.avdevice"
    ];
}

// Sideload packages keep the frameworks in the app's Frameworks directory,
// which is the only location a sideload signer re-signs. Jailbreak packages
// keep them beside the tweak's resources. Both layouts hold the frameworks as
// siblings, so only the containing directory differs.
static NSArray<NSString *> *SPKFFmpegCandidateRoots(void) {
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    NSString *appFrameworks = [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"Frameworks"];
    if (appFrameworks.length > 0) {
        [roots addObject:appFrameworks];
    }
    NSString *bundled = SPKResourcePath(@"");
    if (bundled.length > 0 && ![roots containsObject:bundled]) {
        [roots addObject:bundled];
    }
    return roots;
}

static NSString *SPKFFmpegBinaryPathInRoot(NSString *root, NSString *library) {
    NSString *framework = [library stringByAppendingPathExtension:@"framework"];
    return [[root stringByAppendingPathComponent:framework] stringByAppendingPathComponent:library];
}

static NSArray<NSString *> *SPKFFmpegPreloadSiblingLibraries(NSString *root) {
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    for (NSString *library in SPKFFmpegLibraryNames()) {
        NSString *path = SPKFFmpegBinaryPathInRoot(root, library);
        if (![fileManager fileExistsAtPath:path]) {
            [errors addObject:[NSString stringWithFormat:@"Missing sibling: %@", path]];
            continue;
        }
        void *handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            const char *dlError = dlerror();
            [errors addObject:[NSString stringWithFormat:@"dlopen failed for sibling %@\n%s", library, dlError ?: "unknown"]];
        }
    }
    return errors;
}

static void SPKFFmpegEnsureLoaded(void) {
    if (sSPKFFmpegChecked) {
        return;
    }
    sSPKFFmpegChecked = YES;

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *errors = [NSMutableArray array];
    for (NSString *root in SPKFFmpegCandidateRoots()) {
        NSString *candidate = SPKFFmpegBinaryPathInRoot(root, @"spk.ffmpegkit");
        if (![fileManager fileExistsAtPath:candidate]) {
            [errors addObject:[NSString stringWithFormat:@"Missing: %@", candidate]];
            continue;
        }

        NSArray<NSString *> *siblingErrors = SPKFFmpegPreloadSiblingLibraries(root);
        if (siblingErrors.count > 0) {
            [errors addObjectsFromArray:siblingErrors];
            continue; // Stop trying this root if its siblings fail
        }
        void *handle = dlopen(candidate.UTF8String, RTLD_NOW | RTLD_GLOBAL);
        if (!handle) {
            const char *dlError = dlerror();
            [errors addObject:[NSString stringWithFormat:@"dlopen failed for %@\n%s", candidate.lastPathComponent, dlError ?: "unknown"]];
            continue;
        }

        sSPKFFmpegKitClass = NSClassFromString(@"FFmpegKit");
        sSPKReturnCodeClass = NSClassFromString(@"ReturnCode");
        if (sSPKFFmpegKitClass && sSPKReturnCodeClass) {
            sSPKFFmpegAvailable = YES;
            return;
        }
        [errors addObject:[NSString stringWithFormat:@"Loaded %@ but FFmpegKit classes were unavailable", candidate.lastPathComponent]];
    }

    SPKFFmpegPersistLoaderFailure(errors);
}

static NSString *SPKFFmpegStringPref(NSString *key, NSString *fallback) {
    NSString *value = [SPKUtils getStringPref:key];
    return value.length > 0 ? value : fallback;
}

static NSInteger SPKFFmpegIntegerPref(NSString *key, NSInteger fallback) {
    NSString *stringValue = [SPKUtils getStringPref:key];
    if (stringValue.length > 0) {
        NSInteger parsed = stringValue.integerValue;
        if (parsed > 0) {
            return parsed;
        }
    }
    return fallback;
}

// Maps the user-facing speed setting to an x264 preset name.
static NSString *SPKFFmpegPresetForSpeed(NSString *speed) {
    NSDictionary<NSString *, NSString *> *map = @{
        @"ultrafast" : @"ultrafast",
        @"superfast" : @"superfast",
        @"veryfast" : @"veryfast",
        @"faster" : @"faster",
        @"fast" : @"faster", // "fast" is a UI alias for "faster"
        @"medium" : @"medium",
        @"slow" : @"slow",
        @"slower" : @"slower",
        @"veryslow" : @"veryslow",
    };
    NSString *preset = map[speed];
    return preset.length > 0 ? preset : @"medium";
}

// Minimum/maximum ABR target for the default re-encode, in bits/sec. Mirrors the
// clamp SPKFFmpegAdvancedDefaultBitrateKbps applies in the advanced path (2500 –
// 50000 kbps).
static const NSInteger kSPKFFmpegDefaultMinVideoBitrate = 2500000;
static const NSInteger kSPKFFmpegDefaultMaxVideoBitrate = 50000000;

// Rate-control tokens for the default (non-advanced) encoder. When the source
// bitrate is known, target it with single-pass ABR (bitrate-capped) so the
// re-encode lands close to the source's — and therefore the sheet's estimated —
// size. Without this, libx264's implicit CRF 23 chases the source's detail and
// balloons an already-compressed rep (e.g. a ~100 kbps AV1 tier) into a
// multi-megabyte H.264 file.
//
// The target is FLOORED at 2.5 Mbps (and capped at 50 Mbps), matching the
// advanced path. IG serves videos as AV1/HEVC, whose manifest bandwidth
// can be far below what H.264 needs for equal quality. The floor keeps such reps watchable while leaving the
// common case (a healthy multi-Mbps manifest) exactly as before. `sourceBitrate`
// is the manifest bandwidth (bits/sec); 0 falls back to plain CRF. Encoding
// effort still comes from the "Encoding speed" preset, applied by the caller.
static NSArray<NSString *> *SPKFFmpegRateControlTokens(NSInteger sourceBitrate) {
    if (sourceBitrate <= 0) {
        return @[ @"-crf", @"23" ];
    }
    NSInteger target = MIN(MAX(sourceBitrate, kSPKFFmpegDefaultMinVideoBitrate),
                           kSPKFFmpegDefaultMaxVideoBitrate);
    NSInteger maxrate = (NSInteger)llround(target * 1.2);
    return @[
        @"-b:v", [NSString stringWithFormat:@"%ld", (long)target],
        @"-maxrate", [NSString stringWithFormat:@"%ld", (long)maxrate],
        @"-bufsize", [NSString stringWithFormat:@"%ld", (long)(target * 2)]
    ];
}

// Default DASH merge command — software libx264 with preset-driven effort and CRF rate control
//
// `-movflags +faststart` is deliberately omitted. Long libx264 encodes (preset
// slow/slower) on iOS reliably trigger an FFmpeg muxer error during the
// in-place "second pass" that relocates the moov atom:
//
//   [mp4] Starting second pass: moving the moov atom to the beginning of the file
//   [mp4] Unable to re-open <path> output file for shifting data
//   [out#0/mp4] Error writing trailer: No such file or directory
//
// Faststart is instead handled by a separate stream-copy pass driven by the
// merge attempts orchestrator (see `SPKFFmpegFaststartArguments`).
static NSString *SPKFFmpegDefaultMergeCommand(NSURL *videoFileURL,
                                              NSURL *audioFileURL,
                                              NSURL *outputURL,
                                              NSInteger width,
                                              NSInteger height,
                                              NSInteger sourceBitrate) {
    (void)width;
    (void)height;

    NSString *speed = SPKFFmpegStringPref(@"downloads_encoding_speed", @"medium");
    NSString *preset = SPKFFmpegPresetForSpeed(speed);

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithArray:@[
        @"-y",
        @"-hide_banner",
        @"-analyzeduration 100M",
        @"-probesize 100M",
        @"-fflags +genpts",
    ]];

    if (audioFileURL) {
        [parts addObject:[NSString stringWithFormat:@"-i '%@' -i '%@'", videoFileURL.path, audioFileURL.path]];
        [parts addObject:@"-map 0:v:0 -map 1:a:0"];
    } else {
        [parts addObject:[NSString stringWithFormat:@"-i '%@'", videoFileURL.path]];
        [parts addObject:@"-map 0:v:0"];
    }

    [parts addObjectsFromArray:@[
        @"-c:v libx264",
        [NSString stringWithFormat:@"-preset %@", preset],
        @"-pix_fmt yuv420p",
        @"-profile:v main",
        @"-level 4.0",
    ]];
    [parts addObject:[SPKFFmpegRateControlTokens(sourceBitrate)
                         componentsJoinedByString:@" "]];
    if (audioFileURL) {
        // Audio is stream-copied. The merge entry point pre-converts xHE-AAC
        // sources to AAC-LC via AVFoundation before getting here, so a copy is
        // safe; FFmpeg never decodes the audio.
        //
        // No `-shortest`: libx264 has a multi-second lookahead at slow presets
        // (rc_lookahead=60 + B-frame reorder ≈ 2s). With `-c:a copy` (no
        // encoder pipeline) the muxer would EOF on audio and discard the
        // still-in-flight encoded video tail. DASH inputs are always within
        // ~tens of ms, so output duration stays correct without it.
        [parts addObject:@"-c:a copy"];
    } else {
        [parts addObject:@"-an"];
    }

    [parts addObject:[NSString stringWithFormat:@"'%@'", outputURL.path]];

    return [parts componentsJoinedByString:@" "];
}

// Array form of the default merge command, used by the normalization fallback
// retries. Mirrors SPKFFmpegDefaultMergeCommand exactly so the behavior stays
// consistent across the primary attempt and the two normalized retries.
static NSArray<NSString *> *SPKFFmpegDefaultMergeArguments(NSURL *videoFileURL,
                                                           NSURL *audioFileURL,
                                                           NSURL *outputURL,
                                                           NSString *extraVideoFilter,
                                                           NSInteger sourceBitrate) {
    NSString *speed = SPKFFmpegStringPref(@"downloads_encoding_speed", @"medium");
    NSString *preset = SPKFFmpegPresetForSpeed(speed);

    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-y",
        @"-hide_banner",
        @"-analyzeduration",
        @"100M",
        @"-probesize",
        @"100M",
        @"-fflags",
        @"+genpts",
        @"-i",
        videoFileURL.path,
    ]];

    if (audioFileURL) {
        [args addObjectsFromArray:@[ @"-i", audioFileURL.path ]];
        [args addObjectsFromArray:@[ @"-map", @"0:v:0", @"-map", @"1:a:0" ]];
    } else {
        [args addObjectsFromArray:@[ @"-map", @"0:v:0", @"-an" ]];
    }

    if (extraVideoFilter.length > 0) {
        [args addObjectsFromArray:@[ @"-vf", extraVideoFilter ]];
    }

    [args addObjectsFromArray:@[
        @"-c:v",
        @"libx264",
        @"-preset",
        preset,
        @"-pix_fmt",
        @"yuv420p",
        @"-profile:v",
        @"main",
        @"-level",
        @"4.0",
    ]];
    [args addObjectsFromArray:SPKFFmpegRateControlTokens(sourceBitrate)];

    if (audioFileURL) {
        // See SPKFFmpegDefaultMergeCommand for the audio/no-`-shortest` rationale.
        [args addObjectsFromArray:@[ @"-c:a", @"copy" ]];
    }

    // Faststart is intentionally NOT applied here — it is performed by a
    // separate stream-copy pass (SPKFFmpegFaststartArguments) to avoid the
    // in-place moov-relocation reopen failing on long iOS encodes.
    [args addObject:outputURL.path];
    return args;
}

// Advanced DASH merge arguments. Audio is always copied for DASH merges.
static NSArray<NSString *> *SPKFFmpegAdvancedMergeArguments(NSURL *videoFileURL,
                                                            NSURL *audioFileURL,
                                                            NSURL *outputURL,
                                                            NSInteger width,
                                                            NSInteger height,
                                                            NSInteger sourceBitrate,
                                                            BOOL copyAudio,
                                                            NSString *codecOverride,
                                                            NSString *extraVideoFilter) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-analyzeduration",
        @"100M",
        @"-probesize",
        @"100M",
        @"-fflags",
        @"+genpts",
        @"-i",
        videoFileURL.path,
    ]];

    if (audioFileURL) {
        [args addObjectsFromArray:@[ @"-i", audioFileURL.path ]];
        [args addObjectsFromArray:@[ @"-map", @"0:v:0", @"-map", @"1:a:0" ]];
    } else {
        [args addObjectsFromArray:@[ @"-map", @"0:v:0", @"-an" ]];
    }

    // Optional scale filter
    NSString *scaleFilter = SPKFFmpegMaxResolutionScaleFilter(width, height);
    if (scaleFilter.length > 0) {
        NSString *combined = extraVideoFilter.length > 0 ? [NSString stringWithFormat:@"%@,%@", scaleFilter, extraVideoFilter] : scaleFilter;
        [args addObjectsFromArray:@[ @"-vf", combined ]];
    } else if (extraVideoFilter.length > 0) {
        [args addObjectsFromArray:@[ @"-vf", extraVideoFilter ]];
    }

    // Advanced DASH merge path respects the selected video codec.
    NSString *selectedCodec = codecOverride.length > 0 ? codecOverride : SPKFFmpegStringPref(@"downloads_encoding_vid_codec", @"libx264");
    BOOL isLibx264 = [selectedCodec isEqualToString:@"libx264"];
    NSInteger targetBitrate = SPKFFmpegAdvancedTargetBitrateKbps(sourceBitrate, !isLibx264);

    if (isLibx264) {
        NSString *preset = SPKFFmpegStringPref(@"downloads_encoding_preset", @"medium");
        NSString *profile = SPKFFmpegStringPref(@"downloads_encoding_h264_profile", @"high");
        NSString *level = SPKFFmpegStringPref(@"downloads_encoding_h264_level", @"auto");
        NSString *crf = SPKFFmpegConfiguredCRFOrNil();

        [args addObjectsFromArray:@[
            @"-c:v",
            @"libx264",
            @"-preset",
            SPKFFmpegPresetForSpeed(preset),
        ]];

        if (crf) {
            [args addObjectsFromArray:@[ @"-crf", crf ]];
        } else {
            [args addObjectsFromArray:@[ @"-b:v", [NSString stringWithFormat:@"%ldk", (long)targetBitrate] ]];
        }

        if (profile.length > 0 && ![profile isEqualToString:@"auto"]) {
            [args addObjectsFromArray:@[ @"-profile:v", profile ]];
        }
        if (level.length > 0 && ![level isEqualToString:@"auto"]) {
            [args addObjectsFromArray:@[ @"-level", level ]];
        }
    } else {
        [args addObjectsFromArray:@[
            @"-c:v",
            @"h264_videotoolbox",
            @"-b:v",
            [NSString stringWithFormat:@"%ldk", (long)targetBitrate],
        ]];
    }

    // Always 8-bit 4:2:0: every H.264 profile offered is 8-bit, so passing a
    // 10-bit HDR source's format through makes libx264 refuse to start.
    [args addObjectsFromArray:@[ @"-pix_fmt", @"yuv420p" ]];

    // Faststart is handled by a follow-up stream-copy pass; see
    // SPKFFmpegFaststartArguments and the merge orchestrator. Doing the moov
    // relocation in-place can fail on slow encodes inside the iOS sandbox.

    // Audio
    if (audioFileURL) {
        (void)copyAudio;
        // See SPKFFmpegDefaultMergeCommand for the audio/no-`-shortest` rationale.
        [args addObjectsFromArray:@[ @"-c:a", @"copy" ]];
    }

    [args addObject:outputURL.path];
    return args;
}

static NSArray<NSString *> *SPKFFmpegNormalizationArguments(NSURL *videoFileURL, NSURL *normalizedVideoURL) {
    return @[
        @"-y",
        @"-hide_banner",
        @"-analyzeduration", @"100M",
        @"-probesize", @"100M",
        @"-fflags", @"+genpts",
        @"-i", videoFileURL.path,
        @"-map", @"0:v:0",
        @"-c", @"copy",
        @"-movflags", @"+faststart",
        normalizedVideoURL.path
    ];
}

// Stream-copy faststart relocate: takes a freshly encoded MP4 and writes a new
// MP4 with the moov atom shifted to the front. Cheap (just a remux) and avoids
// FFmpeg's in-place reopen, which is unreliable for long encodes inside the
// iOS sandbox.
static NSArray<NSString *> *SPKFFmpegFaststartArguments(NSURL *sourceURL, NSURL *outputURL) {
    return @[
        @"-y",
        @"-hide_banner",
        @"-i", sourceURL.path,
        @"-c", @"copy",
        @"-map", @"0",
        @"-movflags", @"+faststart",
        outputURL.path
    ];
}

static NSArray<NSString *> *SPKFFmpegAudioReencodeArguments(NSURL *sourceURL, NSURL *outputURL) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-y",
        @"-hide_banner",
        @"-loglevel", @"warning",
        @"-i", sourceURL.path,
        @"-vn",
        @"-c:a", @"aac"
    ]];

    [args addObjectsFromArray:@[ @"-b:a", [NSString stringWithFormat:@"%ldk", (long)SPKFFmpegAudioBitrateKbps()] ]];
    SPKFFmpegAppendAudioChannelOptions(args);

    [args addObject:outputURL.path];
    return args;
}

typedef NS_ENUM(NSInteger, SPKFFmpegTrimAudioMode) {
    SPKFFmpegTrimAudioAAC = 0,  // re-encode to AAC (normal case)
    SPKFFmpegTrimAudioCopy = 1, // stream-copy (xHE-AAC / undecodable sources)
    SPKFFmpegTrimAudioNone = 2, // drop audio (last-resort fallback)
};

// Appends the audio encoder options for a trim attempt, honoring the configured
// bitrate and channel layout in AAC mode.
static void SPKFFmpegAppendTrimAudioOptions(NSMutableArray<NSString *> *args, SPKFFmpegTrimAudioMode audioMode) {
    if (audioMode == SPKFFmpegTrimAudioCopy) {
        [args addObjectsFromArray:@[ @"-c:a", @"copy" ]];
        return;
    }
    if (audioMode != SPKFFmpegTrimAudioAAC) {
        return; // None: video-only, no audio options.
    }
    [args addObjectsFromArray:@[ @"-c:a", @"aac" ]];
    [args addObjectsFromArray:@[ @"-b:a", [NSString stringWithFormat:@"%ldk", (long)SPKFFmpegAudioBitrateKbps()] ]];
    SPKFFmpegAppendAudioChannelOptions(args);
}

// Appends the video encoder options honoring the user's encoding settings: the
// default path mirrors the default merge (libx264 + speed preset); advanced mode
// mirrors the advanced merge's codec/CRF/bitrate/profile/level/pixel-format/
// max-resolution options. Shared by the single-input trim and the DASH
// trim+merge so both respect the same settings.
// `leadingVideoFilter` runs before everything else in the -vf chain: it is the
// framing edit (crop / transpose / hflip), which has to happen before any
// max-resolution scale so the scale applies to the cropped picture.
static void SPKFFmpegAppendVideoEncodeOptions(NSMutableArray<NSString *> *args,
                                              NSInteger width,
                                              NSInteger height,
                                              NSInteger sourceBitrate,
                                              NSString *leadingVideoFilter,
                                              NSString *extraVideoFilter) {
    BOOL useAdvanced = [SPKUtils getBoolPref:@"downloads_adv_encoding"];

    if (!useAdvanced) {
        NSString *preset = SPKFFmpegPresetForSpeed(SPKFFmpegStringPref(@"downloads_encoding_speed", @"medium"));
        [args addObjectsFromArray:@[
            @"-c:v",
            @"libx264",
            @"-preset",
            preset,
            @"-pix_fmt",
            @"yuv420p",
            @"-profile:v",
            @"main",
            @"-level",
            @"4.0",
        ]];
        NSMutableArray<NSString *> *basicFilters = [NSMutableArray array];
        if (leadingVideoFilter.length > 0) {
            [basicFilters addObject:leadingVideoFilter];
        }
        if (extraVideoFilter.length > 0) {
            [basicFilters addObject:extraVideoFilter];
        }
        if (basicFilters.count > 0) {
            [args addObjectsFromArray:@[ @"-vf", [basicFilters componentsJoinedByString:@","] ]];
        }
        return;
    }

    // Collect video filters (max-resolution scale + any caller-supplied filter,
    // e.g. a setpts re-stamp) into a single -vf chain.
    NSMutableArray<NSString *> *videoFilters = [NSMutableArray array];
    if (leadingVideoFilter.length > 0) {
        [videoFilters addObject:leadingVideoFilter];
    }
    NSString *scaleFilter = SPKFFmpegMaxResolutionScaleFilter(width, height);
    if (scaleFilter.length > 0) {
        [videoFilters addObject:scaleFilter];
    }
    if (extraVideoFilter.length > 0) {
        [videoFilters addObject:extraVideoFilter];
    }
    if (videoFilters.count > 0) {
        [args addObjectsFromArray:@[ @"-vf", [videoFilters componentsJoinedByString:@","] ]];
    }

    NSString *selectedCodec = SPKFFmpegStringPref(@"downloads_encoding_vid_codec", @"libx264");
    BOOL isLibx264 = [selectedCodec isEqualToString:@"libx264"];
    NSInteger targetBitrate = SPKFFmpegAdvancedTargetBitrateKbps(sourceBitrate, !isLibx264);

    if (isLibx264) {
        NSString *preset = SPKFFmpegStringPref(@"downloads_encoding_preset", @"medium");
        NSString *profile = SPKFFmpegStringPref(@"downloads_encoding_h264_profile", @"high");
        NSString *level = SPKFFmpegStringPref(@"downloads_encoding_h264_level", @"auto");
        NSString *crf = SPKFFmpegConfiguredCRFOrNil();

        [args addObjectsFromArray:@[ @"-c:v", @"libx264", @"-preset", SPKFFmpegPresetForSpeed(preset) ]];
        if (crf) {
            [args addObjectsFromArray:@[ @"-crf", crf ]];
        } else {
            [args addObjectsFromArray:@[ @"-b:v", [NSString stringWithFormat:@"%ldk", (long)targetBitrate] ]];
        }
        if (profile.length > 0 && ![profile isEqualToString:@"auto"]) {
            [args addObjectsFromArray:@[ @"-profile:v", profile ]];
        }
        if (level.length > 0 && ![level isEqualToString:@"auto"]) {
            [args addObjectsFromArray:@[ @"-level", level ]];
        }
    } else {
        [args addObjectsFromArray:@[ @"-c:v", @"h264_videotoolbox", @"-b:v", [NSString stringWithFormat:@"%ldk", (long)targetBitrate] ]];
    }

    // See SPKFFmpegAdvancedMergeArguments: always 8-bit 4:2:0.
    [args addObjectsFromArray:@[ @"-pix_fmt", @"yuv420p" ]];
}

// Frame-accurate trim encode of a single (already-muxed) input. `-ss`/`-t` are
// placed AFTER `-i` (output seek): FFmpeg decodes from the start and re-times the
// output cleanly from PTS 0, so the first output frame is a real frame at t=0.
// (Input seek — `-ss` before `-i` — plus `-avoid_negative_ts make_zero` shifted
// the whole timeline by the AAC encoder-priming delay, which AVFoundation renders
// as a blank first frame. Output seek avoids the shift entirely; the priming
// stays a harmless audio-only edit list. Decoding from 0 is negligibly slower for
// the short clips this handles.)
static NSArray<NSString *> *SPKFFmpegTrimArguments(NSURL *videoFileURL,
                                                   NSURL *outputURL,
                                                   NSTimeInterval startSeconds,
                                                   NSTimeInterval durationSeconds,
                                                   NSInteger width,
                                                   NSInteger height,
                                                   NSInteger sourceBitrate,
                                                   NSString *cropFilter,
                                                   SPKFFmpegTrimAudioMode audioMode) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-y",
        @"-hide_banner",
        @"-i",
        videoFileURL.path,
        @"-ss",
        [NSString stringWithFormat:@"%.3f", MAX(0.0, startSeconds)],
        @"-t",
        [NSString stringWithFormat:@"%.3f", MAX(0.0, durationSeconds)],
    ]];

    if (audioMode == SPKFFmpegTrimAudioNone) {
        [args addObjectsFromArray:@[ @"-map", @"0:v:0", @"-an" ]];
    } else {
        [args addObjectsFromArray:@[ @"-map", @"0:v:0", @"-map", @"0:a:0" ]];
    }

    SPKFFmpegAppendVideoEncodeOptions(args, width, height, sourceBitrate, cropFilter, nil);
    SPKFFmpegAppendTrimAudioOptions(args, audioMode);
    [args addObject:outputURL.path];
    return args;
}

// Single-pass trim + merge of a separate video and audio stream (both already
// downloaded to local files — the bundled FFmpeg has no TLS). `-ss`/`-t` go
// AFTER the inputs (output seek) so the merged output re-times cleanly from PTS
// 0 with a real first frame, instead of the input-seek + `-avoid_negative_ts
// make_zero` path that shifted the timeline by the AAC priming delay (blank first
// frame). Audio is always re-encoded to AAC.
static NSArray<NSString *> *SPKFFmpegTrimMergeArguments(NSString *videoSource,
                                                        NSString *audioSource,
                                                        NSURL *outputURL,
                                                        NSTimeInterval startSeconds,
                                                        NSTimeInterval durationSeconds,
                                                        NSInteger width,
                                                        NSInteger height,
                                                        NSString *cropFilter) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-y",
        @"-hide_banner",
        @"-i",
        videoSource,
        @"-i",
        audioSource,
        @"-ss",
        [NSString stringWithFormat:@"%.3f", MAX(0.0, startSeconds)],
        @"-t",
        [NSString stringWithFormat:@"%.3f", MAX(0.0, durationSeconds)],
        @"-map",
        @"0:v:0",
        @"-map",
        @"1:a:0",
    ]];
    SPKFFmpegAppendVideoEncodeOptions(args, width, height, 0, cropFilter, nil);
    SPKFFmpegAppendTrimAudioOptions(args, SPKFFmpegTrimAudioAAC);
    [args addObject:outputURL.path];
    return args;
}

static NSURL *SPKFFmpegPreFaststartURL(NSString *basename, NSString *suffix) {
    NSString *safeBasename = basename.length > 0 ? basename : NSUUID.UUID.UUIDString;
    NSString *safeSuffix = suffix.length > 0 ? suffix : @"pre-faststart";
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.mp4", safeBasename, safeSuffix];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
}

static NSURL *SPKFFmpegNormalizedVideoURL(NSString *basename, NSString *suffix) {
    NSString *safeBasename = basename.length > 0 ? basename : NSUUID.UUID.UUIDString;
    NSString *safeSuffix = suffix.length > 0 ? suffix : @"normalized";
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.mp4", safeBasename, safeSuffix];
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:fileName]];
}

static NSError *SPKFFmpegError(NSString *description, NSInteger code) {
    return [NSError errorWithDomain:@"Sparkle.MediaFFmpeg"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEG_FAILED_TEXT")}];
}

/// FFmpeg's failure output is the entire session log: banner, build flags, then
/// the input path, and only somewhere in there the actual reason. Surfacing that
/// verbatim produces a notification that is all path and no reason, so distil it
/// to the one line that says what went wrong. The full log is still written to
/// the FFmpeg logs directory and carried on the error under SPKFFmpegLogKey.
NSString *const SPKFFmpegLogKey = @"SPKFFmpegLog";

static NSString *SPKFFmpegConciseFailureMessage(NSString *logs) {
    if (logs.length == 0)
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEG_COMMAND_FAILED_TEXT");

    static NSArray<NSString *> *markers = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = @[ @"error", @"invalid", @"unable", @"no such file", @"not supported",
                     @"unsupported", @"unknown", @"failed", @"denied", @"permission" ];
    });

    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *chosen = nil;
    NSString *lastNonEmpty = nil;
    for (NSString *raw in [logs componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:whitespace];
        if (line.length == 0)
            continue;
        lastNonEmpty = line;
        // "Conversion failed!" is FFmpeg's last word on every failure and says
        // nothing; the useful line is the one before it.
        if ([line hasPrefix:@"Conversion failed"])
            continue;
        NSString *lowered = line.lowercaseString;
        for (NSString *marker in markers) {
            if ([lowered containsString:marker]) {
                chosen = line;
                break;
            }
        }
    }
    NSString *message = chosen ?: lastNonEmpty;
    if (message.length == 0)
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEG_COMMAND_FAILED_TEXT");

    // Lines about a file are prefixed with its full path; the reason follows.
    if ([message hasPrefix:@"/"]) {
        NSRange separator = [message rangeOfString:@": "];
        if (separator.location != NSNotFound && separator.location + separator.length < message.length) {
            message = [message substringFromIndex:separator.location + separator.length];
        } else {
            message = message.lastPathComponent;
        }
    }
    if (message.length > 160) {
        message = [[message substringToIndex:159] stringByAppendingString:@"…"];
    }
    return message;
}

static NSError *SPKFFmpegErrorWithLog(NSString *description, NSInteger code, NSString *logs) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[NSLocalizedDescriptionKey] = description ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEG_FAILED_TEXT");
    if (logs.length > 0) {
        userInfo[SPKFFmpegLogKey] = logs;
    }
    return [NSError errorWithDomain:@"Sparkle.MediaFFmpeg" code:code userInfo:userInfo];
}

// Pre-convert an arbitrary audio source (including xHE-AAC, which the bundled
// FFmpegKit cannot decode) to a plain AAC-LC m4a using AVFoundation.
//  iOS's audio stack natively supports xHE-AAC, so the resulting file is
// something FFmpeg can `-c:a copy` through without ever decoding the original.
static void SPKFFmpegConvertAudioToAACLCAsync(NSURL *sourceURL,
                                              NSURL *outputURL,
                                              void (^completion)(NSURL *_Nullable, NSError *_Nullable)) {
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:nil];
    if (!asset) {
        if (completion)
            completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_AUDIO_ASSET_COULD_NOT_OPENED_TEXT"), 10));
        return;
    }

    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:asset
                                                                    presetName:AVAssetExportPresetAppleM4A];
    if (!export) {
        if (completion)
            completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_AVASSETEXPORTSESSION_UNAVAILABLE_TEXT"), 11));
        return;
    }
    export.outputURL = outputURL;
    export.outputFileType = AVFileTypeAppleM4A;
    export.shouldOptimizeForNetworkUse = YES;

    [export exportAsynchronouslyWithCompletionHandler:^{
        switch (export.status) {
        case AVAssetExportSessionStatusCompleted: {
            if ([[NSFileManager defaultManager] fileExistsAtPath:outputURL.path]) {
                if (completion)
                    completion(outputURL, nil);
            } else if (completion) {
                completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_AUDIO_CONVERSION_PRODUCED_NO_OUTPUT_TEXT"), 12));
            }
            break;
        }
        case AVAssetExportSessionStatusCancelled:
            if (completion)
                completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_AUDIO_CONVERSION_CANCELLED_TEXT"), NSUserCancelledError));
            break;
        case AVAssetExportSessionStatusFailed:
        default: {
            NSString *desc = export.error.localizedDescription ?: SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_AUDIO_CONVERSION_FAILED_TEXT");
            if (completion)
                completion(nil, SPKFFmpegError(desc, 13));
            break;
        }
        }
    }];
}

// Preferred: string-based execution via FFmpegKit.
static void SPKFFmpegRunAsyncStringCommand(NSString *commandString,
                                           NSString *identifier,
                                           NSString *stage,
                                           NSTimeInterval expectedDuration,
                                           SPKMediaFFmpegProgressBlock progress,
                                           SPKMediaFFmpegCompletionBlock completion,
                                           SPKMediaFFmpegCancelBlockPublisher cancelOut,
                                           NSURL *successURL);

// Fallback: array-based execution.
static void SPKFFmpegRunAsyncCommand(NSArray<NSString *> *arguments,
                                     NSString *identifier,
                                     NSString *stage,
                                     NSTimeInterval expectedDuration,
                                     SPKMediaFFmpegProgressBlock progress,
                                     SPKMediaFFmpegCompletionBlock completion,
                                     SPKMediaFFmpegCancelBlockPublisher cancelOut,
                                     NSURL *successURL);

// Shared implementation for both entry points.
static void _SPKFFmpegRunAsyncImpl(id commandOrArgs,
                                   BOOL isString,
                                   NSString *identifier,
                                   NSString *stage,
                                   NSTimeInterval expectedDuration,
                                   SPKMediaFFmpegProgressBlock progress,
                                   SPKMediaFFmpegCompletionBlock completion,
                                   SPKMediaFFmpegCancelBlockPublisher cancelOut,
                                   NSURL *successURL) {
    SPKFFmpegEnsureLoaded();
    if (!sSPKFFmpegAvailable || !sSPKFFmpegKitClass) {
        if (completion)
            completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEGKIT_NOT_AVAILABLE_TEXT"), 1));
        return;
    }

    // Prefer executeAsync: (string) when the caller already provides a string.
    // Fall back to executeWithArgumentsAsync: (array) for advanced-mode callers.
    SEL executeSelector;
    if (isString) {
        executeSelector = NSSelectorFromString(@"executeAsync:withCompleteCallback:withLogCallback:withStatisticsCallback:");
        if (![sSPKFFmpegKitClass respondsToSelector:executeSelector]) {
            // FFmpegKit build lacks string API — split and try array API instead
            isString = NO;
            commandOrArgs = [(NSString *)commandOrArgs componentsSeparatedByString:@" "];
        }
    }
    if (!isString) {
        executeSelector = NSSelectorFromString(@"executeWithArgumentsAsync:withCompleteCallback:withLogCallback:withStatisticsCallback:");
    }
    if (![sSPKFFmpegKitClass respondsToSelector:executeSelector]) {
        if (completion)
            completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEGKIT_ASYNC_API_UNAVAILABLE_TEXT"), 2));
        return;
    }

    __block long sessionId = 0;
    if (cancelOut) {
        cancelOut(^{
            if (sessionId > 0) {
                SEL cancelSel = NSSelectorFromString(@"cancel:");
                if ([sSPKFFmpegKitClass respondsToSelector:cancelSel]) {
                    ((void (*)(id, SEL, long))objc_msgSend)(sSPKFFmpegKitClass, cancelSel, sessionId);
                } else {
                    [SPKMediaFFmpeg cancelAll];
                }
            } else {
                [SPKMediaFFmpeg cancelAll];
            }
        });
    }

    NSString *commandForLog = isString ? (NSString *)commandOrArgs
                                       : [(NSArray *)commandOrArgs componentsJoinedByString:@" "];

    id completeBlock = ^(id session) {
        id returnCode = nil;
        if ([session respondsToSelector:@selector(getReturnCode)]) {
            returnCode = ((id (*)(id, SEL))objc_msgSend)(session, @selector(getReturnCode));
        }

        BOOL success = NO;
        BOOL cancelled = NO;
        if (returnCode && sSPKReturnCodeClass) {
            SEL sSel = NSSelectorFromString(@"isSuccess:");
            SEL cSel = NSSelectorFromString(@"isCancel:");
            if ([sSPKReturnCodeClass respondsToSelector:sSel])
                success = ((BOOL (*)(id, SEL, id))objc_msgSend)(sSPKReturnCodeClass, sSel, returnCode);
            if ([sSPKReturnCodeClass respondsToSelector:cSel])
                cancelled = ((BOOL (*)(id, SEL, id))objc_msgSend)(sSPKReturnCodeClass, cSel, returnCode);
        }

        NSString *logs = nil;
        if ([session respondsToSelector:@selector(getAllLogsAsString)]) {
            logs = ((id (*)(id, SEL))objc_msgSend)(session, @selector(getAllLogsAsString));
        } else if ([session respondsToSelector:@selector(getOutput)]) {
            logs = ((id (*)(id, SEL))objc_msgSend)(session, @selector(getOutput));
        }

        // The log file is a diagnostic artifact that gets copied into bug
        // reports, so its body stays English no matter the app language.
        NSString *description = cancelled ? @"Cancelled"
                                          : (logs.length > 0 ? logs
                                                             : (success ? @"FFmpeg command succeeded"
                                                                        : @"FFmpeg command failed"));
        SPKFFmpegPersistCommandLog(identifier, cancelled ? @"cancelled" : (success ? @"success" : @"failure"), commandForLog, description);
        if (success && successURL) {
            if (completion)
                completion(successURL, nil);
            return;
        }
        if (completion) {
            NSString *message = cancelled ? SPKL(@"PROFILE_PROFILE_ANALYZER_SERVICE_CANCELLED_TEXT") : SPKFFmpegConciseFailureMessage(logs);
            if (!cancelled) {
                SPKLog(@"FFmpeg", @"[Sparkle] command failed: %@ (full log in %@)", message,
                       SPKFFmpegLogsDirectoryPath());
            }
            completion(nil, SPKFFmpegErrorWithLog(message, cancelled ? NSUserCancelledError : 3, logs));
        }
    };

    id logBlock = ^(__unused id log) {
    };

    id statisticsBlock = ^(id statistics) {
        if (!progress || expectedDuration <= 0.0)
            return;
        double timeValue = 0.0;
        if ([statistics respondsToSelector:@selector(getTime)])
            timeValue = ((double (*)(id, SEL))objc_msgSend)(statistics, @selector(getTime));
        double normalizedTime = timeValue;
        if (normalizedTime > expectedDuration * 4.0)
            normalizedTime /= 1000.0;
        double ratio = expectedDuration > 0.0 ? MIN(MAX(normalizedTime / expectedDuration, 0.0), 0.98) : 0.0;
        progress(ratio, stage);
    };

    id session = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(sSPKFFmpegKitClass,
                                                                 executeSelector,
                                                                 commandOrArgs,
                                                                 completeBlock,
                                                                 logBlock,
                                                                 statisticsBlock);
    if ([session respondsToSelector:@selector(getSessionId)])
        sessionId = ((long (*)(id, SEL))objc_msgSend)(session, @selector(getSessionId));
}

static void SPKFFmpegRunAsyncStringCommand(NSString *commandString,
                                           NSString *identifier,
                                           NSString *stage,
                                           NSTimeInterval expectedDuration,
                                           SPKMediaFFmpegProgressBlock progress,
                                           SPKMediaFFmpegCompletionBlock completion,
                                           SPKMediaFFmpegCancelBlockPublisher cancelOut,
                                           NSURL *successURL) {
    _SPKFFmpegRunAsyncImpl(commandString, YES, identifier, stage, expectedDuration,
                           progress, completion, cancelOut, successURL);
}

static void SPKFFmpegRunAsyncCommand(NSArray<NSString *> *arguments,
                                     NSString *identifier,
                                     NSString *stage,
                                     NSTimeInterval expectedDuration,
                                     SPKMediaFFmpegProgressBlock progress,
                                     SPKMediaFFmpegCompletionBlock completion,
                                     SPKMediaFFmpegCancelBlockPublisher cancelOut,
                                     NSURL *successURL) {
    _SPKFFmpegRunAsyncImpl(arguments, NO, identifier, stage, expectedDuration,
                           progress, completion, cancelOut, successURL);
}

static NSString *SPKFFmpegValidationErrorForOutputURL(NSURL *outputURL,
                                                      BOOL expectsVideo,
                                                      BOOL expectsAudio,
                                                      NSTimeInterval expectedDuration,
                                                      NSString **diagnosticOut) {
    if (diagnosticOut)
        *diagnosticOut = nil;
    NSDictionary<NSString *, id> *options = @{AVURLAssetPreferPreciseDurationAndTimingKey : @NO};
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:outputURL options:options];
    if (!asset) {
        if (diagnosticOut)
            *diagnosticOut = @"Output validation failed: asset could not be opened.";
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_OUTPUT_VALIDATION_FAILED_ASSET_COULD_NOT_OPENED_TEXT");
    }

    NSArray<AVAssetTrack *> *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    NSArray<AVAssetTrack *> *audioTracks = [asset tracksWithMediaType:AVMediaTypeAudio];
    if (expectsVideo && videoTracks.count == 0) {
        if (diagnosticOut)
            *diagnosticOut = @"Output validation failed: merged file has no video track.";
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_OUTPUT_VALIDATION_FAILED_MERGED_FILE_NO_VIDEO_TRACK_TEXT");
    }
    if (expectsAudio && audioTracks.count == 0) {
        if (diagnosticOut)
            *diagnosticOut = @"Output validation failed: merged file has no audio track.";
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_OUTPUT_VALIDATION_FAILED_MERGED_FILE_NO_AUDIO_TRACK_TEXT");
    }

    CMTime duration = asset.duration;
    if (CMTIME_IS_INVALID(duration) || CMTIME_IS_INDEFINITE(duration) || CMTimeGetSeconds(duration) <= 0.0) {
        if (diagnosticOut)
            *diagnosticOut = @"Output validation failed: merged file duration is invalid.";
        return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_OUTPUT_VALIDATION_FAILED_MERGED_FILE_DURATION_INVALID_TEXT");
    }

    if (expectsVideo) {
        AVAssetTrack *track = videoTracks.firstObject;
        CGSize size = track.naturalSize;
        if (size.width <= 0.0 || size.height <= 0.0) {
            if (diagnosticOut)
                *diagnosticOut = @"Output validation failed: merged video track has invalid dimensions.";
            return SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_OUTPUT_VALIDATION_FAILED_MERGED_VIDEO_TRACK_INVALID_DIMENSIONS_TEXT");
        }
    }

    if (expectsVideo && expectsAudio) {
        AVAssetTrack *videoTrack = videoTracks.firstObject;
        AVAssetTrack *audioTrack = audioTracks.firstObject;
        NSTimeInterval containerDuration = CMTimeGetSeconds(duration);
        NSTimeInterval videoDuration = videoTrack ? CMTimeGetSeconds(videoTrack.timeRange.duration) : 0.0;
        NSTimeInterval audioDuration = audioTrack ? CMTimeGetSeconds(audioTrack.timeRange.duration) : 0.0;
        NSTimeInterval tolerance = MAX(0.35, MIN(1.5, expectedDuration > 0.0 ? expectedDuration * 0.10 : 0.75));

        if (videoDuration > 0.0 && audioDuration > 0.0 && fabs(videoDuration - audioDuration) > tolerance) {
            if (diagnosticOut)
                *diagnosticOut = [NSString stringWithFormat:@"Output validation failed: video/audio duration mismatch (video=%.3f, audio=%.3f).", videoDuration, audioDuration];
            return [NSString stringWithFormat:SPKL(@"MEDIA_DOWNLOAD_FFMPEG_AUDIO_DURATION_MISMATCH_FORMAT"),
                                              videoDuration,
                                              audioDuration];
        }
        if (videoDuration > 0.0 && containerDuration > 0.0 && fabs(videoDuration - containerDuration) > tolerance) {
            if (diagnosticOut)
                *diagnosticOut = [NSString stringWithFormat:@"Output validation failed: video/container duration mismatch (video=%.3f, container=%.3f).", videoDuration, containerDuration];
            return [NSString stringWithFormat:SPKL(@"MEDIA_DOWNLOAD_FFMPEG_CONTAINER_DURATION_MISMATCH_FORMAT"),
                                              videoDuration,
                                              containerDuration];
        }
    }

    return nil;
}

static void SPKFFmpegRunMergeAttempts(NSArray<NSDictionary<NSString *, id> *> *attempts,
                                      NSUInteger index,
                                      NSURL *outputURL,
                                      NSTimeInterval expectedDuration,
                                      BOOL expectsVideo,
                                      BOOL expectsAudio,
                                      SPKMediaFFmpegProgressBlock progress,
                                      SPKMediaFFmpegCompletionBlock completion,
                                      void (^cancelCapture)(dispatch_block_t cancelBlock),
                                      NSError *lastError) {
    if (index >= attempts.count) {
        if (completion) {
            completion(nil, lastError ?: SPKFFmpegError(SPKL(@"DOWNLOAD_ERROR_MERGE_FAILED"), 3));
        }
        return;
    }

    NSDictionary<NSString *, id> *attempt = attempts[index];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    // Dispatch to string or array execution depending on what the attempt provides.
    NSString *commandString = attempt[@"command"];
    NSArray<NSString *> *argumentsArray = attempt[@"arguments"];
    NSString *prepareCommand = attempt[@"prepareCommand"];
    NSArray<NSString *> *prepareArguments = attempt[@"prepareArguments"];
    NSURL *prepareOutputURL = attempt[@"prepareOutputURL"];
    NSArray<NSString *> *cleanupPaths = attempt[@"cleanupPaths"];

    // The encode step may write to an intermediate file ("mainOutputURL") that
    // a follow-up post-process step (e.g. +faststart relocate) consumes to
    // produce the final outputURL. If no mainOutputURL is set, the encode
    // writes directly to outputURL and there's no post-process step.
    NSURL *mainOutputURL = attempt[@"mainOutputURL"] ?: outputURL;
    NSArray<NSString *> *postProcessArguments = attempt[@"postProcessArguments"];

    void (^cleanupAttemptTemps)(void) = ^{
        for (NSString *path in cleanupPaths) {
            if (path.length > 0) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            }
        }
        if (mainOutputURL && ![mainOutputURL isEqual:outputURL]) {
            [[NSFileManager defaultManager] removeItemAtPath:mainOutputURL.path error:nil];
        }
    };

    void (^validateAndFinalize)(NSURL *) = ^(NSURL *finalURL) {
        NSString *validationDiagnostic = nil;
        NSString *validationError = SPKFFmpegValidationErrorForOutputURL(finalURL, expectsVideo, expectsAudio, expectedDuration, &validationDiagnostic);
        if (validationError.length == 0) {
            cleanupAttemptTemps();
            if (completion)
                completion(finalURL, nil);
            return;
        }
        NSString *loggedCommand = commandString ?: [argumentsArray componentsJoinedByString:@" "];
        SPKFFmpegPersistCommandLog([NSString stringWithFormat:@"%@-validation", attempt[@"identifier"] ?: @"merge"],
                                   @"validation-failure",
                                   loggedCommand,
                                   validationDiagnostic ?: @"Output validation failed.");
        cleanupAttemptTemps();
        NSError *invalidOutputError = SPKFFmpegError(validationError, 4);
        SPKFFmpegRunMergeAttempts(attempts, index + 1, outputURL, expectedDuration,
                                  expectsVideo, expectsAudio, progress, completion,
                                  cancelCapture, invalidOutputError);
    };

    void (^cancelHandler)(dispatch_block_t) = ^(dispatch_block_t cancelBlock) {
        if (cancelCapture)
            cancelCapture(cancelBlock);
    };

    void (^completionHandler)(NSURL *, NSError *) = ^(NSURL *_Nullable attemptOutputURL, NSError *_Nullable error) {
        if (attemptOutputURL && !error) {
            // If a post-process step is configured (e.g. +faststart relocate),
            // run it now before validating the final output.
            if (postProcessArguments.count > 0) {
                NSString *postIdentifier = [NSString stringWithFormat:@"%@-faststart", attempt[@"identifier"] ?: @"merge"];
                [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];
                SPKFFmpegRunAsyncCommand(postProcessArguments, postIdentifier, @"Finalizing", 0.0, progress, ^(NSURL *_Nullable postURL, NSError *_Nullable postError) {
                    if (postURL && !postError && [[NSFileManager defaultManager] fileExistsAtPath:postURL.path]) {
                        validateAndFinalize(postURL);
                        return;
                    }
                    cleanupAttemptTemps();
                    SPKFFmpegRunMergeAttempts(attempts, index + 1, outputURL, expectedDuration,
                                              expectsVideo, expectsAudio, progress, completion,
                                              cancelCapture, postError ?: SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_FFMPEG_FASTSTART_FAILED_ERROR"), 6));
                },
                                         cancelHandler, outputURL);
                return;
            }
            validateAndFinalize(attemptOutputURL);
            return;
        }
        cleanupAttemptTemps();
        SPKFFmpegRunMergeAttempts(attempts, index + 1, outputURL, expectedDuration,
                                  expectsVideo, expectsAudio, progress, completion,
                                  cancelCapture, error);
    };

    void (^startMainExecution)(void) = ^{
        if (commandString.length > 0) {
            SPKFFmpegRunAsyncStringCommand(commandString,
                                           attempt[@"identifier"],
                                           attempt[@"stage"],
                                           expectedDuration,
                                           progress,
                                           completionHandler,
                                           cancelHandler,
                                           mainOutputURL);
        } else {
            SPKFFmpegRunAsyncCommand(argumentsArray,
                                     attempt[@"identifier"],
                                     attempt[@"stage"],
                                     expectedDuration,
                                     progress,
                                     completionHandler,
                                     cancelHandler,
                                     mainOutputURL);
        }
    };

    if (prepareCommand.length > 0 || prepareArguments.count > 0) {
        NSString *prepareIdentifier = [NSString stringWithFormat:@"%@-prepare", attempt[@"identifier"] ?: @"merge"];
        SPKMediaFFmpegCompletionBlock prepareCompletion = ^(NSURL *_Nullable preparedURL, NSError *_Nullable prepareError) {
            if (preparedURL && !prepareError && (!prepareOutputURL || [[NSFileManager defaultManager] fileExistsAtPath:prepareOutputURL.path])) {
                startMainExecution();
                return;
            }
            cleanupAttemptTemps();
            SPKFFmpegRunMergeAttempts(attempts, index + 1, outputURL, expectedDuration,
                                      expectsVideo, expectsAudio, progress, completion,
                                      cancelCapture, prepareError ?: SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_FFMPEG_NORMALIZATION_FAILED_ERROR"), 5));
        };
        if (prepareCommand.length > 0) {
            SPKFFmpegRunAsyncStringCommand(prepareCommand,
                                           prepareIdentifier,
                                           SPKL(@"MEDIA_DOWNLOAD_FFMPEG_NORMALIZING_VIDEO_STAGE"),
                                           0.0,
                                           progress,
                                           prepareCompletion,
                                           cancelHandler,
                                           prepareOutputURL);
        } else {
            SPKFFmpegRunAsyncCommand(prepareArguments,
                                     prepareIdentifier,
                                     SPKL(@"MEDIA_DOWNLOAD_FFMPEG_NORMALIZING_VIDEO_STAGE"),
                                     0.0,
                                     progress,
                                     prepareCompletion,
                                     cancelHandler,
                                     prepareOutputURL);
        }
        return;
    }

    startMainExecution();
}

@interface _SPKMediaFFmpegLogDetailViewController : UIViewController
- (instancetype)initWithFileName:(NSString *)fileName;
@end

@interface _SPKMediaFFmpegLogListViewController : UITableViewController
@property (nonatomic, copy) NSArray<NSString *> *files;
@end

@implementation _SPKMediaFFmpegLogDetailViewController {
    NSString *_fileName;
    UITextView *_textView;
}

- (instancetype)initWithFileName:(NSString *)fileName {
    self = [super init];
    if (!self)
        return nil;
    _fileName = [fileName copy];
    self.title = fileName.stringByDeletingPathExtension ?: SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_LOG_TEXT");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    _textView.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    _textView.font = [UIFont monospacedSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    _textView.textContainerInset = UIEdgeInsetsMake(16.0, 14.0, 16.0, 14.0);
    _textView.layer.cornerRadius = 14.0;
    [self.view addSubview:_textView];

    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                            constant:12.0],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor
                                                constant:16.0],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor
                                                 constant:-16.0],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                               constant:-12.0]
    ]];

    UIBarButtonItem *shareItem = SPKMediaChromeTopBarButtonItem(@"share", self, @selector(shareTapped));
    shareItem.accessibilityLabel = SPKL(@"ALERT_ACTION_SHARE");
    UIBarButtonItem *copyItem = SPKMediaChromeTopBarButtonItem(@"copy", self, @selector(copyTapped));
    copyItem.accessibilityLabel = SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT");
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ copyItem, shareItem ]);

    [self reloadContent];
}

- (void)reloadContent {
    NSString *path = [SPKFFmpegLogsDirectoryPath() stringByAppendingPathComponent:_fileName ?: @""];
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    _textView.text = content.length > 0 ? content : SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_LOG_FILE_EMPTY_TEXT");
}

- (void)copyTapped {
    if (_textView.text.length == 0) {
        SPKNotify(kSPKNotificationMediaEncodingLogs, SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CORE_NOTHING_COPY_TEXT"), nil, @"error_filled", SPKNotificationToneError);
        return;
    }
    [UIPasteboard generalPasteboard].string = _textView.text;
    SPKNotify(kSPKNotificationMediaEncodingLogs, SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_LOG_COPIED_TEXT"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

- (void)shareTapped {
    NSString *path = [SPKFFmpegLogsDirectoryPath() stringByAppendingPathComponent:_fileName ?: @""];
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [SPKUtils showShareVC:[NSURL fileURLWithPath:path]];
    }
}

@end

@implementation _SPKMediaFFmpegLogListViewController

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self)
        return nil;
    self.title = SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_ENCODING_LOGS_TEXT");
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.backgroundColor = [SPKUtils SPKColor_InstagramGroupedBackground];
    self.tableView.separatorColor = [SPKUtils SPKColor_InstagramSeparator];
    UIBarButtonItem *shareAllItem = SPKMediaChromeTopBarButtonItem(@"share", self, @selector(shareAllTapped));
    shareAllItem.accessibilityLabel = SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_SHARE_TEXT");
    UIBarButtonItem *clearItem = SPKMediaChromeTopBarButtonItem(@"trash", self, @selector(clearTapped));
    clearItem.accessibilityLabel = SPKL(@"ALERT_ACTION_CLEAR");
    clearItem.tintColor = [SPKUtils SPKColor_InstagramDestructive];
    SPKMediaChromeSetTrailingTopBarItems(self.navigationItem, @[ clearItem, shareAllItem ]);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadFiles];
}

- (void)reloadFiles {
    self.files = SPKFFmpegSortedLogFiles().reverseObjectEnumerator.allObjects ?: @[];
    self.tableView.backgroundView = self.files.count == 0 ? [self emptyStateView] : nil;
    [self.tableView reloadData];
}

- (UIView *)emptyStateView {
    UIView *container = [UIView new];

    UIView *content = [UIView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:content];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[SPKAssetUtils instagramIconNamed:@"empty" pointSize:96 renderingMode:UIImageRenderingModeAlwaysTemplate]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = [SPKUtils SPKColor_InstagramTertiaryText];
    [content addSubview:icon];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.text = SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_NO_ENCODING_LOGS_YET_TEXT");
    [content addSubview:title];

    UILabel *subtitle = [UILabel new];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.font = [UIFont systemFontOfSize:14];
    subtitle.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    subtitle.textAlignment = NSTextAlignmentCenter;
    subtitle.numberOfLines = 0;
    subtitle.text = SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEG_RUNS_APPEAR_HERE_AFTER_MERGE_ATTEMPTS_TEXT");
    [content addSubview:subtitle];

    [NSLayoutConstraint activateConstraints:@[
        [content.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [content.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-30],
        [content.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:40],
        [content.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-40],

        [icon.topAnchor constraintEqualToAnchor:content.topAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:content.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:96],
        [icon.heightAnchor constraintEqualToConstant:96],

        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:18],
        [title.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [title.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],

        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
        [subtitle.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [subtitle.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [subtitle.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
    ]];

    return container;
}

- (void)shareAllTapped {
    NSString *exportPath = SPKFFmpegExportLogsFile();
    if (exportPath.length == 0) {
        SPKNotify(kSPKNotificationMediaEncodingLogs, SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_NO_ENCODING_LOGS_TEXT"), SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_FFMPEG_RUNS_APPEAR_HERE_AFTER_MERGE_ATTEMPTS_TEXT"), @"info_filled", SPKNotificationToneInfo);
        return;
    }
    [SPKUtils showShareVC:[NSURL fileURLWithPath:exportPath]];
}

- (void)clearTapped {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *file in self.files ?: @[]) {
        NSString *path = [SPKFFmpegLogsDirectoryPath() stringByAppendingPathComponent:file];
        [fileManager removeItemAtPath:path error:nil];
    }
    [self reloadFiles];
    SPKNotify(kSPKNotificationMediaEncodingLogs, SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_LOGS_CLEARED_TEXT"), nil, @"circle_check_filled", SPKNotificationToneSuccess);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return self.files.count > 0 ? 1 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"log"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"log"];
    }
    NSString *fileName = self.files[indexPath.row];
    NSString *path = [SPKFFmpegLogsDirectoryPath() stringByAppendingPathComponent:fileName];
    NSDictionary<NSFileAttributeKey, id> *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *date = attributes[NSFileModificationDate];
    NSNumber *size = attributes[NSFileSize];

    cell.backgroundColor = [SPKUtils SPKColor_InstagramSecondaryBackground];
    UIView *selectedBackground = [[UIView alloc] initWithFrame:CGRectZero];
    selectedBackground.backgroundColor = [SPKUtils SPKColor_InstagramPressedBackground];
    cell.selectedBackgroundView = selectedBackground;
    cell.textLabel.textColor = [SPKUtils SPKColor_InstagramPrimaryText];
    cell.detailTextLabel.textColor = [SPKUtils SPKColor_InstagramSecondaryText];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.textLabel.text = fileName.stringByDeletingPathExtension;

    NSString *dateLabel = SPKL(@"MEDIA_DOWNLOAD_FFMPEG_UNKNOWN_DATE_LABEL");
    if ([date isKindOfClass:[NSDate class]]) {
        dateLabel = [SPKUtils spk_formattedDateTime:date includingYear:YES] ?: dateLabel;
    }
    NSString *sizeLabel = [NSByteCountFormatter stringFromByteCount:(size ? size.longLongValue : 0) countStyle:NSByteCountFormatterCountStyleFile];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ • %@", dateLabel, sizeLabel];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *fileName = self.files[indexPath.row];
    [self.navigationController pushViewController:[[_SPKMediaFFmpegLogDetailViewController alloc] initWithFileName:fileName] animated:YES];
}

@end

@interface SPKMediaFFmpeg (SPKPrivate)
+ (void)_mergePreparedVideoFileURL:(NSURL *)videoFileURL
                      audioFileURL:(nullable NSURL *)audioFileURL
                     preCleanupURL:(nullable NSURL *)preCleanupURL
                 preferredBasename:(NSString *)preferredBasename
                 estimatedDuration:(NSTimeInterval)estimatedDuration
                             width:(NSInteger)width
                            height:(NSInteger)height
                     sourceBitrate:(NSInteger)sourceBitrate
                          progress:(nullable SPKMediaFFmpegProgressBlock)progress
                        completion:(SPKMediaFFmpegCompletionBlock)completion
                         cancelOut:(nullable SPKMediaFFmpegCancelBlockPublisher)cancelOut;
@end

@implementation SPKMediaFFmpeg

+ (BOOL)isAvailable {
    SPKFFmpegEnsureLoaded();
    return sSPKFFmpegAvailable;
}

+ (void)cancelAll {
    SPKFFmpegEnsureLoaded();
    if (!sSPKFFmpegKitClass) {
        return;
    }
    SEL cancelSelector = NSSelectorFromString(@"cancel");
    if ([sSPKFFmpegKitClass respondsToSelector:cancelSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(sSPKFFmpegKitClass, cancelSelector);
    }
}

+ (UIViewController *)logsViewController {
    SPKFFmpegEnsureLoaded();
    return [[_SPKMediaFFmpegLogListViewController alloc] init];
}

+ (void)mergeVideoFileURL:(NSURL *)videoFileURL
             audioFileURL:(NSURL *)audioFileURL
        preferredBasename:(NSString *)preferredBasename
        estimatedDuration:(NSTimeInterval)estimatedDuration
                    width:(NSInteger)width
                   height:(NSInteger)height
            sourceBitrate:(NSInteger)sourceBitrate
                 progress:(SPKMediaFFmpegProgressBlock)progress
               completion:(SPKMediaFFmpegCompletionBlock)completion
                cancelOut:(SPKMediaFFmpegCancelBlockPublisher)cancelOut {
    NSString *basename = preferredBasename.length > 0 ? preferredBasename : NSUUID.UUID.UUIDString;

    if (audioFileURL) {
        // Pre-convert audio to AAC-LC m4a via AVFoundation before invoking FFmpeg.
        // This handles xHE-AAC (mp4a.40.42) — which our FFmpegKit build can't decode —
        // by letting iOS's native audio stack do the decode/transcode.
        // Once converted, the merge happily stream-copies the audio.
        NSURL *convertedAudioURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-audio-aaclc.m4a", basename]]];
        if (progress)
            progress(0.0, SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT"));
        SPKFFmpegConvertAudioToAACLCAsync(audioFileURL, convertedAudioURL, ^(NSURL *_Nullable preparedAudioURL, NSError *_Nullable convertError) {
            if (preparedAudioURL && !convertError) {
                [self _mergePreparedVideoFileURL:videoFileURL
                                    audioFileURL:preparedAudioURL
                                   preCleanupURL:preparedAudioURL
                               preferredBasename:basename
                               estimatedDuration:estimatedDuration
                                           width:width
                                          height:height
                                   sourceBitrate:sourceBitrate
                                        progress:progress
                                      completion:completion
                                       cancelOut:cancelOut];
                return;
            }
            // Conversion failed — log it, then fall back to the original
            // audio. Stream-copy through FFmpeg may still work for AAC-LC
            // sources that AVFoundation rejects for some other reason.
            NSString *conversionDetails = convertError
                                               ? [NSString stringWithFormat:@"AVAssetExportSession failed (domain=%@, code=%ld)",
                                                                            convertError.domain.length > 0 ? convertError.domain : @"unknown",
                                                                            (long)convertError.code]
                                               : @"AVAssetExportSession failed without an error";
            SPKFFmpegPersistErrorLog(@"audio-aaclc-prepare",
                                     [NSString stringWithFormat:@"AVAssetExportSession m4a %@ -> %@", audioFileURL.path, convertedAudioURL.path],
                                     conversionDetails);
            [self _mergePreparedVideoFileURL:videoFileURL
                                audioFileURL:audioFileURL
                               preCleanupURL:nil
                           preferredBasename:basename
                           estimatedDuration:estimatedDuration
                                       width:width
                                      height:height
                               sourceBitrate:sourceBitrate
                                    progress:progress
                                  completion:completion
                                   cancelOut:cancelOut];
        });
        return;
    }

    [self _mergePreparedVideoFileURL:videoFileURL
                        audioFileURL:nil
                       preCleanupURL:nil
                   preferredBasename:basename
                   estimatedDuration:estimatedDuration
                               width:width
                              height:height
                       sourceBitrate:sourceBitrate
                            progress:progress
                          completion:completion
                           cancelOut:cancelOut];
}

+ (void)_mergePreparedVideoFileURL:(NSURL *)videoFileURL
                      audioFileURL:(nullable NSURL *)audioFileURL
                     preCleanupURL:(nullable NSURL *)preCleanupURL
                 preferredBasename:(NSString *)preferredBasename
                 estimatedDuration:(NSTimeInterval)estimatedDuration
                             width:(NSInteger)width
                            height:(NSInteger)height
                     sourceBitrate:(NSInteger)sourceBitrate
                          progress:(SPKMediaFFmpegProgressBlock)progress
                        completion:(SPKMediaFFmpegCompletionBlock)completion
                         cancelOut:(SPKMediaFFmpegCancelBlockPublisher)cancelOut {
    NSString *basename = preferredBasename.length > 0 ? preferredBasename : NSUUID.UUID.UUIDString;
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-merged.mp4", basename]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    SPKMediaFFmpegCompletionBlock wrappedCompletion = ^(NSURL *_Nullable url, NSError *_Nullable err) {
        if (preCleanupURL) {
            [[NSFileManager defaultManager] removeItemAtURL:preCleanupURL error:nil];
        }
        if (completion)
            completion(url, err);
    };

    NSMutableArray<NSDictionary<NSString *, id> *> *attempts = [NSMutableArray array];

    BOOL useAdvanced = [SPKUtils getBoolPref:@"downloads_adv_encoding"];
    // Progress label: "merging" only makes sense when there's an audio track to
    // fold in; a lone video stream is just re-encoded.
    NSString *mergeStage =
        audioFileURL ? SPKL(@"DOWNLOAD_PROGRESS_MERGING") : SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_RE_ENCODING_VIDEO_TEXT");
    if (!useAdvanced) {
        // Default mode starts with the direct libx264+preset path, then retries
        // with normalized video inputs (and finally a setpts re-stamping pass)
        // if validation still fails. All retries use the same libx264 settings
        // so file-size/quality stays consistent across attempts.
        //
        // Each attempt encodes to an intermediate "pre-faststart" file, then a
        // separate stream-copy pass relocates the moov atom to the front. This
        // avoids FFmpeg's in-place +faststart reopen, which is unreliable on
        // long iOS encodes inside the sandbox.
        NSURL *defaultEncodeURL = SPKFFmpegPreFaststartURL(basename, @"default-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:defaultEncodeURL error:nil];
        NSString *defaultCommandToEncode = SPKFFmpegDefaultMergeCommand(videoFileURL,
                                                                        audioFileURL,
                                                                        defaultEncodeURL,
                                                                        width,
                                                                        height,
                                                                        sourceBitrate);
        [attempts addObject:@{
            @"identifier" : @"merge",
            @"stage" : mergeStage,
            @"command" : defaultCommandToEncode,
            @"mainOutputURL" : defaultEncodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(defaultEncodeURL, outputURL),
            @"cleanupPaths" : @[ defaultEncodeURL.path ?: @"" ]
        }];

        NSURL *normalizedVideoURL = SPKFFmpegNormalizedVideoURL(basename, @"default-normalized");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedVideoURL error:nil];
        NSURL *normalizedEncodeURL = SPKFFmpegPreFaststartURL(basename, @"default-normalized-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedEncodeURL error:nil];
        NSArray<NSString *> *normalizedArgs = SPKFFmpegDefaultMergeArguments(normalizedVideoURL,
                                                                             audioFileURL,
                                                                             normalizedEncodeURL,
                                                                             nil,
                                                                             sourceBitrate);
        [attempts addObject:@{
            @"identifier" : @"merge-normalized",
            @"stage" : mergeStage,
            @"arguments" : normalizedArgs,
            @"prepareArguments" : SPKFFmpegNormalizationArguments(videoFileURL, normalizedVideoURL),
            @"prepareOutputURL" : normalizedVideoURL,
            @"mainOutputURL" : normalizedEncodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(normalizedEncodeURL, outputURL),
            @"cleanupPaths" : @[ normalizedVideoURL.path ?: @"", normalizedEncodeURL.path ?: @"" ]
        }];

        NSURL *normalizedSetPTSVideoURL = SPKFFmpegNormalizedVideoURL(basename, @"default-normalized-setpts");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedSetPTSVideoURL error:nil];
        NSURL *normalizedSetPTSEncodeURL = SPKFFmpegPreFaststartURL(basename, @"default-normalized-setpts-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedSetPTSEncodeURL error:nil];
        NSArray<NSString *> *normalizedSetPTSArgs = SPKFFmpegDefaultMergeArguments(normalizedSetPTSVideoURL,
                                                                                   audioFileURL,
                                                                                   normalizedSetPTSEncodeURL,
                                                                                   @"setpts=PTS-STARTPTS",
                                                                                   sourceBitrate);
        [attempts addObject:@{
            @"identifier" : @"merge-normalized-setpts",
            @"stage" : mergeStage,
            @"arguments" : normalizedSetPTSArgs,
            @"prepareArguments" : SPKFFmpegNormalizationArguments(videoFileURL, normalizedSetPTSVideoURL),
            @"prepareOutputURL" : normalizedSetPTSVideoURL,
            @"mainOutputURL" : normalizedSetPTSEncodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(normalizedSetPTSEncodeURL, outputURL),
            @"cleanupPaths" : @[ normalizedSetPTSVideoURL.path ?: @"", normalizedSetPTSEncodeURL.path ?: @"" ]
        }];
    } else {
        NSString *selectedCodec = SPKFFmpegStringPref(@"downloads_encoding_vid_codec", @"libx264");
        BOOL isLibx264 = [selectedCodec isEqualToString:@"libx264"];

        NSURL *advancedEncodeURL = SPKFFmpegPreFaststartURL(basename, isLibx264 ? @"advanced-libx264-pre-faststart" : @"advanced-videotoolbox-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:advancedEncodeURL error:nil];
        NSArray<NSString *> *advancedArgs = SPKFFmpegAdvancedMergeArguments(videoFileURL,
                                                                            audioFileURL,
                                                                            advancedEncodeURL,
                                                                            width,
                                                                            height,
                                                                            sourceBitrate,
                                                                            YES,
                                                                            selectedCodec,
                                                                            nil);
        NSString *advancedCommand = SPKFFmpegCommandStringFromArguments(advancedArgs);
        [attempts addObject:@{
            @"identifier" : isLibx264 ? @"merge-advanced-libx264-direct" : @"merge-advanced-videotoolbox-direct",
            @"stage" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_RE_ENCODING_VIDEO_TEXT"),
            @"command" : advancedCommand,
            @"arguments" : advancedArgs,
            @"mainOutputURL" : advancedEncodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(advancedEncodeURL, outputURL),
            @"cleanupPaths" : @[ advancedEncodeURL.path ?: @"" ]
        }];

        NSURL *normalizedVideoURL = SPKFFmpegNormalizedVideoURL(basename, isLibx264 ? @"advanced-libx264-normalized" : @"advanced-videotoolbox-normalized");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedVideoURL error:nil];
        NSURL *normalizedEncodeURL = SPKFFmpegPreFaststartURL(basename, isLibx264 ? @"advanced-libx264-normalized-pre-faststart" : @"advanced-videotoolbox-normalized-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedEncodeURL error:nil];
        NSArray<NSString *> *normalizedArgs = SPKFFmpegAdvancedMergeArguments(normalizedVideoURL,
                                                                              audioFileURL,
                                                                              normalizedEncodeURL,
                                                                              width,
                                                                              height,
                                                                              sourceBitrate,
                                                                              YES,
                                                                              selectedCodec,
                                                                              nil);
        [attempts addObject:@{
            @"identifier" : isLibx264 ? @"merge-advanced-libx264-normalized" : @"merge-advanced-videotoolbox-normalized",
            @"stage" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_RE_ENCODING_VIDEO_TEXT"),
            @"arguments" : normalizedArgs,
            @"prepareArguments" : SPKFFmpegNormalizationArguments(videoFileURL, normalizedVideoURL),
            @"prepareOutputURL" : normalizedVideoURL,
            @"mainOutputURL" : normalizedEncodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(normalizedEncodeURL, outputURL),
            @"cleanupPaths" : @[ normalizedVideoURL.path ?: @"", normalizedEncodeURL.path ?: @"" ]
        }];

        NSURL *normalizedSetPTSVideoURL = SPKFFmpegNormalizedVideoURL(basename, isLibx264 ? @"advanced-libx264-setpts" : @"advanced-videotoolbox-setpts");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedSetPTSVideoURL error:nil];
        NSURL *normalizedSetPTSEncodeURL = SPKFFmpegPreFaststartURL(basename, isLibx264 ? @"advanced-libx264-setpts-pre-faststart" : @"advanced-videotoolbox-setpts-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:normalizedSetPTSEncodeURL error:nil];
        NSArray<NSString *> *normalizedSetPTSArgs = SPKFFmpegAdvancedMergeArguments(normalizedSetPTSVideoURL,
                                                                                    audioFileURL,
                                                                                    normalizedSetPTSEncodeURL,
                                                                                    width,
                                                                                    height,
                                                                                    sourceBitrate,
                                                                                    YES,
                                                                                    selectedCodec,
                                                                                    @"setpts=PTS-STARTPTS");
        [attempts addObject:@{
            @"identifier" : isLibx264 ? @"merge-advanced-libx264-setpts" : @"merge-advanced-videotoolbox-setpts",
            @"stage" : SPKL(@"MEDIA_DOWNLOAD_MEDIA_FFMPEG_RE_ENCODING_VIDEO_TEXT"),
            @"arguments" : normalizedSetPTSArgs,
            @"prepareArguments" : SPKFFmpegNormalizationArguments(videoFileURL, normalizedSetPTSVideoURL),
            @"prepareOutputURL" : normalizedSetPTSVideoURL,
            @"mainOutputURL" : normalizedSetPTSEncodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(normalizedSetPTSEncodeURL, outputURL),
            @"cleanupPaths" : @[ normalizedSetPTSVideoURL.path ?: @"", normalizedSetPTSEncodeURL.path ?: @"" ]
        }];
    }

    __block dispatch_block_t currentCancel = nil;
    if (cancelOut) {
        cancelOut(^{
            if (currentCancel) {
                currentCancel();
            }
        });
    }
    SPKFFmpegRunMergeAttempts(attempts, 0, outputURL, estimatedDuration, YES, (audioFileURL != nil), progress, wrappedCompletion, ^(dispatch_block_t cancelBlock) {
        currentCancel = [cancelBlock copy];
    },
                              nil);
}

+ (void)extractAudioFileURL:(NSURL *)audioFileURL
          preferredBasename:(NSString *)preferredBasename
                   progress:(SPKMediaFFmpegProgressBlock)progress
                 completion:(SPKMediaFFmpegCompletionBlock)completion
                  cancelOut:(SPKMediaFFmpegCancelBlockPublisher)cancelOut {
    NSString *basename = preferredBasename.length > 0 ? preferredBasename : NSUUID.UUID.UUIDString;
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-audio.m4a", basename]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    NSArray<NSString *> *copyArguments = @[
        @"-y",
        @"-hide_banner",
        @"-loglevel", @"warning",
        @"-i", audioFileURL.path,
        @"-vn",
        @"-c:a", @"copy",
        outputURL.path
    ];
    NSArray<NSDictionary<NSString *, id> *> *attempts = @[
        @{
            @"identifier" : @"audio-copy",
            @"arguments" : copyArguments
        },
        @{
            @"identifier" : @"audio-reencode-aac",
            @"arguments" : SPKFFmpegAudioReencodeArguments(audioFileURL, outputURL)
        }
    ];

    SPKFFmpegRunMergeAttempts(attempts, 0, outputURL, 0.0, NO, YES, progress, completion, ^(dispatch_block_t cancelBlock) {
        if (cancelOut)
            cancelOut(cancelBlock);
    },
                              nil);
}

+ (void)trimVideoFileURL:(NSURL *)videoFileURL
            startSeconds:(NSTimeInterval)startSeconds
         durationSeconds:(NSTimeInterval)durationSeconds
              cropFilter:(NSString *)cropFilter
             croppedSize:(CGSize)croppedSize
       preferredBasename:(NSString *)preferredBasename
                progress:(SPKMediaFFmpegProgressBlock)progress
              completion:(SPKMediaFFmpegCompletionBlock)completion
               cancelOut:(SPKMediaFFmpegCancelBlockPublisher)cancelOut {
    NSString *basename = preferredBasename.length > 0 ? preferredBasename : NSUUID.UUID.UUIDString;
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-trimmed.mp4", basename]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    // Don't demand an audio track on silent clips, and capture the source
    // dimensions so advanced encoding (max-resolution scaling) can use them.
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:videoFileURL
                                            options:@{AVURLAssetPreferPreciseDurationAndTimingKey : @NO}];
    BOOL hasAudio = [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;

    NSInteger width = 0;
    NSInteger height = 0;
    AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (videoTrack) {
        CGSize rendered = CGSizeApplyAffineTransform(videoTrack.naturalSize, videoTrack.preferredTransform);
        width = (NSInteger)lround(fabs(rendered.width));
        height = (NSInteger)lround(fabs(rendered.height));
    }
    // With a crop in the chain the encoder sees the cropped picture, so the
    // max-resolution decision has to be made against that size.
    if (croppedSize.width > 0.0 && croppedSize.height > 0.0) {
        width = (NSInteger)lround(croppedSize.width);
        height = (NSInteger)lround(croppedSize.height);
    }

    NSArray<NSNumber *> *audioModes = hasAudio
                                          ? @[ @(SPKFFmpegTrimAudioAAC), @(SPKFFmpegTrimAudioCopy), @(SPKFFmpegTrimAudioNone) ]
                                          : @[ @(SPKFFmpegTrimAudioNone) ];

    NSMutableArray<NSDictionary<NSString *, id> *> *attempts = [NSMutableArray array];
    for (NSNumber *modeValue in audioModes) {
        SPKFFmpegTrimAudioMode mode = (SPKFFmpegTrimAudioMode)modeValue.integerValue;
        NSString *suffix = [NSString stringWithFormat:@"trim-%ld", (long)mode];
        NSURL *encodeURL = SPKFFmpegPreFaststartURL(basename, [suffix stringByAppendingString:@"-pre-faststart"]);
        [[NSFileManager defaultManager] removeItemAtURL:encodeURL error:nil];

        [attempts addObject:@{
            @"identifier" : [NSString stringWithFormat:@"trim-%ld", (long)mode],
            @"stage" : SPKL(@"MEDIA_DOWNLOAD_FFMPEG_TRIMMING_VIDEO_STAGE"),
            @"arguments" : SPKFFmpegTrimArguments(videoFileURL, encodeURL, startSeconds, durationSeconds, width, height, 0, cropFilter, mode),
            @"mainOutputURL" : encodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(encodeURL, outputURL),
            @"cleanupPaths" : @[ encodeURL.path ?: @"" ]
        }];
    }

    __block dispatch_block_t currentCancel = nil;
    if (cancelOut) {
        cancelOut(^{
            if (currentCancel)
                currentCancel();
        });
    }
    SPKFFmpegRunMergeAttempts(attempts, 0, outputURL, durationSeconds, YES, NO, progress, completion, ^(dispatch_block_t cancelBlock) {
        currentCancel = [cancelBlock copy];
    },
                              nil);
}

+ (void)extractFrameFromVideoFileURL:(NSURL *)videoFileURL
                           atSeconds:(NSTimeInterval)seconds
                   preferredBasename:(NSString *)preferredBasename
                          completion:(SPKMediaFFmpegCompletionBlock)completion {
    NSString *basename = preferredBasename.length > 0 ? preferredBasename : NSUUID.UUID.UUIDString;
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-frame.png", basename]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    // Input seek is frame accurate here: FFmpeg seeks to the preceding keyframe
    // and decodes forward to the requested time before emitting the frame.
    NSArray<NSString *> *arguments = @[
        @"-y",
        @"-hide_banner",
        @"-loglevel", @"warning",
        @"-ss", [NSString stringWithFormat:@"%.3f", MAX(0.0, seconds)],
        @"-i", videoFileURL.path,
        @"-map", @"0:v:0",
        @"-frames:v", @"1",
        @"-an",
        @"-c:v", @"png",
        outputURL.path
    ];
    SPKFFmpegRunAsyncCommand(arguments, @"frame-extract", SPKL(@"MEDIA_TRIM_TRIM_SAVE_COORDINATOR_EXTRACTING_FRAME_TEXT"), 0.0, nil, ^(NSURL *_Nullable url, NSError *_Nullable error) {
        // A seek past the last decodable frame exits cleanly with no output.
        if (url && ![[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
            url = nil;
            error = SPKFFmpegError(SPKL(@"MEDIA_TRIM_TRIM_RENDERER_COULD_NOT_EXTRACT_SELECTED_FRAME_TEXT"), 21);
        }
        if (completion)
            completion(url, error);
    },
                             nil, outputURL);
}

+ (void)trimMergeVideoURL:(NSURL *)videoURL
                 audioURL:(NSURL *)audioURL
             startSeconds:(NSTimeInterval)startSeconds
          durationSeconds:(NSTimeInterval)durationSeconds
               cropFilter:(NSString *)cropFilter
        preferredBasename:(NSString *)preferredBasename
                    width:(NSInteger)width
                   height:(NSInteger)height
                 progress:(SPKMediaFFmpegProgressBlock)progress
               completion:(SPKMediaFFmpegCompletionBlock)completion
                cancelOut:(SPKMediaFFmpegCancelBlockPublisher)cancelOut {
    if (!videoURL || !audioURL) {
        if (completion)
            completion(nil, SPKFFmpegError(SPKL(@"MEDIA_DOWNLOAD_FFMPEG_TRIM_MISSING_SOURCE_ERROR"), 20));
        return;
    }

    NSString *basename = preferredBasename.length > 0 ? preferredBasename : NSUUID.UUID.UUIDString;
    NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-trimmed.mp4", basename]]];
    [[NSFileManager defaultManager] removeItemAtURL:outputURL error:nil];

    NSString *videoSource = videoURL.isFileURL ? videoURL.path : videoURL.absoluteString;

    void (^runWithAudioSource)(NSString *, dispatch_block_t) = ^(NSString *audioSource, dispatch_block_t cleanup) {
        NSURL *encodeURL = SPKFFmpegPreFaststartURL(basename, @"trim-merge-pre-faststart");
        [[NSFileManager defaultManager] removeItemAtURL:encodeURL error:nil];

        NSArray<NSDictionary<NSString *, id> *> *attempts = @[ @{
            @"identifier" : @"trim-merge",
            @"stage" : SPKL(@"MEDIA_DOWNLOAD_FFMPEG_TRIMMING_VIDEO_STAGE"),
            @"arguments" : SPKFFmpegTrimMergeArguments(videoSource, audioSource, encodeURL, startSeconds, durationSeconds, width, height, cropFilter),
            @"mainOutputURL" : encodeURL,
            @"postProcessArguments" : SPKFFmpegFaststartArguments(encodeURL, outputURL),
            @"cleanupPaths" : @[ encodeURL.path ?: @"" ]
        } ];

        SPKMediaFFmpegCompletionBlock wrapped = ^(NSURL *_Nullable url, NSError *_Nullable err) {
            if (cleanup)
                cleanup();
            if (completion)
                completion(url, err);
        };

        __block dispatch_block_t currentCancel = nil;
        if (cancelOut) {
            cancelOut(^{
                if (currentCancel)
                    currentCancel();
            });
        }
        SPKFFmpegRunMergeAttempts(attempts, 0, outputURL, durationSeconds, YES, YES, progress, wrapped, ^(dispatch_block_t cancelBlock) {
            currentCancel = [cancelBlock copy];
        },
                                  nil);
    };

    // Pre-convert the DASH audio to AAC-LC via AVFoundation first. IG's DASH
    // audio is often xHE-AAC, which the bundled FFmpeg can't decode; iOS's audio
    // stack can, so this makes the merge succeed. Falls back to the original
    // audio if conversion fails (works for plain AAC-LC sources).
    NSURL *convertedAudioURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-audio-aaclc.m4a", basename]]];
    if (progress)
        progress(0.0, SPKL(@"AUDIO_AUDIO_DMUPLOAD_COORDINATOR_CONVERTING_AUDIO_TEXT"));
    SPKFFmpegConvertAudioToAACLCAsync(audioURL, convertedAudioURL, ^(NSURL *_Nullable preparedAudioURL, NSError *_Nullable convertError) {
        if (preparedAudioURL && !convertError) {
            runWithAudioSource(preparedAudioURL.path, ^{
                [[NSFileManager defaultManager] removeItemAtURL:preparedAudioURL error:nil];
            });
        } else {
            runWithAudioSource(audioURL.isFileURL ? audioURL.path : audioURL.absoluteString, nil);
        }
    });
}

@end
