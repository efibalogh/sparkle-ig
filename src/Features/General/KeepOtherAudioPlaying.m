#import "KeepOtherAudioPlaying.h"
#import "../../Shared/MobileConfig/SPKMobileConfigOverrides.h"
#import "../../Utils.h"

// * Keep other audio playing on launch
// At startup Instagram activates its audio session as mixable, then switches
// the active session's mode to MoviePlayback. iOS treats that mode switch as a
// new claim on playback and interrupts whatever another app is playing, so
// music or a podcast stops the moment Instagram opens, before any video is
// unmuted. The switch is gated by one MobileConfig parameter,
// ig_ios_ingest_ec3_audio (config 92647):
//   param 6 (bool) audiosession_movie_mode, read once by the audio session
//   manager when the user session starts.
// With the preference on Sparkle answers false, so the session keeps the
// default mode and stays mixable. Unmuting a video still takes over audio as
// usual, because that goes through Instagram's exclusive category instead.
//
// The ID is looked up by (config, index) at launch. 410.1.0 ships the config
// but its audio session manager has no movie-mode switch, so the feature
// counts as unavailable there.

static NSString *const kSPKKeepOtherAudioPrefKey = @"general_keep_other_audio_playing";

static uint32_t const kSPKEC3AudioConfig = 92647;

// The table is scanned once; settings ask for availability before or after
// the launch installer has run.
static unsigned long long sSPKKeepOtherAudioParam;
static BOOL sSPKKeepOtherAudioAvailable;

static void SPKKeepOtherAudioResolveOnce(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class manager = NSClassFromString(@"IGAudioSessionManager");
        if (![manager instancesRespondToSelector:NSSelectorFromString(@"setUseMoviePlaybackAsDefaultMode:")]) {
            SPKLog(@"KeepOtherAudio", @"No movie-mode switch in this build; nothing to override");
            return;
        }
        SPKMobileConfigParamSpec const specs[] = {
            {6, SPKMobileConfigParamTypeBool},
        };
        unsigned long long params[1] = {0};
        if (!SPKMobileConfigResolveParams(kSPKEC3AudioConfig, specs, 1, params)) {
            SPKLog(@"KeepOtherAudio", @"Config %u not resolved; keeping Instagram's audio session mode",
                   kSPKEC3AudioConfig);
            return;
        }
        sSPKKeepOtherAudioParam = params[0];
        sSPKKeepOtherAudioAvailable = YES;
    });
}

BOOL SPKKeepOtherAudioPlayingIsAvailable(void) {
    SPKKeepOtherAudioResolveOnce();
    return sSPKKeepOtherAudioAvailable;
}

void SPKInstallKeepOtherAudioPlayingHooksIfNeeded(void) {
    // Registered before Instagram's session-start read; the getter re-checks
    // the preference on every read, but Instagram only reads it once per launch.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (!SPKKeepOtherAudioPlayingIsAvailable())
            return;
        SPKMobileConfigOverrideBool(sSPKKeepOtherAudioParam, kSPKKeepOtherAudioPrefKey, NO);
    });
}
