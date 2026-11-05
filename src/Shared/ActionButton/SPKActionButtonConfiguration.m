#import "SPKStrings.h"
#import "SPKActionButtonConfiguration.h"
#import "../../Settings/SPKPreferences.h"
#import "../../Utils.h"
#import "SPKActionDescriptor.h"

static NSArray<NSString *> *SPKFilteredActionArray(NSArray *values, NSArray<NSString *> *supported) {
    NSMutableOrderedSet<NSString *> *filtered = [NSMutableOrderedSet orderedSet];
    for (id value in values) {
        if ([value isKindOfClass:[NSString class]] && [supported containsObject:value]) {
            [filtered addObject:value];
        }
    }
    return filtered.array;
}

static NSArray<NSString *> *SPKFilteredUniqueActionArray(NSArray *values, NSArray<NSString *> *supported) {
    return SPKFilteredActionArray(values, supported);
}

static NSString *SPKDefaultSectionTitleKey(NSString *identifier) {
    return @{
        @"more" : @"MESSAGES_DELETED_MESSAGES_MORE_TEXT",
        @"audio" : @"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_TITLE",
        @"zoom" : @"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_ZOOM_TEXT",
        @"copy" : @"FEED_COMMENT_ACTIONS_COPY_TEXT",
        @"download" : @"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_DOWNLOAD_TEXT",
        @"bulk" : @"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_BULK_TEXT",
    }[identifier];
}

// Before i18n, and during its first implementation, default section titles
// were persisted as display text. Recognize a default in any shipped language
// and resolve it again for the active language. Anything else is a real user
// override and must remain exactly as entered.
static void SPKRelocalizePersistedDefaultSectionTitle(SPKActionMenuSection *section) {
    NSString *key = SPKDefaultSectionTitleKey(section.identifier);
    if (key.length == 0 || section.title.length == 0)
        return;
    for (NSString *language in [SPKStrings supportedLanguages]) {
        if ([section.title isEqualToString:[SPKStrings localized:key forLanguage:language]]) {
            section.title = SPKL(key);
            return;
        }
    }
}

NSString *SPKActionButtonTopicKeyForSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
        return @"feed";
    case SPKActionButtonSourceReels:
        return @"reels";
    case SPKActionButtonSourceStories:
        return @"stories";
    case SPKActionButtonSourceDirect:
        return @"msgs";
    case SPKActionButtonSourceProfile:
        return @"profile";
    case SPKActionButtonSourceInstants:
        return @"instants";
    }
}

NSString *SPKActionButtonTopicTitleForSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
        return SPKL(@"FEED_TITLE");
    case SPKActionButtonSourceReels:
        return SPKL(@"REELS_TITLE");
    case SPKActionButtonSourceStories:
        return SPKL(@"STORIES_OTHER_STORIES_TITLE");
    case SPKActionButtonSourceDirect:
        return SPKL(@"MESSAGES_CONFIRMATION_MESSAGES_TITLE");
    case SPKActionButtonSourceProfile:
        return SPKL(@"PROFILE_TITLE");
    case SPKActionButtonSourceInstants:
        return SPKL(@"INSTANTS_CONFIRMATION_INSTANTS_TITLE");
    }
}

