#import "SPKStartupHooks.h"

#import "../Utils.h"
#import "SPKHookBisect.h"
#import "SPKStabilityGuard.h"

FOUNDATION_EXPORT void SPKInstallLiquidGlassHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallProgressiveBlurHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFeedActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHeaderActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFollowingFeedHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallReelsActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallStoriesActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallStoryAudioToggleHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideAudioUnavailableToastHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallStoryAutoSaveHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDirectAutoSaveHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallMessagesActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallAggregatedMediaActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallProfileActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallProfilePhotoZoomHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallBackgroundRefreshHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallSeenButtonHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallFollowConfirmHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallCreateGroupButtonControlHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallConfirmSendHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallSharedLinkCleanupHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallShareLongPressCopyHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallHideMetaAIHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallAccountSwitchHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallAdBlockingEarlyHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallStoryAdBlockingHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFeedFilteringHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFeedFilteringFeedHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallNoSuggestedUsersHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallLikeConfirmHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallTweakFeedHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallTweakStoryHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallTweakReelsHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallTweakMessagesHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallTweakGeneralUIHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallTweakLaunchCriticalHooks(void);
FOUNDATION_EXPORT void SPKInstallOpenLinkFromClipboardHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideExploreGridHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideTrendingSearchesHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallCustomFontHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallNavigationHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallSettingsShortcutsHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallDisableHapticsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallCopyDescriptionHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallTappableTextLinksHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideRecentSearchesHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallSearchBarIconRemapHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallDetailedColorPickerHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallEnhancedMediaResolutionHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideMetricsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDisableFeedAutoplayHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallPostCommentConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallSwipeCloseCommentsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallCommentActionsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideCommentGiftsButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallCommentComposerGalleryUploadHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideStoryTrayHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideThreadsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideRepostButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDisableHomeButtonRefreshHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDisableStorySeenHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallStickerInteractConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallStoryPollVoteCountsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideReelsHeaderHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideReelsViewerCommentBarHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallReelsPlaybackHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallDisableScrollingReelsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFollowIndicatorHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallProfileAnalyzerVisitTrackerHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDisableDMStorySeenHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallDisableInstantsCreationHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallInstantsActionButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallInstantsAutoSaveHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallInstantsAllowScreenshotHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallInstantsReactionConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallInstantsGalleryUploadHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallVisualMsgModifierHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallNoSuggestedChatsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallChangeThemeConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFollowRequestConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDisableTypingStatusHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFullLastActiveHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallShhConfirmHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallHideFriendsMapHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallKeepDeletedMessagesHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHiddenChatsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallPresenceNotificationsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallAccurateActiveStatusHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallCallConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDMAudioMsgConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDMInteractionConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallDMRefreshConfirmHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallCaptureHidingHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallProfileHeaderControlsHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallAudioPageDownloadHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallDirectMessageMenuHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallNotesActionsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideDirectCallButtonsHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideFlagButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallFixDuplicateNotificationsHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallOpenPostNativePushHooksIfNeeded(void);
FOUNDATION_EXPORT void SPKInstallDisableAppIconGestureHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallUnlockStoryPreviewHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallUnlockMessagePreviewHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideViewerPlusButtonHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallSearchStoryViewersHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallStoryVideoStickerHooksIfEnabled(void);
FOUNDATION_EXPORT void SPKInstallHideRecentHighlightsHooksIfEnabled(void);

// Master kill switch: when YES, suppress all feature hook installation, but
// keep the home long-press shortcut so users can still reach Settings to turn
// it back off. Toggling requires a restart (each installer is dispatch_once).
static BOOL SPKShouldSuppressFeatureHooks(void) {
    return [SPKUtils getBoolPref:@"tools_disable_all"] || SPKStabilityGuardIsSafeStartupMode();
}

