#import "SPKLiquidGlassBisect.h"

#if SPK_DEV

#import "SPKLiquidGlassGates.h"
#import "../../AssetUtils.h"
#import "../../Shared/Diagnostics/SPKDiagnostics.h"
#import "../../Shared/i18n/SPKStrings.h"
#import "../../Utils.h"

// Test state, device-global like the gate switches it drives. Suspects are
// families: a value Sparkle stores and the getter Instagram reads it back
// through only make sense handed back together.
static NSString *const kSPKLGTestPhaseKey = @"tools_lg_test_phase";
static NSString *const kSPKLGTestCandidatesKey = @"tools_lg_test_candidates";
static NSString *const kSPKLGTestTrialKey = @"tools_lg_test_trial";
static NSString *const kSPKLGTestStepKey = @"tools_lg_test_step";
static NSString *const kSPKLGTestTotalKey = @"tools_lg_test_total";

static NSString *const kSPKLGPhaseVerify = @"verify";
static NSString *const kSPKLGPhaseNarrow = @"narrow";

static NSArray<NSString *> *SPKLGStoredList(NSString *key) {
    NSString *joined = [SPKUtils getStringPref:key];
    return joined.length ? [joined componentsSeparatedByString:@"\n"] : @[];
}

static void SPKLGStoreList(NSString *key, NSArray<NSString *> *list) {
    SPKPreferenceSetObject([list componentsJoinedByString:@"\n"], key);
}

BOOL SPKLiquidGlassBisectIsActive(void) {
    return [SPKUtils getStringPref:kSPKLGTestPhaseKey].length > 0;
}

static NSString *SPKLGFamily(NSDictionary *gate) {
    return SPKLiquidGlassGateDisplayName(gate[SPKLiquidGlassGateNameKey]);
}

// These two decide which tab bar exists at all. Handing them back swaps the
// floating bar for the classic one, which removes the screen being checked, so
// they always stay forced and are never suspects. The other tab bar values only
// tune the floating bar and are tested like everything else.
static BOOL SPKLGIsPinned(NSDictionary *gate) {
    NSString *name = gate[SPKLiquidGlassGateNameKey];
    return [name isEqualToString:@"IGFloatingTabBarEnabled"] || [name isEqualToString:@"IGTabBarStyleForLauncherSet"];
}

// Families with at least one value Sparkle changed this launch, in registry order.
static NSArray<NSString *> *SPKLGChangedFamilies(void) {
    NSMutableOrderedSet<NSString *> *families = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *gate in SPKLiquidGlassGateSnapshot()) {
        if (SPKLGIsPinned(gate))
            continue;
        if (![gate[SPKLiquidGlassGateInstalledKey] boolValue] || [gate[SPKLiquidGlassGateSkippedThisLaunchKey] boolValue])
            continue;
        NSInteger instagramValue = [gate[SPKLiquidGlassGateInstagramValueKey] integerValue];
        NSInteger returnedValue = [gate[SPKLiquidGlassGateReturnedValueKey] integerValue];
        if (returnedValue < 0)
            continue;
        // A stored value has no Instagram reading, so it always counts.
        if (instagramValue < 0 || instagramValue != returnedValue)
            [families addObject:SPKLGFamily(gate)];
    }
    return families.array;
}

// Hands exactly these families back to Instagram from the next launch on.
static void SPKLGApplyReleased(NSArray<NSString *> *families) {
    NSSet<NSString *> *released = [NSSet setWithArray:families];
    for (NSDictionary *gate in SPKLiquidGlassGateSnapshot()) {
        NSString *name = gate[SPKLiquidGlassGateNameKey];
        SPKLiquidGlassGateSetSkippedNextLaunch(name, !SPKLGIsPinned(gate) && [released containsObject:SPKLGFamily(gate)]);
    }
}

static void SPKLGClearState(void) {
    for (NSString *key in @[ kSPKLGTestPhaseKey, kSPKLGTestCandidatesKey, kSPKLGTestTrialKey, kSPKLGTestStepKey, kSPKLGTestTotalKey ])
        SPKPreferenceSetObject(nil, key);
}