NSArray<NSString *> *SPKActionButtonSupportedActionsForSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceReels:
        return @[
            kSPKActionDownloadLibrary,
            kSPKActionDownloadShare,
            kSPKActionCopyDownloadLink,
            kSPKActionCopyMedia,
            kSPKActionDownloadGallery,
            kSPKActionTrimSave,
            kSPKActionEditSave,
            kSPKActionDownloadAudio,
            kSPKActionDownloadAudioShare,
            kSPKActionDownloadAudioGallery,
            kSPKActionPlayAudio,
            kSPKActionCopyAudioURL,
            kSPKActionExpand,
            kSPKActionViewThumbnail,
            kSPKActionCopyCaption,
            kSPKActionOpenTopicSettings,
            kSPKActionRepost
        ];
    case SPKActionButtonSourceStories:
        return @[
            kSPKActionDownloadLibrary,
            kSPKActionDownloadShare,
            kSPKActionCopyDownloadLink,
            kSPKActionCopyMedia,
            kSPKActionDownloadGallery,
            kSPKActionTrimSave,
            kSPKActionEditSave,
            kSPKActionDownloadAudio,
            kSPKActionDownloadAudioShare,
            kSPKActionDownloadAudioGallery,
            kSPKActionPlayAudio,
            kSPKActionCopyAudioURL,
            kSPKActionExpand,
            kSPKActionViewThumbnail,
            kSPKActionStoryMentionsSheet,
            kSPKActionToggleStorySeenUserRule,
            kSPKActionToggleStoryAutoSaveUserRule,
            kSPKActionOpenTopicSettings
        ];
    case SPKActionButtonSourceDirect:
        return @[
            kSPKActionDownloadLibrary,
            kSPKActionDownloadShare,
            kSPKActionCopyDownloadLink,
            kSPKActionCopyMedia,
            kSPKActionDownloadGallery,
            kSPKActionTrimSave,
            kSPKActionEditSave,
            kSPKActionDownloadAudio,
            kSPKActionDownloadAudioShare,
            kSPKActionDownloadAudioGallery,
            kSPKActionPlayAudio,
            kSPKActionCopyAudioURL,
            kSPKActionExpand,
            kSPKActionViewThumbnail,
            kSPKActionDeletedMessagesLog,
            kSPKActionToggleDirectAutoSaveThreadRule,
            kSPKActionOpenTopicSettings
        ];
    case SPKActionButtonSourceInstants:
        return @[
            kSPKActionDownloadLibrary,
            kSPKActionDownloadShare,
            kSPKActionCopyDownloadLink,
            kSPKActionCopyMedia,
            kSPKActionDownloadGallery,
            kSPKActionTrimSave,
            kSPKActionEditSave,
            kSPKActionExpand,
            kSPKActionViewThumbnail,
            kSPKActionToggleInstantsAutoSaveUserRule,
            kSPKActionToggleInstantsManualSeenUserRule,
            kSPKActionOpenTopicSettings
        ];
    case SPKActionButtonSourceProfile:
        return @[
            kSPKActionDownloadLibrary,
            kSPKActionDownloadShare,
            kSPKActionCopyDownloadLink,
            kSPKActionCopyMedia,
            kSPKActionDownloadGallery,
            kSPKActionEditSave,
            kSPKActionExpand,
            kSPKActionProfileCopyInfo,
            kSPKActionToggleProfileStorySeenUserRule,
            kSPKActionToggleProfileMessagesSeenUserRule,
            kSPKActionOpenTopicSettings
        ];
    }
}

NSArray<NSString *> *SPKActionButtonBulkDownloadSupportedActionsForSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceReels:
    case SPKActionButtonSourceStories:
    case SPKActionButtonSourceInstants:
    case SPKActionButtonSourceDirect:
        return @[
            kSPKActionDownloadAllLibrary,
            kSPKActionDownloadAllShare,
            kSPKActionDownloadAllGallery
        ];
    case SPKActionButtonSourceProfile:
        return @[];
    }
}

NSArray<NSString *> *SPKActionButtonBulkCopySupportedActionsForSource(SPKActionButtonSource source) {
    switch (source) {
    case SPKActionButtonSourceFeed:
    case SPKActionButtonSourceReels:
    case SPKActionButtonSourceStories:
    case SPKActionButtonSourceInstants:
    case SPKActionButtonSourceDirect:
        return @[
            kSPKActionDownloadAllClipboard,
            kSPKActionDownloadAllLinks
        ];
    case SPKActionButtonSourceProfile:
        return @[];
    }
}

// Maps a single-item action identifier to its bulk "all" counterpart, or nil
// when the action has no bulk equivalent.
static NSString *SPKBulkAllIdentifierForBaseAction(NSString *identifier) {
    if ([identifier isEqualToString:kSPKActionDownloadLibrary])
        return kSPKActionDownloadAllLibrary;
    if ([identifier isEqualToString:kSPKActionDownloadShare])
        return kSPKActionDownloadAllShare;
    if ([identifier isEqualToString:kSPKActionDownloadGallery])
        return kSPKActionDownloadAllGallery;
    if ([identifier isEqualToString:kSPKActionCopyMedia])
        return kSPKActionDownloadAllClipboard;
    if ([identifier isEqualToString:kSPKActionCopyDownloadLink])
        return kSPKActionDownloadAllLinks;
    return nil;
}