// Hooks that must always install regardless of the kill switch so users keep
// access to Sparkle Settings (home tab long-press → settings).
static void SPKInstallEssentialAccessHooks(void) {
    SPKInstallNavigationHooksIfNeeded();
    SPKInstallSettingsShortcutsHooksIfNeeded();
}

// Every feature installer below goes through SPK_INSTALL so a single installer
// can be skipped at launch from Settings > Tools > Hook Bisect. Feature prefs
// can't do this: most installers ignore their pref and install unconditionally,
// leaving the swizzle (and its per-layout work) in place with the feature "off".
#define SPK_INSTALL(installer)                                    \
    do {                                                          \
        if (!SPKHookBisectShouldSkipInstaller(#installer))        \
            installer();                                          \
    } while (0)

void SPKInstallLaunchCriticalHooks(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"Launch");
    // The presence scheduler is constructed while Instagram builds the user
    // session. Installing this with the delayed Messages surface misses that
    // one-time initializer, leaving the configured refresh interval inert.
    SPK_INSTALL(SPKInstallAccurateActiveStatusHooksIfEnabled);
    // Progressive blur relies on UIScrollEdgeEffect (iOS 26+ only).
    if (SYSTEM_VERSION_GREATER_THAN_OR_EQUAL_TO(@"26.0")) {
        if ([SPKUtils getBoolPref:@"interface_progressive_blur"]) {
            SPK_INSTALL(SPKInstallProgressiveBlurHooksIfEnabled);
        }
    }
    // Liquid Glass surface hooks install on any iOS: the tab bar experiment
    // gates reshape the bar into the floating pill even pre-26 (only the glass
    // material is unavailable). The ObjC button hooks inside self-skip when
    // their classes are absent, so this is safe on older systems.
    if ([SPKUtils spk_isLiquidGlassEffectivelyEnabled]) {
        SPK_INSTALL(SPKInstallLiquidGlassHooksIfEnabled);
    }
    SPK_INSTALL(SPKInstallTweakLaunchCriticalHooks);
    SPK_INSTALL(SPKInstallFollowingFeedHooksIfEnabled);
    SPK_INSTALL(SPKInstallAdBlockingEarlyHooksIfEnabled);
    SPK_INSTALL(SPKInstallStoryAdBlockingHooksIfEnabled);
    SPK_INSTALL(SPKInstallNavigationHooksIfNeeded);
    SPK_INSTALL(SPKInstallSettingsShortcutsHooksIfNeeded);
}

void SPKInstallFeedSurfaceHooksIfNeeded(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"Feed");
    SPK_INSTALL(SPKInstallTweakFeedHooksIfNeeded);
    SPK_INSTALL(SPKInstallFeedFilteringFeedHooksIfEnabled);
    SPK_INSTALL(SPKInstallFeedActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallHeaderActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallBackgroundRefreshHooksIfEnabled);
    SPK_INSTALL(SPKInstallLikeConfirmHooksIfNeeded);
    SPK_INSTALL(SPKInstallDisableFeedAutoplayHooksIfEnabled);
    SPK_INSTALL(SPKInstallPostCommentConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallSwipeCloseCommentsHooksIfEnabled);
    SPK_INSTALL(SPKInstallCommentActionsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideCommentGiftsButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallCommentComposerGalleryUploadHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideStoryTrayHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideRecentHighlightsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideThreadsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideRepostButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallDisableHomeButtonRefreshHooksIfEnabled);
    SPK_INSTALL(SPKInstallCopyDescriptionHooksIfEnabled);
    SPK_INSTALL(SPKInstallTappableTextLinksHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideMetricsHooksIfEnabled);
    SPK_INSTALL(SPKInstallDisableAppIconGestureHooksIfEnabled);
}