static void SPKLGCloseApp(void) {
    [[NSUserDefaults standardUserDefaults] synchronize];
    exit(0);
}

static NSUInteger SPKLGStepsFor(NSUInteger count) {
    NSUInteger steps = 0;
    while (count > 1) {
        count = (count + 1) / 2;
        steps++;
    }
    return steps;
}

// Releases the first half of the candidates for the next launch.
static void SPKLGStartStep(NSArray<NSString *> *candidates, NSInteger step) {
    NSArray<NSString *> *trial = [candidates subarrayWithRange:NSMakeRange(0, (candidates.count + 1) / 2)];
    SPKPreferenceSetObject(kSPKLGPhaseNarrow, kSPKLGTestPhaseKey);
    SPKLGStoreList(kSPKLGTestCandidatesKey, candidates);
    SPKLGStoreList(kSPKLGTestTrialKey, trial);
    SPKPreferenceSetObject(@(step), kSPKLGTestStepKey);
    SPKLGApplyReleased(trial);
    SPKLog(@"LiquidGlass", @"Test step %ld: releasing %@ of %@", (long)step, trial, candidates);
}

static void SPKLGFinishWithCulprit(NSString *family) {
    SPKLGClearState();
    SPKLGApplyReleased(@[ family ]);
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSMutableArray<NSString *> *symbols = [NSMutableArray array];
    for (NSDictionary *gate in SPKLiquidGlassGateSnapshot()) {
        if ([SPKLGFamily(gate) isEqualToString:family])
            [symbols addObject:gate[SPKLiquidGlassGateNameKey]];
    }
    NSString *details = [NSString stringWithFormat:@"%@\n%@", family, [symbols componentsJoinedByString:@"\n"]];
    SPKLog(@"LiquidGlass", @"Test result: %@", details);
    [UIPasteboard generalPasteboard].string = details;
    [SPKUtils showConfirmation:^{
        SPKLGCloseApp();
    }
                         title:SPKL(@"DEV_LG_TEST_FOUND_TITLE")
                       message:[NSString stringWithFormat:SPKL(@"DEV_LG_TEST_FOUND_MESSAGE_FORMAT"), family, [symbols componentsJoinedByString:@"\n"]]];
}

static void SPKLGAnswer(BOOL problemGone) {
    NSString *phase = [SPKUtils getStringPref:kSPKLGTestPhaseKey];
    NSArray<NSString *> *candidates = SPKLGStoredList(kSPKLGTestCandidatesKey);
    NSArray<NSString *> *trial = SPKLGStoredList(kSPKLGTestTrialKey);
    NSInteger step = (NSInteger)[SPKUtils getDoublePref:kSPKLGTestStepKey];

    if ([phase isEqualToString:kSPKLGPhaseVerify]) {
        if (!problemGone) {
            // Every changed value was with Instagram and the problem stayed.
            SPKLGClearState();
            SPKLiquidGlassGateSetAllSkippedNextLaunch(NO);
            [[NSUserDefaults standardUserDefaults] synchronize];
            [SPKUtils showConfirmation:^{
                SPKLGCloseApp();
            }
                                 title:SPKL(@"DEV_LG_TEST_NOT_LIQUID_GLASS_TITLE")
                               message:SPKL(@"DEV_LG_TEST_NOT_LIQUID_GLASS_MESSAGE")];
            return;
        }
        if (candidates.count == 1) {
            SPKLGFinishWithCulprit(candidates.firstObject);
            return;
        }
        SPKLGStartStep(candidates, step + 1);
        SPKLGCloseApp();
        return;
    }

    NSArray<NSString *> *remaining;
    if (problemGone) {
        remaining = trial;
    } else {
        NSMutableArray<NSString *> *rest = [candidates mutableCopy];
        [rest removeObjectsInArray:trial];
        remaining = rest;
    }
    if (remaining.count <= 1) {
        if (remaining.count == 1)
            SPKLGFinishWithCulprit(remaining.firstObject);
        else
            SPKLGClearState();
        return;
    }
    SPKLGStartStep(remaining, step + 1);
    SPKLGCloseApp();
}