// Bulk destinations are derived from the user's single-item action config:
// every enabled single-item download/copy action contributes its bulk-all
// counterpart, in the same order. This keeps the "Bulk" menu in lockstep with
// the rest of the action button (no separate bulk store / editor).
static NSArray<NSString *> *SPKDerivedBulkActionsForSource(SPKActionButtonSource source, NSArray<NSString *> *supportedBulk) {
    if (supportedBulk.count == 0)
        return @[];
    SPKActionButtonConfiguration *configuration =
        [SPKActionButtonConfiguration configurationForSource:source
                                                  topicTitle:SPKActionButtonTopicTitleForSource(source)
                                            supportedActions:SPKActionButtonSupportedActionsForSource(source)
                                             defaultSections:SPKActionButtonDefaultSectionsForSource(source)];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (SPKActionMenuSection *section in [configuration visibleSections]) {
        for (NSString *identifier in section.actions) {
            NSString *bulk = SPKBulkAllIdentifierForBaseAction(identifier);
            if (bulk && [supportedBulk containsObject:bulk]) {
                [result addObject:bulk];
            }
        }
    }
    return result.array;
}

NSArray<NSString *> *SPKActionButtonConfiguredBulkDownloadActionsForSource(SPKActionButtonSource source) {
    return SPKDerivedBulkActionsForSource(source, SPKActionButtonBulkDownloadSupportedActionsForSource(source));
}

NSArray<NSString *> *SPKActionButtonConfiguredBulkCopyActionsForSource(SPKActionButtonSource source) {
    return SPKDerivedBulkActionsForSource(source, SPKActionButtonBulkCopySupportedActionsForSource(source));
}

NSArray<SPKActionMenuSection *> *SPKActionButtonDefaultSectionsForSource(SPKActionButtonSource source) {
    NSMutableArray<SPKActionMenuSection *> *sections = [NSMutableArray array];
    NSArray<NSString *> *downloadActions = @[
        kSPKActionDownloadLibrary,
        kSPKActionDownloadShare,
        kSPKActionDownloadGallery,
        kSPKActionEditSave,
        kSPKActionTrimSave
    ];
    NSArray<NSString *> *audioActions = (source == SPKActionButtonSourceFeed ||
                                         source == SPKActionButtonSourceReels ||
                                         source == SPKActionButtonSourceStories ||
                                         source == SPKActionButtonSourceDirect)
                                            ? @[
                                                  kSPKActionDownloadAudio,
                                                  kSPKActionDownloadAudioShare,
                                                  kSPKActionDownloadAudioGallery,
                                                  kSPKActionPlayAudio,
                                                  kSPKActionCopyAudioURL
                                              ]
                                            : @[];
    // Zoom: expand + view thumbnail (profile has no thumbnail).
    NSArray<NSString *> *zoomActions = (source == SPKActionButtonSourceProfile)
                                           ? @[ kSPKActionExpand ]
                                           : @[ kSPKActionExpand, kSPKActionViewThumbnail ];
    NSArray<NSString *> *copyActions = (source == SPKActionButtonSourceProfile)
                                           ? @[ kSPKActionCopyDownloadLink, kSPKActionCopyMedia, kSPKActionProfileCopyInfo ]
                                           : ((source == SPKActionButtonSourceFeed || source == SPKActionButtonSourceReels)
                                                  ? @[ kSPKActionCopyDownloadLink, kSPKActionCopyMedia, kSPKActionCopyCaption ]
                                                  : @[ kSPKActionCopyDownloadLink, kSPKActionCopyMedia ]);
    NSArray<NSString *> *moreActions;
    if (source == SPKActionButtonSourceFeed || source == SPKActionButtonSourceReels) {
        moreActions = @[ kSPKActionRepost, kSPKActionOpenTopicSettings ];
    } else if (source == SPKActionButtonSourceStories) {
        moreActions = @[ kSPKActionStoryMentionsSheet, kSPKActionToggleStorySeenUserRule, kSPKActionToggleStoryAutoSaveUserRule, kSPKActionOpenTopicSettings ];
    } else if (source == SPKActionButtonSourceDirect) {
        moreActions = @[ kSPKActionDeletedMessagesLog, kSPKActionToggleDirectAutoSaveThreadRule, kSPKActionOpenTopicSettings ];
    } else if (source == SPKActionButtonSourceProfile) {
        moreActions = @[ kSPKActionToggleProfileStorySeenUserRule, kSPKActionToggleProfileMessagesSeenUserRule, kSPKActionOpenTopicSettings ];
    } else if (source == SPKActionButtonSourceInstants) {
        moreActions = @[ kSPKActionToggleInstantsAutoSaveUserRule, kSPKActionToggleInstantsManualSeenUserRule, kSPKActionOpenTopicSettings ];
    } else {
        moreActions = @[ kSPKActionOpenTopicSettings ];
    }

    if (moreActions.count > 0) {
        [sections addObject:[SPKActionMenuSection sectionWithIdentifier:@"more"
                                                                  title:SPKL(@"MESSAGES_DELETED_MESSAGES_MORE_TEXT")
                                                               iconName:@"more"
                                                            collapsible:YES
                                                                actions:moreActions]];
    }
    if (audioActions.count > 0) {
        [sections addObject:[SPKActionMenuSection sectionWithIdentifier:@"audio"
                                                                  title:SPKL(@"MESSAGES_DIRECT_MESSAGE_MENU_AUDIO_TITLE")
                                                               iconName:@"audio_upload"
                                                            collapsible:YES
                                                                actions:audioActions]];
    }
    if (zoomActions.count > 0) {
        [sections addObject:[SPKActionMenuSection sectionWithIdentifier:@"zoom"
                                                                  title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_ZOOM_TEXT")
                                                               iconName:@"zoom"
                                                            collapsible:YES
                                                                actions:zoomActions]];
    }
    [sections addObject:[SPKActionMenuSection sectionWithIdentifier:@"copy"
                                                              title:SPKL(@"FEED_COMMENT_ACTIONS_COPY_TEXT")
                                                           iconName:@"copy"
                                                        collapsible:YES
                                                            actions:copyActions]];
    [sections addObject:[SPKActionMenuSection sectionWithIdentifier:@"download"
                                                              title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_DOWNLOAD_TEXT")
                                                           iconName:@"download"
                                                        collapsible:YES
                                                            actions:downloadActions]];
    return sections;
}

