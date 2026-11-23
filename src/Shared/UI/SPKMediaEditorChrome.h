#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// The container every Sparkle media editor (trim, video crop, photo) is shown
/// in: full screen, always dark, with native bars so the system renders them as
/// Liquid Glass on iOS 26 and moves them into the side column on iPhone Duo.
///
/// Editors opened from another editor (Crop and Edit Frame from the trimmer) are
/// pushed onto the same stack with a crossfade instead of being presented as a
/// second modal, so the whole edit reads as one screen.
@interface SPKMediaEditorNavigationController : UINavigationController
@end

/// Presents `editor` in a new `SPKMediaEditorNavigationController`.
FOUNDATION_EXPORT void SPKMediaEditorPresent(UIViewController *editor, UIViewController *presenter);

/// Shows `editor` from inside another editor: pushed with a crossfade when
/// `host` sits in an editor stack, otherwise presented on its own.
FOUNDATION_EXPORT void SPKMediaEditorOpenFromEditor(UIViewController *editor, UIViewController *host);

/// Closes an editor the way it was opened: pops it when it was pushed onto an
/// editor stack, otherwise dismisses the whole stack. `completion` runs once the
/// editor is gone (immediately after a pop starts, since the host stays on
/// screen underneath).
FOUNDATION_EXPORT void SPKMediaEditorClose(UIViewController *editor, void (^_Nullable completion)(void));

/// YES when `editor` was pushed onto another editor (Crop or Edit Frame over
/// the trimmer) rather than being the root of its stack.
FOUNDATION_EXPORT BOOL SPKMediaEditorIsPushed(UIViewController *editor);

/// Points the editor's leading cancel item the right way: a back chevron when
/// closing returns to the editor underneath, the close cross when it leaves the
/// edit altogether. Call from viewWillAppear, once the stack is known.
FOUNDATION_EXPORT void SPKMediaEditorConfigureCancelItem(UIBarButtonItem *item, UIViewController *editor);

/// Closes the editor after asking whether to drop its changes, or straight away
/// when there are none. `discard` runs only once the user confirms (or at once
/// without changes) and does the actual closing.
FOUNDATION_EXPORT void SPKMediaEditorConfirmDiscard(UIViewController *editor, BOOL hasChanges, void (^discard)(void));

/// Styles one item of a toolbar switch (the trimmer's modes): the selected
/// item in Instagram blue, the others in the plain glyph color, with the
/// selected trait for VoiceOver.
FOUNDATION_EXPORT void SPKMediaEditorSetSwitchItemSelected(UIBarButtonItem *item, BOOL selected);

/// YES when the editor should put its controls beside the media rather than
/// under it: a short display (landscape, or iPhone Duo folded on its side) or a
/// regular-width one (iPhone Duo unfolded, iPad).
FOUNDATION_EXPORT BOOL SPKMediaEditorPrefersSideControls(UITraitCollection *traits, CGSize size);

NS_ASSUME_NONNULL_END