static void SPKLGStop(void) {
    SPKLGClearState();
    SPKLiquidGlassGateSetAllSkippedNextLaunch(NO);
    [[NSUserDefaults standardUserDefaults] synchronize];
    [SPKUtils showRestartConfirmation];
}

void SPKLiquidGlassBisectStart(void) {
    if ([SPKUtils spk_liquidGlassMode] == SPKLiquidGlassModeFollow) {
        [SPKUtils showConfirmation:^{
        }
                             title:SPKL(@"DEV_LG_TEST_TITLE")
                           message:SPKL(@"DEV_LG_TEST_NEEDS_FORCED_MESSAGE")];
        return;
    }
    NSArray<NSString *> *families = SPKLGChangedFamilies();
    if (families.count == 0) {
        [SPKUtils showConfirmation:^{
        }
                             title:SPKL(@"DEV_LG_TEST_TITLE")
                           message:SPKL(@"DEV_LG_TEST_NOTHING_CHANGED_MESSAGE")];
        return;
    }
    NSUInteger total = SPKLGStepsFor(families.count) + 1;
    NSString *message = [NSString stringWithFormat:SPKL(@"DEV_LG_TEST_START_MESSAGE_FORMAT"), (unsigned long)families.count, (unsigned long)total];
    [SPKUtils showConfirmation:^{
        // Step 1 hands everything back, to prove a forced value is involved at all.
        SPKPreferenceSetObject(kSPKLGPhaseVerify, kSPKLGTestPhaseKey);
        SPKLGStoreList(kSPKLGTestCandidatesKey, families);
        SPKLGStoreList(kSPKLGTestTrialKey, families);
        SPKPreferenceSetObject(@1, kSPKLGTestStepKey);
        SPKPreferenceSetObject(@(total), kSPKLGTestTotalKey);
        SPKLGApplyReleased(families);
        SPKLog(@"LiquidGlass", @"Test started with %@", families);
        SPKLGCloseApp();
    }
                         title:SPKL(@"DEV_LG_TEST_TITLE")
                       message:message];
}

NSArray<UIMenuElement *> *SPKLiquidGlassBisectMenuElements(void) {
    if (!SPKLiquidGlassBisectIsActive()) {
        return @[ [UIAction actionWithTitle:SPKL(@"DEV_LG_TEST_START_ACTION")
                                      image:[SPKAssetUtils menuIconNamed:@"search"]
                                 identifier:nil
                                    handler:^(__unused UIAction *action) {
                                        SPKLiquidGlassBisectStart();
                                    }] ];
    }

    NSInteger step = (NSInteger)[SPKUtils getDoublePref:kSPKLGTestStepKey];
    NSInteger total = MAX(step, (NSInteger)[SPKUtils getDoublePref:kSPKLGTestTotalKey]);
    UIAction *stillThere = [UIAction actionWithTitle:SPKL(@"DEV_LG_TEST_ANSWER_STILL_THERE")
                                               image:[SPKAssetUtils menuIconNamed:@"xmark"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
                                                 SPKLGAnswer(NO);
                                             }];
    UIAction *gone = [UIAction actionWithTitle:SPKL(@"DEV_LG_TEST_ANSWER_GONE")
                                         image:[SPKAssetUtils menuIconNamed:@"circle_check"]
                                    identifier:nil
                                       handler:^(__unused UIAction *action) {
                                           SPKLGAnswer(YES);
                                       }];
    UIAction *stop = [UIAction actionWithTitle:SPKL(@"DEV_LG_TEST_STOP")
                                         image:[SPKAssetUtils menuIconNamed:@"trash"]
                                    identifier:nil
                                       handler:^(__unused UIAction *action) {
                                           SPKLGStop();
                                       }];
    stop.attributes = UIMenuElementAttributesDestructive;
    NSString *title = [NSString stringWithFormat:SPKL(@"DEV_LG_TEST_STEP_FORMAT"), (long)step, (long)total];
    return @[ [UIMenu menuWithTitle:title image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ stillThere, gone, stop ]] ];
}

#endif