@implementation SPKActionButtonConfiguration

+ (instancetype)configurationForSource:(SPKActionButtonSource)source
                            topicTitle:(NSString *)topicTitle
                      supportedActions:(NSArray<NSString *> *)supportedActions
                       defaultSections:(NSArray<SPKActionMenuSection *> *)defaultSections {
    SPKActionButtonConfiguration *configuration = [[self alloc] init];
    configuration.source = source;
    configuration.topicTitle = topicTitle.length > 0 ? topicTitle : SPKActionButtonTopicTitleForSource(source);
    configuration.supportedActions = supportedActions.count > 0 ? supportedActions : SPKActionButtonSupportedActionsForSource(source);
    configuration.sections = [NSMutableArray array];
    configuration.disabledActions = [NSMutableArray array];
    configuration.unassignedActions = [NSMutableArray array];

    id storedValue = SPKPreferenceObjectForKey([configuration configDefaultsKey]);
    NSDictionary *stored = [storedValue isKindOfClass:[NSDictionary class]] ? storedValue : nil;
    if ([stored isKindOfClass:[NSDictionary class]]) {
        NSArray *storedSections = [stored[@"sections"] isKindOfClass:[NSArray class]] ? stored[@"sections"] : @[];
        for (NSDictionary *dictionary in storedSections) {
            SPKActionMenuSection *section = [SPKActionMenuSection sectionFromDictionary:dictionary];
            if (section) {
                SPKRelocalizePersistedDefaultSectionTitle(section);
                [configuration.sections addObject:section];
            }
        }
        [configuration.disabledActions addObjectsFromArray:SPKFilteredActionArray(stored[@"disabled_actions"], configuration.supportedActions)];
        [configuration.unassignedActions addObjectsFromArray:SPKFilteredActionArray(stored[@"unassigned_actions"], configuration.supportedActions)];
    }

    if (configuration.sections.count == 0) {
        for (SPKActionMenuSection *section in (defaultSections.count > 0 ? defaultSections : SPKActionButtonDefaultSectionsForSource(source))) {
            [configuration.sections addObject:[section copy]];
        }
    }

    // Ensure a reorderable "Bulk" section exists on sources that support bulk
    // downloads. Its contents are derived from the single-item actions, so it has
    // no stored actions of its own; users reorder/rename it like any section.
    // Injected here (not only in the defaults) so existing persisted configs pick
    // it up too. Profile has no bulk support, so it is skipped there.
    if (SPKActionButtonBulkDownloadSupportedActionsForSource(source).count > 0 ||
        SPKActionButtonBulkCopySupportedActionsForSource(source).count > 0) {
        BOOL hasBulkSection = NO;
        for (SPKActionMenuSection *section in configuration.sections) {
            if ([section.identifier isEqualToString:@"bulk"]) {
                hasBulkSection = YES;
                break;
            }
        }
        if (!hasBulkSection) {
            SPKActionMenuSection *bulkSection = [SPKActionMenuSection sectionWithIdentifier:@"bulk"
                                                                                      title:SPKL(@"ACTION_BUTTON_ACTION_BUTTON_CONFIGURATION_BULK_TEXT")
                                                                                   iconName:@"carousel"
                                                                                collapsible:YES
                                                                                    actions:@[]];
            // Appended last so the Bulk section is the bottom-most when available.
            [configuration.sections addObject:bulkSection];
        }
    }

    // Adopt the Instants auto-save toggle into configs saved before it existed.
    // Without this, `normalize` files any newly supported action under "unassigned",
    // so an existing user would never see the action unless they went looking for it
    // in the action editor -- and the whole point of the action is discoverability.
    // Only configs that have never mentioned it are touched: once the editor saves,
    // a deliberate unassign or disable is recorded and respected from then on.
    if (stored && source == SPKActionButtonSourceInstants) {
        [configuration adoptAction:kSPKActionToggleInstantsAutoSaveUserRule intoSectionWithIdentifier:@"more"];
        [configuration adoptAction:kSPKActionToggleInstantsManualSeenUserRule intoSectionWithIdentifier:@"more"];
    }

    [configuration normalize];
    return configuration;
}