void SPKInstallStorySurfaceHooksIfNeeded(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"Stories");
    SPK_INSTALL(SPKInstallTweakStoryHooksIfNeeded);
    SPK_INSTALL(SPKInstallFeedFilteringHooksIfEnabled);
    SPK_INSTALL(SPKInstallStoriesActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallStoryAudioToggleHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideAudioUnavailableToastHooksIfEnabled);
    SPK_INSTALL(SPKInstallStoryAutoSaveHooksIfEnabled);
    SPK_INSTALL(SPKInstallSeenButtonHooksIfNeeded);
    SPK_INSTALL(SPKInstallHideMetaAIHooksIfEnabled);
    SPK_INSTALL(SPKInstallLikeConfirmHooksIfNeeded);
    SPK_INSTALL(SPKInstallDisableStorySeenHooksIfNeeded);
    SPK_INSTALL(SPKInstallStickerInteractConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallStoryPollVoteCountsHooksIfEnabled);
    SPK_INSTALL(SPKInstallDetailedColorPickerHooksIfEnabled);
    SPK_INSTALL(SPKInstallUnlockStoryPreviewHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideViewerPlusButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallSearchStoryViewersHooksIfEnabled);
    SPK_INSTALL(SPKInstallStoryVideoStickerHooksIfEnabled);
}

void SPKInstallReelsSurfaceHooksIfNeeded(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"Reels");
    SPK_INSTALL(SPKInstallTweakReelsHooksIfNeeded);
    SPK_INSTALL(SPKInstallReelsActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallFeedFilteringHooksIfEnabled);
    SPK_INSTALL(SPKInstallLikeConfirmHooksIfNeeded);
    SPK_INSTALL(SPKInstallReelsPlaybackHooksIfNeeded);
    SPK_INSTALL(SPKInstallHideReelsHeaderHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideReelsViewerCommentBarHooksIfEnabled);
    SPK_INSTALL(SPKInstallDisableScrollingReelsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideRepostButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideMetricsHooksIfEnabled);
    SPK_INSTALL(SPKInstallTappableTextLinksHooksIfEnabled);
}

void SPKInstallMessagesSurfaceHooksIfNeeded(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"Messages");
    SPK_INSTALL(SPKInstallTweakMessagesHooksIfNeeded);
    SPK_INSTALL(SPKInstallDirectAutoSaveHooksIfEnabled);
    SPK_INSTALL(SPKInstallMessagesActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallAggregatedMediaActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallSeenButtonHooksIfNeeded);
    SPK_INSTALL(SPKInstallCreateGroupButtonControlHooksIfEnabled);
    SPK_INSTALL(SPKInstallConfirmSendHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideMetaAIHooksIfEnabled);
    SPK_INSTALL(SPKInstallDisableDMStorySeenHooksIfNeeded);
    SPK_INSTALL(SPKInstallDisableInstantsCreationHooksIfEnabled);
    SPK_INSTALL(SPKInstallInstantsActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallInstantsAutoSaveHooksIfEnabled);
    SPK_INSTALL(SPKInstallInstantsAllowScreenshotHooksIfEnabled);
    SPK_INSTALL(SPKInstallInstantsReactionConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallInstantsGalleryUploadHooksIfEnabled);
    SPK_INSTALL(SPKInstallVisualMsgModifierHooksIfEnabled);
    SPK_INSTALL(SPKInstallNoSuggestedChatsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHiddenChatsHooksIfEnabled);
    SPK_INSTALL(SPKInstallChangeThemeConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallFollowRequestConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallDisableTypingStatusHooksIfEnabled);
    SPK_INSTALL(SPKInstallFullLastActiveHooksIfEnabled);
    SPK_INSTALL(SPKInstallPresenceNotificationsHooksIfEnabled);
    SPK_INSTALL(SPKInstallShhConfirmHooksIfNeeded);
    SPK_INSTALL(SPKInstallHideFriendsMapHooksIfEnabled);
    SPK_INSTALL(SPKInstallKeepDeletedMessagesHooksIfEnabled);
    SPK_INSTALL(SPKInstallCallConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallDMAudioMsgConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallDMInteractionConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallDMRefreshConfirmHooksIfEnabled);
    SPK_INSTALL(SPKInstallDirectMessageMenuHooksIfNeeded);
    SPK_INSTALL(SPKInstallNotesActionsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideDirectCallButtonsHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideFlagButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallUnlockMessagePreviewHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideRecentSearchesHooksIfEnabled);
    SPK_INSTALL(SPKInstallDetailedColorPickerHooksIfEnabled);
    SPK_INSTALL(SPKInstallHeaderActionButtonHooksIfEnabled);
}