- (void)adoptAction:(NSString *)identifier intoSectionWithIdentifier:(NSString *)sectionIdentifier {
    if (![self.supportedActions containsObject:identifier])
        return;
    if ([self.disabledActions containsObject:identifier] || [self.unassignedActions containsObject:identifier])
        return;
    for (SPKActionMenuSection *section in self.sections) {
        if ([section.actions containsObject:identifier])
            return;
    }

    SPKActionMenuSection *target = [self sectionWithIdentifier:sectionIdentifier];
    if (!target)
        return; // the user removed the section; leave the action unassigned
    target.actions = [target.actions arrayByAddingObject:identifier];
}

- (NSString *)configDefaultsKey {
    return SPKPrefActionButtonConfigKey(SPKActionButtonTopicKeyForSource(self.source));
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableArray *sectionDictionaries = [NSMutableArray array];
    for (SPKActionMenuSection *section in self.sections) {
        [sectionDictionaries addObject:[section dictionaryRepresentation]];
    }
    return @{
        @"sections" : sectionDictionaries,
        @"disabled_actions" : [self.disabledActions copy] ?: @[],
        @"unassigned_actions" : [self.unassignedActions copy] ?: @[]
    };
}

- (void)save {
    [self normalize];
    SPKPreferenceSetObject([self dictionaryRepresentation], [self configDefaultsKey]);
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
}

- (NSArray<NSString *> *)assignedActions {
    NSMutableOrderedSet<NSString *> *assigned = [NSMutableOrderedSet orderedSet];
    for (SPKActionMenuSection *section in self.sections) {
        for (NSString *identifier in section.actions) {
            if ([self.supportedActions containsObject:identifier]) {
                [assigned addObject:identifier];
            }
        }
    }
    return assigned.array;
}

- (void)normalize {
    NSArray<NSString *> *supported = self.supportedActions ?: @[];
    NSMutableOrderedSet<NSString *> *seen = [NSMutableOrderedSet orderedSet];
    NSMutableArray<SPKActionMenuSection *> *normalizedSections = [NSMutableArray array];

    for (SPKActionMenuSection *section in self.sections ?: @[]) {
        if (![section isKindOfClass:[SPKActionMenuSection class]])
            continue;
        if (section.identifier.length == 0)
            section.identifier = NSUUID.UUID.UUIDString;
        if (section.title.length == 0)
            section.title = SPKL(@"SETTINGS_ACTION_SECTION_EDIT_SECTION_TEXT");
        if (section.iconName.length == 0)
            section.iconName = @"more";

        NSArray<NSString *> *filteredActions = SPKFilteredActionArray(section.actions, supported);
        NSMutableArray<NSString *> *uniqueActions = [NSMutableArray array];
        for (NSString *identifier in filteredActions) {
            if ([seen containsObject:identifier])
                continue;
            [seen addObject:identifier];
            [uniqueActions addObject:identifier];
        }
        section.actions = uniqueActions;
        [normalizedSections addObject:section];
    }

    self.sections = normalizedSections;
    self.disabledActions = [SPKFilteredActionArray(self.disabledActions, supported) mutableCopy];

    NSMutableOrderedSet<NSString *> *unassigned = [NSMutableOrderedSet orderedSetWithArray:SPKFilteredActionArray(self.unassignedActions, supported)];
    for (NSString *identifier in supported) {
        if (![seen containsObject:identifier]) {
            [unassigned addObject:identifier];
        }
    }
    self.unassignedActions = unassigned.array.mutableCopy;
}

- (nullable SPKActionMenuSection *)sectionWithIdentifier:(NSString *)identifier {
    for (SPKActionMenuSection *section in self.sections) {
        if ([section.identifier isEqualToString:identifier])
            return section;
    }
    return nil;
}

- (NSArray<SPKActionMenuSection *> *)visibleSections {
    NSMutableArray<SPKActionMenuSection *> *visible = [NSMutableArray array];
    for (SPKActionMenuSection *section in self.sections) {
        NSMutableArray<NSString *> *actions = [NSMutableArray array];
        for (NSString *identifier in section.actions) {
            if (![self.disabledActions containsObject:identifier] && ![self.unassignedActions containsObject:identifier]) {
                [actions addObject:identifier];
            }
        }
        if (actions.count == 0)
            continue;
        [visible addObject:[SPKActionMenuSection sectionWithIdentifier:section.identifier
                                                                 title:section.title
                                                              iconName:section.iconName
                                                           collapsible:section.collapsible
                                                               actions:actions]];
    }
    return visible;
}

- (nullable NSString *)sectionIdentifierForAction:(NSString *)identifier {
    for (SPKActionMenuSection *section in self.sections) {
        if ([section.actions containsObject:identifier]) {
            return section.identifier;
        }
    }
    return nil;
}

- (void)setAction:(NSString *)identifier assignedToSectionIdentifier:(NSString *)sectionIdentifier {
    if (![self.supportedActions containsObject:identifier])
        return;

    for (SPKActionMenuSection *section in self.sections) {
        [section.actions removeObject:identifier];
    }
    [self.unassignedActions removeObject:identifier];

    if (sectionIdentifier.length > 0) {
        SPKActionMenuSection *section = [self sectionWithIdentifier:sectionIdentifier];
        if (section && ![section.actions containsObject:identifier]) {
            [section.actions addObject:identifier];
        }
    } else {
        if (![self.unassignedActions containsObject:identifier]) {
            [self.unassignedActions addObject:identifier];
        }
    }
    [self normalize];
}

- (void)moveSectionFromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex {
    if (sourceIndex < 0 || destinationIndex < 0 || sourceIndex >= self.sections.count || destinationIndex >= self.sections.count)
        return;
    SPKActionMenuSection *section = self.sections[sourceIndex];
    [self.sections removeObjectAtIndex:sourceIndex];
    [self.sections insertObject:section atIndex:destinationIndex];
}

- (void)moveActionInSectionIdentifier:(NSString *)sectionIdentifier fromIndex:(NSInteger)sourceIndex toIndex:(NSInteger)destinationIndex {
    SPKActionMenuSection *section = [self sectionWithIdentifier:sectionIdentifier];
    if (!section)
        return;
    if (sourceIndex < 0 || destinationIndex < 0 || sourceIndex >= section.actions.count || destinationIndex >= section.actions.count)
        return;
    NSString *identifier = section.actions[sourceIndex];
    [section.actions removeObjectAtIndex:sourceIndex];
    [section.actions insertObject:identifier atIndex:destinationIndex];
}

@end

NSArray<NSString *> *SPKProfileCopyInfoSupportedActions(void) {
    return @[
        kSPKActionProfileCopyID,
        kSPKActionProfileCopyUsername,
        kSPKActionProfileCopyName,
        kSPKActionProfileCopyBio,
        kSPKActionProfileCopyLink
    ];
}

NSArray<NSString *> *SPKProfileConfiguredCopyInfoActions(void) {
    NSArray<NSString *> *supported = SPKProfileCopyInfoSupportedActions();
    id storedValue = SPKPreferenceObjectForKey(@"profile_action_btn_copy_info_submenu_actions");
    NSArray *stored = [storedValue isKindOfClass:[NSArray class]] ? storedValue : nil;
    NSArray<NSString *> *filtered = SPKFilteredUniqueActionArray(stored, supported);
    return filtered.count > 0 ? filtered : supported;
}

void SPKProfileSetConfiguredCopyInfoActions(NSArray<NSString *> *actions) {
    SPKPreferenceSetObject(SPKFilteredUniqueActionArray(actions, SPKProfileCopyInfoSupportedActions()),
                           @"profile_action_btn_copy_info_submenu_actions");
    [[NSNotificationCenter defaultCenter] postNotificationName:SPKActionButtonConfigurationDidChangeNotification object:nil];
}