void SPKInstallProfileSurfaceHooksIfNeeded(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"Profile");
    SPK_INSTALL(SPKInstallProfileActionButtonHooksIfEnabled);
    SPK_INSTALL(SPKInstallProfilePhotoZoomHooksIfEnabled);
    SPK_INSTALL(SPKInstallFollowConfirmHooksIfNeeded);
    SPK_INSTALL(SPKInstallNoSuggestedUsersHooksIfEnabled);
    SPK_INSTALL(SPKInstallFollowIndicatorHooksIfEnabled);
    SPK_INSTALL(SPKInstallProfileHeaderControlsHooksIfNeeded);
    SPK_INSTALL(SPKInstallProfileAnalyzerVisitTrackerHooksIfEnabled);
    SPK_INSTALL(SPKInstallSettingsShortcutsHooksIfNeeded);
}

void SPKInstallGeneralUIHooksIfNeeded(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKHookBisectSetCurrentSurface(@"General UI");
    SPK_INSTALL(SPKInstallAccountSwitchHooksIfNeeded);
    SPK_INSTALL(SPKInstallTweakGeneralUIHooksIfNeeded);
    SPK_INSTALL(SPKInstallSharedLinkCleanupHooksIfEnabled);
    SPK_INSTALL(SPKInstallShareLongPressCopyHooksIfNeeded);
    SPK_INSTALL(SPKInstallHideMetaAIHooksIfEnabled);
    SPK_INSTALL(SPKInstallNoSuggestedUsersHooksIfEnabled);
    SPK_INSTALL(SPKInstallOpenLinkFromClipboardHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideExploreGridHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideTrendingSearchesHooksIfEnabled);
    SPK_INSTALL(SPKInstallCustomFontHooksIfEnabled);
    SPK_INSTALL(SPKInstallNavigationHooksIfNeeded);
    SPK_INSTALL(SPKInstallSettingsShortcutsHooksIfNeeded);
    SPK_INSTALL(SPKInstallDisableHapticsHooksIfEnabled);
    SPK_INSTALL(SPKInstallCopyDescriptionHooksIfEnabled);
    SPK_INSTALL(SPKInstallHideRecentSearchesHooksIfEnabled);
    SPK_INSTALL(SPKInstallSearchBarIconRemapHooksIfNeeded);
    SPK_INSTALL(SPKInstallEnhancedMediaResolutionHooksIfEnabled);
    SPK_INSTALL(SPKInstallAudioPageDownloadHooksIfNeeded);
    SPK_INSTALL(SPKInstallCaptureHidingHooksIfNeeded);
    SPK_INSTALL(SPKInstallFixDuplicateNotificationsHooksIfNeeded);
    SPK_INSTALL(SPKInstallOpenPostNativePushHooksIfNeeded);
}

void SPKInstallEnabledFeatureHooks(void) {
    if (SPKShouldSuppressFeatureHooks()) {
        SPKInstallEssentialAccessHooks();
        return;
    }
    SPKInstallGeneralUIHooksIfNeeded();
    SPKInstallFeedSurfaceHooksIfNeeded();
    SPKInstallStorySurfaceHooksIfNeeded();
    SPKInstallReelsSurfaceHooksIfNeeded();
    SPKInstallMessagesSurfaceHooksIfNeeded();
    SPKInstallProfileSurfaceHooksIfNeeded();
}
