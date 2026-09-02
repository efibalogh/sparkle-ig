# Sparkle Features

A complete catalog of Sparkle's options, grouped to mirror the in-app settings.

Most toggles take effect immediately. Options that rebuild Instagram UI are
marked **(restart)** and prompt for a relaunch when changed.

---

## Localization

- **Language** *(restart)*: Use the Translate button in the top-right of Sparkle Settings to open the language sheet. Sparkle ships English, and with nothing else installed English is the selection. Installing a language pack adds it to the same list, with how much of it is translated, and brings back a System Default row that follows Instagram first, then the device language, then English.
- The choice is device-wide, applies to every Instagram account after restart, and falls back to English when a language or individual string is unavailable.
- Sparkle-owned dates use the selected language's ordering, punctuation, and month names while retaining the device's 12/24-hour clock preference across Action Button menus, Gallery, Downloads, media details, logs, and diagnostics.
- Built-in collapsible Action Button section names follow the selected language. A section name explicitly customized by the user remains verbatim.
- **Import Language Pack**: Installs community translations from `.zip` archives, each containing a `<code>.lproj` folder. Several archives can be picked at once. Importing makes a language available without selecting it; the new entries appear in the list above, and switching is an explicit tap. Re-importing replaces the pack for that language, and swiping a language left removes it. An imported pack takes precedence over a shipped catalog of the same language, so a translator can preview corrections in place.
- **Export English Strings**: Shares the English catalog as a `.zip`, the file a new translation starts from.
- **Report a Translation Issue**: Opens the translation issue form, with the language prefilled when Sparkle is running in an imported one.
- **Contribute a Translation**: Opens the translation guide, for correcting a language or starting a new one.
- Translation quality: English is the only hand-written catalog and the only one Sparkle ships. The 16 community catalogs live in the repository as installable packs rather than in the app. They were machine translated and have not been reviewed by native speakers, so some strings read unnaturally or describe a setting inaccurately. A language ships with Sparkle once a native speaker has reviewed it.

---

## General

### Behavior
- **Copy Text**: Long-press text fields across the app to copy them.
- **Hide Recent Searches** *(restart)*: Hides existing recent searches and stops search bars from saving new queries.
- **Copy Links Without Tracking**: Strips the username path and tracking parameters from copied links.
- **Hold Send to Copy Link**: Long-press the send/share button to copy the post link.

### Sharing
- **Hide Create Group Button**: Hides the create group button on the Instagram send/share sheet.
- **Confirm Create Group**: Confirmation alert before creating a group on Instagram send/share sheet.
- **Confirm Send**: Confirmation alert before sending a post.

### Media Preview & Menu
- **Show Media Info**: Overlays the author and post date (including time for live previews) over the expanded photo preview. Tap the media to hide it together with the controls. (Photos only — video previews are left untouched so the scrubber and controls stay clear.)
- **Select Text in Photos**: Recognizes text in the expanded photo preview and floats two controls over it: a button that highlights the recognized text, and a **Copy All** capsule that copies the whole transcript. On iOS 26 both are real Liquid Glass, adapting to the photo behind them and springing under a press; on older versions they fall back to solid capsules that scale and lighten while held. The media info overlay steps aside while text is highlighted, so nothing sits on top of the controls. (Photos only. Requires iOS 16 or later on hardware VisionKit supports; the toggle is hidden elsewhere.)
- **Show Date in Menu**: Shows the exact date and time a post was made in the action button menu title.

### Recommendations
- **Ads**: Per-surface ad hiding: Feed, Stories, Reels, Explore, plus Reels shopping CTA. Ad filtering preserves native feed loading indicators, including on short or initially empty lists.
- **Meta AI**: Hide Meta AI in Direct, Explore & Search, Comments, Creation Tools, and global AI chrome. Hiding it in Explore & Search also restores the plain search glyph in the search bar (replacing the gen-AI search icon).
- **Suggested Users**: Hide suggested-user surfaces: Feed, Reels, Direct, Search, Profile, Activity, follow lists, and subscriptions.

### Comments
- **Swipe to Close Comments** + **Swipe Direction**: Adds a horizontal swipe-to-dismiss gesture to comment sheets.
- **Comment Menu Actions**: Adds opt-in comment text copying, plus Photos/Share/Gallery/clipboard actions and link copying for both GIF and photo comments (GIF gets a Giphy link, photo gets a direct image download link). Gallery saves use a dedicated `Comments` source.
- **Show GIF Title**: Long-press a GIF comment and its menu resolves the GIF's real name and the channel that uploaded it, with a tap to copy the name. Off by default, because each lookup asks giphy.com about that one GIF; nothing is requested until you open the menu, and results are cached for the session.
- **Confirm Comment Like**.
- **Hide Comment Shopping**: Removes commerce carousels in comment threads.
- **Hide Gifts Button**: Removes the Gifts shortcut from the comment composer and lets the input use the freed space.
- **Upload Photos from Gallery**: Long-press the composer's photo button to attach an image from your Sparkle Gallery (a normal tap still opens Instagram's photo picker).
- Comment options apply everywhere comments appear (feed, reels, etc.).

### Storage
- **Clear Cache**: Clears temporary caches now (shows current cache size). The confirmation notification reports how much was freed.
- **Auto Clear Cache**: Automatic clearing checked whenever Instagram becomes active: `Never`, `Always`, `Daily`, `Weekly`, `Monthly`.

### App
- **App Icon**: Choose an alternate icon from those exposed by the installed Instagram bundle.
- **Open Menu Icon**: Choose the glyph shown on every action button whose default tap action is **Open Menu**. A single global choice (not per-surface), picked from the same unified icon picker used everywhere else. Defaults to the Sparkle action glyph.
- **Disable App Haptics**: Turns off in-app haptics and vibrations.

### Accounts
- **Per-Account Settings**:
  - Gives each logged-in Instagram account its own Sparkle preferences. A newly seen account inherits your current settings until you change something. Switching accounts in-app applies the right set immediately. **(restart)**
  - Some settings stay shared accross accounts. A **How It Works** button lists the shared features in-app.

---

## Interface

### Notifications
Per-feature control of the Sparkle notification pill and its haptics. See **Notifications** below.

### Tabs
- **Tab Editor**: A single screen for the whole tab bar, with a live preview of the bar you are building. Every change is staged and committed together with one Apply action and restart prompt. **(restart)**
  - **Default**: Instagram picks the order; you can still hide tabs and choose where the app opens.
  - **Custom**: drag the handles to arrange Feed, Reels/Saved, Messages, Explore, and Profile in any order.
  - **Classic**: Instagram's legacy layout, with Messages in the feed header and Create back as a tab. Messages is not listed in this layout: it is the header link there, reachable by tapping it or by swiping, so there is no tab to hide.
  - Tap any tab to show or hide it, and drag its handle to move it. The last visible tab cannot be hidden.
  - **Launch Tab**: open Instagram on any visible destination. Left on Default, a custom layout opens on its first tab instead of always landing on Feed.
  - **Swipe Between Tabs**: follow Instagram, force on, or force off.
  - **Saved** is its own entry in the list, and it is offered in the **Custom layout only**: Default and Classic are Instagram's own arrangements, which it changes between releases. Instagram has no Saved surface of its own, so Saved borrows the slot of a hidden tab: turn one of the five Instagram tabs off and Saved can be switched on, then dragged anywhere in the bar. That keeps the bar at five tabs maximum. The whole tab bar setup is shared by every account on the device.
  - **Single Tab Mode** is its own section, always listed and greyed out until it applies.
    - **Hide Tab Bar** takes the bar away once the configuration leaves a single tab, for a clean single-surface interface. It is offered only where Sparkle Settings stays reachable without the tab bar long-press: with **Messages** (long-press the new message button) or with **Feed** while the **Feed Header Button** is on. Any other single tab keeps the bar, so you cannot hide your way out of Sparkle.
    - **Messages Header Button** adds the Sparkle shortcut to the left of the Messages navigation bar, for when Messages is the tab that is left.
  - Leaving the editor keeps your changes staged instead of prompting: come back and they are still there, with Apply waiting. **Discard Changes** puts everything back to the configuration in use, and **Reset to Instagram Default** stages the stock layout. Neither writes anything until you apply.
- Settings access is safeguarded elsewhere too: if Quick Settings Access is on but the Home tab is hidden (or taken by the Gallery shortcut), the long-press to open Sparkle Settings automatically moves to another visible tab.

### Appearance
- **App Font**: Replaces Instagram's typeface with a font you import. **(restart)**
  - Import `.otf`, `.ttf`, or `.ttc` files with the **+** button. A specimen card at the top shows the selected font at a readable size across Regular, Medium, and Bold, so a family missing a real bold is obvious before you commit to it; each row below is set in its own typeface. Files live inside Sparkle, so uninstalling takes them with it.
  - The replacement covers both Instagram's own text and UIKit's, so the app, its alerts and keyboard, and Sparkle's own screens all follow. Only the *face* is replaced and never the size, so Dynamic Type and any text Instagram sizes specially keep working.
  - Left alone on purpose: Instagram's logo, the story text tool's fonts, and column-aligned numerals (timers, view counts), which would break or misalign if swapped.
  - A font family is matched per weight, so bold text stays bold if the family ships a bold face, and falls back to the nearest weight it does ship. Italic requests fall back to the upright face when there is no italic.
  - Restart to apply everywhere: text already on screen keeps the font it was built with. Deleting the last file of the font in use falls back to the default.
  - Shared by every account on the device, since fonts are resolved before Instagram knows which account is signed in.

### Explore & Search
- **Hide Explore Posts Grid**: Hides the suggested-post grid on Explore. This follows the active account when **Per-Account Settings** is enabled.
- **Hide Trending Searches** *(restart)*: Hides trending searches under the Explore search bar.
- **Open Clipboard Link**: Long-press the Explore tab to open an Instagram URL from the clipboard. When the Reels slot shows Saved, post and reel links use the same native single-post push as the Gallery so deep links do not disturb the tab destination.

### Capture
- **Hide UI on Capture**: Redacts Sparkle overlay buttons and labels (action button, seen/mentions buttons, poll vote-count badges, etc.) from screenshots, screen recordings, and mirroring.

### Liquid Glass *(iOS 26+)*
- **Liquid Glass**: Force-enables Instagram's native Liquid Glass UI for accounts/devices that don't already have it. **(restart)** Only ever forces it *on*; turning it off never suppresses Liquid Glass that Instagram already renders natively (server-rollout accounts) or that Sparkle's own screens (Gallery, Settings, etc.) pick up automatically from iOS 26: so Sparkle's UI never looks inconsistent with Instagram's regardless of this switch.
- **Progressive Blur**: Restores the native progressive navigation bar blur on scroll. Requires iOS 26 (relies on `UIScrollEdgeEffect`).
- **Tab Bar Behavior**: Controls how the floating Liquid Glass tab bar behaves while scrolling.

### Tab Bar *(iOS 18 and lower)*
On systems without Liquid Glass, the tab bar section is replaced by a focused toggle. The glass *material* is iOS 26+ only, but the floating pill *shape* comes from Instagram's tab bar experiment gates, which work on any iOS.
- **Pill-Shaped Tab Bar**: Reshapes the tab bar into the iOS 26-style floating pill. **(restart)** Shape only — no glass material on this device.
- **Tab Bar Behavior**: Controls how the pill tab bar behaves while scrolling (Default / Fixed / Hide on scroll).

---

## Feed

### Action Button
- **Feed Action Button**: Adds an action button to feed posts.
- **Default Tap Action** + **Configure Actions**: Single tap runs the chosen action; long-press opens the full, user-editable menu (sections).
- **Bulk**: On posts that support it (carousels with multiple downloadable items) the menu shows a **Bulk · N** section (N = carousel item count) with **Download All**, **Copy All**, and **Select Media**. Bulk is an ordinary section in **Configure Actions**: drag to reorder it, rename it, change its icon, or toggle collapsible, just like any other section. Its destinations are derived from your single-item action config (enabling/disabling or reordering a Download/Copy action carries straight into Bulk), so there is no separate bulk menu to configure. The section is resolved when the menu opens, so it appears reliably even on the first item of a story/reel. **Select Media** opens a grid picker to hand-pick a subset (tap to toggle, with a Select All/None control), then runs the chosen destination on just those items. Available from the action button and the full-screen media preview toolbar.
- **Single-element submenus inline**: Any section or submenu (built-in or custom: Download All, Copy All, Copy Info, etc.) that resolves to a single action is shown inline instead of as a one-item collapsible submenu.
- **Section icons**: Picking a section or submenu icon (including Bulk) opens the unified icon picker: a single searchable grid of the installed Instagram bundle's icons. There is no separate "shortcuts" row: your current icon is resolved and highlighted directly in the list. The same picker powers the App Icon and Open Menu Icon choosers.

### Header Shortcut
- **Feed Header Button** **(restart)**: Adds a Sparkle button to the home feed header, to the left of the notifications heart. In the classic tab layout (create button moved to the bottom bar) it docks on the far left instead, and it scrolls/fades away with Instagram's own header buttons.
- **Default Tap Action**: Tap runs the chosen action — **Open Menu** (default, button shows the Sparkle glyph) or jump straight to one destination (button mirrors that destination's icon). A long-press always opens the menu.
- **Destinations**: A sub-page to pick which sheets the button can open — **Sparkle Settings**, **Profile Analyzer**, **Gallery**, **Deleted Messages**, **Downloads**. Enable one for a direct tap or several to choose from the long-press menu. Changes apply when you return to the feed (no restart).

### Layout
- **Main Feed**: `For You` or `Following`. Following mode forces the chronological feed, keeps pagination and cold starts on that source, and removes the For You picker entry. **(restart)**
- **Disable App Icon Gesture**: Stops the feed header logo long-press from opening Instagram's app icon picker (Sparkle has its own under Settings).
- **Hide Stories Tray**, **Hide Entire Feed**, **Hide Suggested Posts**, **Hide Suggested Accounts**, **Hide Suggested Reels**, **Hide Suggested Threads**.
- **Hide Repost Button**: Removes the repost button from posts. **(restart)**

### Metrics
- **Hide Like / Comment / Repost / Reshare Count** under feed posts.

### Media
- **Long Press to Expand**: Long-press feed media to open the expanded viewer.
- **Disable Video Autoplay**: Prevents feed videos from auto-playing. **(restart)**
- **Start Expanded Videos Muted**: Expanded videos open muted.

### Refresh
- **Disable Home Tab Refresh**: No refresh when re-tapping the Home tab.
- **Disable Background Refresh**: Prevents background feed refresh.

### Confirmation
- **Confirm Like**, **Confirm Double Tap**, **Confirm Repost**, **Confirm Posting Comment**.

---

## Stories

### Action Button
- **Stories Action Button**, **Default Tap Action**, **Configure Actions**: As with feed; placed above the bottom story bar.

### Seen Receipts
- **Manually Mark Seen**: Suppresses automatic seen receipts and adds an eye button to mark a story seen.
- **Included / Excluded Users**: Two separate per-account lists, selected by Manually Mark Seen: when off, the *Included Users* list (only those users get the eye button / require manual seen); when on, the *Excluded Users* list (those users keep normal automatic seen). Each list is independent and stored per account. Manageable from the eye button, long-press, or the list.
- **Mark Seen on Like**, **Mark Seen on Reply**: disabled unless Manually Mark Seen is on.

### Story Navigation
- **Stop Auto Advance**: Prevents auto-advancing to the next story.
- **Advance on Eye Button / Story Like / Story Reply**: Advances after the respective mark-seen action.

### Confirmations
- **Confirm Like**, **Confirm Quick Reaction**, **Confirm Sticker Interaction**.

### Instagram Plus (not available in v410.1.0)
- **Unlock Story Preview**: Unlocks the Instagram Plus "Story Preview" — long-pressing a story shows the real preview (photo, video, auto-advance) instead of the blurred upgrade upsell, without appearing on the viewer list. Also removes the "Try Instagram Plus" row from the long-press menu. Works from the feed story tray and DMs.
- **Hide Viewer List Plus Button**: Hides the Instagram Plus button in your story's viewer list.

### Creation
- **Allow Videos in Photo Sticker**: Allows selecting video files in addition to photos when using the native photo sticker in Stories.
- **Show Gallery Upload Button**: Adds a direct **Sparkle Gallery** button in the photo sticker picker to attach media saved in Sparkle as stickers.
- **Use Detailed Color Picker**: Long-press the eyedropper for finer text-color control.

### Other
- **Story Audio Button**: Adds an animated speaker button above the bottom Story bar for Story media with playable audio. Tap it to mute or unmute Story playback without changing Feed or Reels audio. It distinguishes playing, muted, and zero system volume; at zero volume, tapping gives selection feedback and animates the icon without changing playback or device volume.
- **Search Viewer List**: Adds a search button to your own story's viewer list. Tapping it fetches the complete viewer list and opens a sheet where you can search by username or name; use a native top-bar menu to filter by who you follow, who you do not follow, people who do not follow you, or starred viewers; and star viewers for persistent quick lookup. Starred viewers follow the per-account setting scope. A fully Sparkle-native alternative to the Instagram Plus viewer search.
- **Hide Story Midcards**: Removes the "Join a trending" / "Add Yours" promo cards from the stories tray. 
- **Hide Recent Highlights**: Removes resurfaced highlights, the stories Instagram serves once you have watched every unseen story. They are dropped in three places, because the story tray, tapping forward and swiping sideways each read a different list: from the tray, so they no longer appear as rings; from the viewer's own reel list, so tapping forward past the last story no longer walks into them; and from the viewer's data store, so swiping to the next person does not reach them either. Opening a highlight yourself from a profile is unaffected.
- **Show Story Mentions**: Adds a mentions button listing mentioned users. Each account appears once no matter how many mention stickers point at it, and the story's own author is left out of the list. Tapping a user opens their real profile over the story viewer instead of closing it, so swiping back or tapping the back button returns you straight to the story. The follow button beside each account is Instagram's own control, showing Follow, Following, Requested, or Follow back.
- **Mention Count Badge**: Shows the number of unique mentioned accounts on the story mentions button. Requires Show Story Mentions. The badge is redacted along with the button when Hide UI on Capture is on.
- **Show Poll Vote Counts**: Shows vote counts next to poll options.

---

## Reels

### Action Button
- **Reels Action Button**, **Default Tap Action**, **Configure Actions**.

### Behavior
- **Tap Controls**: `Default`, `Pause/Play`, or `Mute/Unmute`.
- **Show Progress Scrubber**: Always shows the progress bar.
- **Disable Auto-Unmuting Reels**: Prevents unmute on volume/silent-switch changes. **(restart)**
- **Disable Reels Tab Refresh**: No refresh when re-tapping the Reels tab.

### Limits
- **Disable Scrolling Reels**: Blocks scrolling to the next reel. **(restart)**
- **Prevent Doom Scrolling** + **Doom Scrolling Limit**: Caps the number of reels that load in the main Reels feed (1–100). Profile reels are unaffected.

### Layout
- **Hide Reels Header**, **Hide Repost Button** **(restart)**, **Hide Suggested Accounts**.
- **Hide Viewer Comment Bar**: Removes the bottom "Add a comment..." field from the Reels viewer, reclaiming vertical space for captions on shorter displays. **(restart)**

### Metrics
- **Hide Like / Comment / Repost / Reshare / Save Count**.

### Confirmation
- **Confirm Like**, **Confirm Double Tap**, **Confirm Reel Refresh**, **Confirm Repost**.

---

## Messages

### Action Button
- **Messages Action Button**, **Default Tap Action**, **Configure Actions**: For visual messages.
- **Also Show on Chat Media**: Extends the action button to the full-screen viewer for permanent chat media — camera-roll photos and videos opened from a thread or the chat's shared-media grid. Replaces Instagram's native Save button, so media can be downloaded to Photos, the Sparkle Gallery, copied, shared, etc. Chat videos honor the **Download Video Quality** setting: when set to *Always Ask* the quality picker offers the video's full DASH ladder, same as feed/reels. Requires the Messages Action Button toggle.

### Messaging
- **Unlock Message Preview (not available in v410.1.0)**: Unlocks the Instagram Plus "Message Preview" (chat peeks) — long-pressing a chat shows the real preview instead of the blurred upgrade upsell.
- **Manually Mark Seen**: adds an eye button to mark chats seen.
- **Mark Seen on Message Send / Reply / Reaction / Typing**: auto-seen triggers; disabled unless Manually Mark Seen is on.
- **Seen Button Position**: choose whether the eye button sits in the top nav bar or as a bubble above the composer, within thumb reach and hidden while you type. The bubble can be dragged aside to peek underneath and snaps back when you scroll. Disabled unless Manually Mark Seen is on.
- **Included / Excluded Chats**: two separate per-account lists (Included when off, Excluded when on), same model as stories.

### Activity Notifications
- **Activity Notifications**: Master switch. Notifies you when a tracked user comes online, goes offline, starts typing, or reads a message you sent. An in-app pill while Instagram is open, a system notification while it is backgrounded.
- **Online / Offline / Typing / Read**: Pick which events notify you. Online and Read are on by default. Activity events use the neutral info pill style. Typing fires when a tracked user starts typing in any chat they share with you, once per burst rather than on every keystroke pause. Read fires only when that user's seen cursor advances across one of your outgoing messages. Typing and Read include the group name in both the pill and system notification when the event came from a group chat.
- **Notify Outside the App**: Sends a system notification when Instagram is not in front, so typing and read receipts that happen while you are elsewhere still reach you. On by default. While you are in the app the in-app pill is used instead, so nothing is filed twice. Instagram only tracks who is online while it is open, so online and offline are always reported as a pill inside the app.
- **Tracked Users**: Only users on this list are tracked. The list is always isolated by Instagram account, even when Sparkle's general Per-Account Settings option is off. Add users from the list or with **Track Activity** in a 1:1 chat. Rules are per user, so the same tracked person can generate typing and read events from a group chat too.
- **Activity Diagnostics**: Shows a live ONLINE, OFFLINE, or NO DATA result for each tracked user, the last activity age when available, and proof that the accurate-status scheduler and grace hooks were installed and exercised. Refresh rereads Instagram's store; Clear resets Sparkle's transition memory and cooldowns without deleting Instagram's live presence data.
- **Accurate Active Status**: Drops the grace period Instagram keeps someone marked as active for and shortens its native presence refresh, so the native green dot turns off when they actually leave rather than minutes later. Independent of the notification switches: it changes Instagram's own UI whether or not anybody is tracked. Changes apply immediately, including after switching accounts. The grace period is not exposed on 410.1.0, where only the shorter refresh applies.
- **Refresh Interval**: How often activity is refreshed while Accurate Active Status is on, from 10 to 300 seconds (default 20). Shorter is quicker to update and uses more battery. Changing it retimes Instagram's running presence scheduler immediately.
- Activity only arrives while Instagram is running. Backgrounding it keeps events coming for as long as iOS leaves the app alive, and they stop entirely once it is suspended; there is no background keepalive. Instagram also only reports activity for people it shares presence with. Repeated reports in the same direction are rate limited per user, but an online event never suppresses the following offline event, or vice versa.

### Deleted Messages
- **Keep Deleted Messages**: Preserves remotely-unsent messages in the chat, marked with an undo-circle indicator.
- **Log Deleted Messages**: Records normalized message snapshots before removal, then reconciles unsends after cold launches or later cache refreshes.
- **Log Removed Reactions**: Records removed reactions.
- **Respect Seen Chat List**: Skips log capture, ephemeral-media staging, and unsent notifications for chats in your manual-seen include/exclude list. Keep Deleted Messages preservation remains independent.
- **Deleted Messages Log**: Browsable log of preserved messages. 1:1 chats are grouped by sender; group chats collapse into a single entry titled with the real group name (resolved from IG's thread metadata: the custom name, or participant names for untitled groups). Group rows show the group's custom photo when set (else a group glyph), and group detail labels each unsent message with its sender.
- **Media Recovery Cache**: Pre-caches view-once/view-twice photos and videos, GIFs, and stickers until manually cleared from the Deleted Messages storage page. Media for messages that were never unsent is excluded from exports; clearing it retains lightweight metadata for best-effort fallback downloads. If an older or failed capture has no local copy, its log entry becomes a compact unavailable-media bubble instead of opening an expired CDN URL.
- **Refresh Profile Pictures**: Avatars self-heal: expired CDN URLs are silently re-resolved from Instagram, so reopening the log restores missing pictures. The log and sender-detail ⋯ menus force-refresh them all, and individual placeholders can be tapped to retry. Profile pictures are a shared cache managed under **Data & Settings › Storage**.
- **Confirm Inbox Refresh**: Confirmation before pull-to-refresh in the inbox, which would reload threads and drop preserved messages.

### Interface
- **Last Active**: Shows the exact time someone was last active in the chat header ("Active at 1:15 AM") instead of a relative label ("Active 2h ago"). Only reformats the presence Instagram already shows — no extra tracking — and leaves the live "Active now" window untouched. Choose **Off**, **Smart** (time alone for today, adds the date for older days), or **Date & Time** (always shows both).
- **Hide Typing Status**: Suppresses your typing indicator.
- **Hide Reels Blend Button**, **Hide Audio Call Button**, **Hide Video Call Button**, **Hide Flag Button**, **No Suggested Chats**.

### Visual Messages
- **Manually Mark Seen** + **Advance After Manual Seen**.
- **Stop Auto Advance**: Keeps the current visual message on screen instead of auto-advancing when it ends.
- **Disable View-Once Limitations**: Treats view-once messages as normal visual messages.
- **Disable Screenshot Detection**: Allows screen capture of visual messages.

### Vanish Mode
- **Disable Swipe-Up Gesture**: Disables the gesture that enables vanish mode.
- **Disable Screenshot Detection**: Allows screen capture while vanish mode is active.

### Notes
- **Hide Notes Tray**, **Hide Friends Map**.
- **Download Notes Audio**: Long-press a note in the tray to add a "Save audio" row to its menu (Save Audio to Files, Share Audio, Save Audio to Gallery, Play Audio, or Copy Audio Download URL). Only appears on notes that carry audio. **(restart)**
- **Copy Note Text**: Long-press a note to add a "Copy text" row to its menu. Only appears on text notes. **(restart)**
- _Note actions are not supported on IG 410.1.0 (yet)._

### Audio
- **Download Audio Messages**: Adds an "Audio Actions" row to a voice message's menu that expands in place into Save Audio to Files, Share Audio, Save Audio to Gallery, Play Audio, and Copy Audio Download URL. **(restart)**
- **Upload Audio Messages**: Adds an "Upload Audio" row to the composer plus (+) menu that expands into Photos, Gallery, and Files, then converts the clip you pick to M4A and sends it as a voice message. **(restart)**
- **Trim Before Sending**: When uploading an audio message, offer to trim the audio in the trim editor before it's sent (Send now, or Trim & Send).
- _Where an Instagram build cannot nest menu rows, both rows fall back to listing the same actions in a sheet._

### Media
- **Send Photo from Gallery**: Adds a "Send Photo" option to the composer plus (+) menu that sends a photo from the Sparkle Gallery into the chat. **(restart)**
- **Show GIF Title**: Long-press a GIF or sticker message for its name and the channel that uploaded it, then tap to copy the name. Direct stores no name for a GIF, so the row reads "Looking up GIF title" for a moment and fills itself in when Giphy answers; afterwards that GIF resolves instantly for the rest of the session. Off by default, and nothing is requested until you open a GIF's menu. **(restart)**

### Confirmation
- **Confirm Audio Call**, **Confirm Video Call**, **Confirm Double Tap**, **Confirm Reactions**, **Confirm Voice Messages**, **Confirm Follow Requests**, **Confirm Vanish Mode**, **Confirm Changing Theme**.

---

## Instants

### Action Button
- **Instants Action Button**, **Default Tap Action**, **Configure Actions**: Actions resolve the currently visible Instant with its author, posted date, and full-resolution media. Bulk actions retain every Instant encountered during the current viewer session until it closes, including ones already tapped past.
- **Toggle Instant Auto-Save**: Adds or removes the author of the Instant on screen from the Instants auto-save list, mirroring the equivalent story and chat actions. Shown only while *Auto-Save Instants* is on and the author can be read. See *Downloads › Auto-Save › Instants*.

### Privacy
- **Allow Screenshots**: Bypasses screenshot/screen-recording detection in the Instants viewer.

### Creation
- **Disable Instants Creation**: Hard-blocks the Instant shutter (photo and video); the shutter is darkened and capture is blocked, with an optional notification + haptic. Received Instants still work.
- **Skip Camera After Instants**: Skips the camera page Instagram opens after viewing the last Instant.
- **Disable Camera Control**: Stops the hardware Camera Control button (iPhone 16/17) from taking an Instant. Only available on devices that have Camera Control.
- **Camera View Button**: Adds one Sparkle button to the Instants camera view, in the slot the action button uses in the viewer, wearing the glyph set by **Open Menu Icon** in General settings. Its menu has three groups: upload a photo or video from **Photos / Gallery / Files** (see below); **Browse Saved Instants**; and **Instants Settings**.
- **Upload a photo**: The picked photo opens in the Sparkle photo editor in locked-square mode, so you frame it exactly as it will be sent. Tap the shutter to send it.
- **Upload a video**: The picked video opens in the trim editor, capped at the 6 second Instant length and pre-framed to the square, so it is ready to send without opening the crop editor (open it to reframe). Press and hold the shutter to record it, exactly as you would a live Instant: the clip plays into the camera from its first frame the moment you hold, and holds still on that frame until then, so the take always starts at the beginning of the clip rather than mid-playback.
- **Browse Saved Instants**: Lists everyone you have saved Instants from, with a count per user. Picking one navigates to the Gallery filtered to that user's Instants (across folders), titled with their username and with a back chevron to the list; filter and search are dropped there, since the screen already is the filter. Behind the Gallery lock when one is set.

### Confirmation
- **Confirm Instant Videos**: Finishes recording first, then asks before Instagram sends the video. Confirm sends the completed clip and returns to a fresh camera feed; cancel discards the send and rearms the camera, preserving injected media for another try. This works only with video Instants; photo Instants are not supported. While enabled, the hardware Camera Control button is disabled because its video path cannot be confirmed safely.
- **Confirm Instant Reaction**: Asks before an Instant reaction is sent.

---

## Profile

### Action Button
- **Profile Action Button** + **Default Tap Action**: `None`, `Copy Info`, `View Picture`, `Share Picture`, `Save to Gallery`, or `Profile Settings`. Sits in the profile nav bar just left of Instagram's own buttons (More/Follow/notify), tracking them as they morph and collapse on scroll; on your own profile it is omitted. On iOS 26 it grows a matching Liquid Glass bubble that fades in with scroll, and long usernames truncate so they never run under it.
- **Copy Info Default**: What Copy Info copies: `ID`, `Username`, `Name`, `Bio`, or `Profile Link`.

### Profile Picture
- **Long Press to Expand**: Long-press a profile picture to open it expanded.

### Indicators
- **Following Indicator**: Shows whether the profile follows you back, under their stats. Choose **Off**, **Icon**, **Text**, or **Icon & Text**.
- **Colorful Indicator**: Turn on to use the colored green/red instead of the native gray.
- **Hide Notes Bubble**: Removes the notes thought-bubble over the profile picture.
- **Hide Threads Button**: Removes the Threads switch button from the profile header.

### Confirmation
- **Confirm Follow**, **Confirm Unfollow**.

---

## Gallery

Sparkle's built-in media library: a private, on-device gallery with folders,
metadata, search, and an optional passcode/biometric lock. Media saved through
the action buttons or media preview lands here. Gallery data, deleted-message
logs, and Profile Analyzer data live locally under `Documents/Sparkle/`.

### Access
- **Open Gallery**: Opens the Gallery from settings.
- **Quick Gallery Access**: Choose a tab whose long-press opens the Gallery (or `None`).

### Browsing
- **Show Favorites at Top**: Pins favorites within the current sort/folder.
- **Show Files From Subfolders**: Lists everything in one grid/list instead of only the current folder's own files, so the Gallery root shows all your media without opening a single folder. Folders stay in the chip bar and still narrow the list to their own subtree, and each item shows the folder it lives in. Searching **All Folders** works as before.
- **Grid density**: Pinch the grid to switch between 2 / 3 / 5 columns (persisted).
- **Folder chips**: Subfolders appear as a horizontally-scrolling chip strip above the media.
- **Source & username overlays**: Grid items can show the source-type icon and `@username` (toggleable; username shows at lower densities). Video/audio items show a duration label.
- **Grid / list view** and **sort / filter** controls in the bottom toolbar.
- **Picker sheets**: Anywhere Sparkle asks you to choose saved media — Direct uploads, the comment composer, Instants, story stickers — you get the same browser as the Gallery itself: folder chips with item counts, grid/list toggle, pinch density, sort, filter, and search with a **This Folder** / **All Folders** scope. Folders open in place with a back button rather than stacking sheets, and your scroll position is restored when you come back out. An empty sheet explains itself rather than showing a bare grid. Picking an item whose file has since gone missing reports it instead of failing silently. Multi-select pickers show the running count on the **Add** button.
- **Item actions**: Each item's menu can **Open Story / Reel / Post** (the label and link match the saved source: posts and reels open on their own page over the Gallery, so you return straight to where you were when done, and the `instagram.com/p/...` or `instagram.com/reel/...` permalink is kept as a fallback; stories open `instagram.com/stories/...`) and **Open Profile** (opens the real profile over the Gallery the same way; older items saved without an account attached are looked up once and remembered, so every later open is instant), plus favorite, rename, move, share, **Trim** (videos and audio), **Edit** (photos: see Editing), and delete.
- **Select Text in Photos**: Static image previews get the same text recognition and floating controls as the media preview (see Media Preview & Menu), following the same toggle. Animated GIF/WebP previews and unsupported iOS versions skip analysis.

### Trimming
- **Trim editor**: Trim a video down to a clip, a single still frame, or **audio only**, with a filmstrip scrubber, draggable in/out handles, and mode chips. Reachable from a Gallery video or audio's **Trim** menu action, the **media preview** bottom toolbar (videos and audio), and the **Trim & Save** action button (see below). Picking **Audio Only** on a video switches the editor into the audio trimmer (waveform + artwork) and exports the selected range as an M4A, discarding the picture: if you don't touch the scrubber it saves the whole audio; the chip is hidden for silent videos. Trimming an audio file (or expanded audio) opens the same waveform editor directly. Frame-accurate re-encode via the FFmpeg pipeline honoring your **Download Encoding** settings (codec/CRF/bitrate/preset/resolution; falls back to AVFoundation); single-frame extraction is exported as HEIC/JPEG, turning a "photo + song" video into a real photo; audio exports as native AAC. Rendering runs in the background behind a progress pill: the app stays usable.
- **Crop (in the trim editor)**: A **Crop** button in the trim editor's top bar (sitting in its own bubble beside **Save**) opens a full-screen framing editor over a looping preview of the clip: pan/zoom to frame, rotate ±90°, flip horizontally, and pick a crop aspect. Confirming re-frames the trim editor's own preview to exactly what will be rendered, so the result is visible before you commit. The crop is applied in the same encode pass as the trim, never a second re-encode, and resolution limits from your **Download Encoding** settings measure the cropped picture rather than the original. The button appears only for a trimmed video: a single frame is cropped in the photo editor behind **Edit Frame**, and **Audio Only** has no picture.
- **Scrubber**: Drag the in/out handles to set the clip, drag inside the selection to slide the whole selection along the video, and tap anywhere to move the playhead. Handles keep their position under your finger instead of jumping to it. Dragging up or down away from the filmstrip slows the movement to a half, a quarter, then a tenth, with a haptic tick at each step, so you can land on an exact moment; where a maximum clip length applies, the filmstrip shows a zoomed window of the timeline that you pan by dragging outside the selection, rather than squeezing the whole video into one screen width.
- **Ask to Replace Original**: When trimming or editing a Gallery item, ask whether to replace the original in place or save a copy. Off always saves a copy and keeps the original.

### Editing
- **Photo editor**: Crop, pan/zoom, rotate (±90°), and horizontal flip for photos, with a selectable crop aspect. Reachable from: the **media preview** bottom toolbar's **Edit** button (Gallery photos *and* any expanded Instagram photo); a Gallery photo's **Edit** menu action; and the **Edit & Save** action button (see below). For a Gallery photo, saving honors **Ask to Replace Original** (replace in place or save a copy); for an expanded Instagram photo it offers a Done menu of destinations (**Photos / Gallery / Share / Copy**). The same editor powers Instants photo-upload positioning in a locked-square mode. *(Note: editing an animated GIF flattens it to a still image.)*
- **Trim & Save (action button)**: An opt-in, video-only action you can add to any action-button menu via the customizer (works on feed-inline reels too). It sources the video at your configured **download video quality** (progressive "ready-to-play" or merged DASH; prompts when set to "always ask"), opens the trim editor, then offers a Done menu of destinations (**Photos / Gallery / Share / Copy**; when the output is audio, **Save to Files** replaces Photos). DASH-quality trims download the streams and merge + cut in one pass, encoding only the selected window.
- **Edit & Save (action button)**: The photo counterpart to Trim & Save: an opt-in, image-only action for any action-button menu. It fetches the photo, opens the editor, then offers a Done menu of destinations (**Photos / Gallery / Share / Copy**).

### Importing
- **Import Media**: Bring media into the Gallery from the Files app — images, GIFs, videos, and audio — with full editable metadata. Picked files land in a queue you can review before committing: each row previews the file (tap the thumbnail for a full-screen preview) and opens a details form to set its **display name**, **username**, **source**, **date**, and, under **Advanced**, the user/media IDs, shortcode, permalink, pixel size, and duration. **Paste link to autofill** fills the form from a copied Instagram link. A **Shared details** row applies the same values to every queued file that you haven't edited individually, so a batch from one account only needs filling in once. Files are imported into the Gallery folder you opened Settings from.
- **Queue persistence**: The queue survives leaving the screen and app relaunches — picked files are staged on disk, so a half-filled batch is never lost. Entries are cleared as they import, or via swipe / **Clear Queue**.
- **Regram Media Vault import**: Coming from Regram? Pick your exported folder, `MediaVault.zip`, or the full `Regram-Data.zip` and Sparkle reads the vault's database directly, enqueueing every file with its metadata already filled in — source, username, dates, dimensions, and favorites — mapped onto Sparkle's own sources. Everything stays editable before import. (ZIP64 archives, which is what macOS and the Files app produce, are supported.)

### Gallery Settings
- **Pinch to Zoom**: Enables grid density pinching.
- **Show Source & Username**: Toggles the grid overlays above.
- **Show Media Info**: Overlays the username, source, and saved/posted dates on the expanded photo preview. Tap the media to hide it along with the controls. (Photos only.)
- **This Account Only**: Scopes the Gallery to media saved while logged into the current account (plus older unassigned files); enabling it offers to claim existing unassigned files for the current account. Each saved file is tagged with the account that saved it; reassign a file to another logged-in account from its **Edit Details → Account** row (e.g. to stash media into a different account's Gallery). Non-destructive: turn it off to see everything.
- **Hidden Sources**: Hides selected sources, from Gallery browsing and Gallery picker sheets without deleting files or excluding them from maintenance and duplicate tracking.
- **Enable Passcode Lock** + **Change Passcode**: 4–6 digit passcode with Face ID / Touch ID unlock. Hashes are stored in the keychain (PBKDF2-HMAC-SHA256). Enforced globally when opening the Gallery itself and all gallery picker sheets (e.g., when uploading media in Direct Messages or Instants).
- **Import Media**: Opens the importer (see Importing above) — from Files, or a Regram Media Vault export.
- **Storage**: Total / image / video / audio counts and total size.
- **Delete Files**: Bulk-delete tooling: by everything, by type (images/videos/thumbnails), by source (feed/stories/reels/DMs/profile pictures), or by user.

---

## Downloads

Tapping **Downloads** opens the download manager directly. A gear button in the
top bar opens **Downloads Settings** (below). Settings remain searchable from
the main settings search.

- **Downloads**: Action-based download manager with chip filters for All, Active, Queued, Failed, and Recent. Each row represents the user action, not an internal transport task. Multi-item actions expand inline, failed items can be retried individually, Gallery and Photos saves open their matching destination, and single-file results preview locally when applicable. Supports cancellation, destructive-action confirmations, clearing history without deleting saved media, and best-effort retry for reconstructable actions. With **Per-Account Settings** on, the history and **Clear Finished** action are scoped to the current account (each download keeps the account that started it); the limit and max-concurrent settings stay global.
- **Global Queue Pill**: Parallel and queued download work shares one aggregate Downloads pill instead of spawning one pill per item or separate queue-finished toasts.

### Auto-Save
Saves media automatically as you view it, with no tap. Available for **Stories**, **Messages** (view-once), and **Instants**. The destination, quality, and feedback settings below are shared by every surface; each surface page holds only its own enable switch, filter mode, and list. Media already saved to the chosen destination is skipped, so re-viewing never saves twice — this holds regardless of the *Detect Duplicate Downloads* setting, which auto-save does not use.

Every surface has the same **Filter Mode**: `All` saves everything except what you exclude; `Selected` saves only what you pick. Each mode keeps its own list, so switching back and forth never destroys the other. Lists are per-account, per-surface, and independent of the Manually Mark Seen lists.

- **Stories**: Auto-saves story photos and videos as you watch them. Keyed by user.
  - **Excluded / Selected Users**: Manageable from the list itself (add by username) or from the story action menu (*Toggle Story Auto-Save*), which adds or removes the user whose story you're watching.
- **Messages**: Auto-saves view-once and replayable DM photos and videos as you open them — the media you otherwise can't get back. Keyed by **chat**, so group threads work without resolving a per-message sender.
  - **Excluded / Selected Chats**: Manageable from the list itself (add by username, which resolves your 1:1 thread with them) or from the visual message viewer's action menu (*Toggle Chat Auto-Save*). Groups can only be added from the viewer.
- **Instants**: Auto-saves instants as you open them. Keyed by **username**, since a resolved snap carries no author id — which also means the list can be curated by typing a username, with no lookup needed.
  - **Excluded / Selected Users**: Manageable from the list itself (add by username) or from the Instants action menu (*Toggle Instant Auto-Save*), which adds or removes the author of the instant on screen. Turning it on re-checks the instant you're looking at, so the current one is saved without tapping forward.
- **Save To**: `Sparkle Gallery` keeps auto-saved media inside the tweak; `Photos App` saves it to your system photo library (iOS asks for photo library permission the first time). The skip-if-already-saved check follows the destination you pick, so switching destinations re-saves items the new one doesn't have yet — and deleting an item from its destination lets it be saved again next time you view it.
- **Photo Quality** / **Video Quality**: Quality tier for auto-saved media. `Default` takes Instagram's ready-to-play file — fastest, no re-encode per item; `High` merges DASH video + audio for best quality at the cost of an FFmpeg pass per item (**requires FFmpegKit**). Auto-save never prompts, so there is no `Always Ask`.
- **Keep in Download History**: Auto-saves are pruned from the download history once saved. Enable to keep them listed.
- **Notifications**: Feedback is per viewing session, not per item — tapping through twenty stories costs two toasts, not forty. All of it is configured under *Notifications › Auto-Save*, where each toast can be a pill, haptic-only, or silent:
  - *Story / DM / Instants Auto-Save Started*: posted once, on the session's first save.
  - *Auto-Save Summary*: posted at the end with the number of items saved; tap it to open the Gallery (or the Photos app, following the destination). It waits for every download and DASH merge to finish, so the count is final.
  - *Auto-Save Still Working*: only when you leave the viewer while items are mid-flight (typically `High` video quality muxing DASH audio), explaining why the summary hasn't arrived yet.

### Behavior
- **Detect Duplicate Downloads**: Skips media already saved: Gallery checks are exact by persistent media identity; Photos checks cover saves Sparkle recorded while tracking is enabled. Existing Photos-library items cannot be discovered retroactively.
- **Parallel Downloads**: Limits concurrent download work from 1–4 (default 2) across direct saves, carousel items, conversions, and DASH merge pipelines.
- **History Limit**: Caps saved download actions at a configurable history limit (default 300 entries).
- **Save to Custom Album**: Toggles saving Photos-destination downloads to a specific custom album in the iOS Photos app.
- **Album Name**: Configures the title of the custom Photos album (defaults to "Sparkle", disabled when the toggle is off). If empty, saving falls back to the default Recents camera roll.

### Storage
- Each download keeps a **staged copy on disk** so its history entry stays previewable on tap; this staged data (plus staged source/preview scratch) is what the **Storage Usage → Downloads** figure counts. Clearing a download from history — via **Clear Finished Downloads**, a swipe-delete, or the history-limit trim — frees its staged copy automatically. Media already saved to Photos or the Gallery is never affected. On launch, Sparkle also sweeps any **orphaned** staged leftovers no longer tied to a history entry (interrupted downloads, crash leftovers, or backlog from older builds), so the cache stays bounded by your history without any manual step.

### Quality
- **Fetch 4K Images**: Mimics a desktop web browser to retrieve 4K/high-resolution image candidates from the web version of the Instagram API (fetched on-demand when downloading, copying, or displaying the quality picker — including downloads and copies started from the full-screen media preview).
- **Default Photo Quality**: `Max` / `High` / `Medium` / `Low` (or `Always Ask`). `Max` leverages web 4K image candidates when enabled; disabling the 4K switch automatically adjusts the setting to `High` and disables `Max`.
- **Quality Picker Sheet ("Always Ask")**: Cleanly groups photo candidates into dedicated **Web API** and **Mobile API** sections, removes cropped grid thumbnails (e.g. 1:1 cropped square thumbnails on non-1:1 posts), deduplicates identical resolutions, and strips technical subtitle clutter (`11.8 Megapixels • 4:5`). In bulk downloads, presents a single **Batch Quality** action sheet (`Max`, `High`, `Medium`, `Low`) to choose quality once for all items in the batch.
- **Enhanced Media Resolution**: Requests higher-resolution media for downloads.
- **Default Video Quality**: Save/share quality. `High` merges DASH video + audio; `Default` uses ready-to-play files; `Always Ask` prompts each time. **Requires FFmpegKit** for the merge/quality options.
- **Encoding Settings**: Advanced codec / preset / bitrate / CRF / resolution / audio overrides for the merge step (requires FFmpegKit). A **Reset Encoding Settings** button restores every advanced encoding option to its default (the toggle stays on).
- **View Encoding Logs**: Inspect and share the FFmpeg loader/merge logs.

### Audio
- **Audio Downloads**: Adds audio actions (save/share/copy download URL) to supported media.
- **Audio Page Button**: Adds an action button to the music/audio page.
- **Audio Page Default Action**: Default tap action for the audio page button: `Save Audio to Files`, `Share Audio`, `Save Audio to Gallery`, `Play Audio`, `Copy Audio Download URL`, or `None`.

---

## Profile Analyzer

Fetches your account's full followers and following lists through Instagram's
private API, stores a local snapshot, and surfaces relationship insights. Runs
in the background: start an analysis and keep using the app; a notification pill
reports progress and completion. Data is stored locally per account and never
uploaded. Accounts with more than 13,000 total connections (followers + following)
can't be analyzed because a single scan would hit Instagram's rate limits.

### Analyzer
- **Open Profile Analyzer**: Dashboard with your profile header (avatar, @username, and posts/followers/following — your identity shows even before the first scan), a Scan Now/Again button that intermittently surfaces when you last analyzed, and the insight categories below.
- **Insights** (always available after a scan):
  - **Mutual Followers**: accounts you follow that also follow you.
  - **Not Following You Back**: accounts you follow that don't follow you.
  - **You Don't Follow Back**: accounts that follow you that you don't follow.
- **Changes** (accumulate across scans: re-running never wipes the history):
  - **New Followers** / **Lost Followers**: everyone gained or lost since tracking began.
  - **You Started Following** / **You Unfollowed**: your following changes over time.
  - **Profile Updates**: username, name, or profile-picture changes for tracked accounts.
  - Each category badges the number of changes you haven't looked at yet; inside, unseen changes are grouped under **Latest** above previously-seen ones under **Previous**. Opening a category clears its badge.
  - **Swipe any change to delete it** once you've seen it: the entry is dropped from the stored history and the category's count drops to match. Only that entry goes; the rest of the history and your snapshots are untouched.
- Each list supports search, sorting (A–Z / Z–A / default), tapping a row to open the profile, and an inline follow button with live follow-state resolution. The button is Instagram's own control, so it matches the app exactly and shows **Follow**, **Following**, **Requested**, and **Follow back**. Because it is Instagram's, its label follows Instagram's language rather than Sparkle's.

### Tracking
- **Track Visited Profiles**: Records the profiles you open so you can review who you visit most (with first/last-seen and a visit count). Most-recent, most-visited, and alphabetical sorts; swipe to remove an entry, or clear the whole history from the list's **More** menu. Stored locally.

### Maintenance
- **Reset Profile Analyzer Data**: Deletes all stored snapshots, the change history, and visited-profile history.
- **Refresh Profile Pictures**: Avatars self-heal: when a stored CDN URL has expired, Sparkle silently re-resolves a fresh one from Instagram, so simply reopening a list restores missing pictures. A list's **More** menu force-refreshes them all, and individual placeholders can be tapped to retry. Profile pictures are a shared cache managed under **Data & Settings › Storage**.

### Notifications
- **Profile Analyzer Complete**: Pill + haptic when an analysis finishes (toggleable under Notifications).

---

## Notifications

The Sparkle notification pill is configurable.

### Appearance
- **Glow**: Glow effect around notifications.
- **Liquid Glass**: Renders the notification pill with iOS 26 Liquid Glass (adaptive text/icons). Requires iOS 26; falls back to the standard material on iOS 18 and lower.
- **Download Progress**: Subtitle style for download-progress pills.
- **Duration**: Auto-dismiss delay (0.5–5.0s).

### Preview
- **Test Notification**: Cycles success / error / info previews.

### Per-feature toggles
Every notification category has an independent **visibility** toggle and a
matching **haptic** toggle (under Haptics), covering downloads, copies,
story/message seen actions, gallery actions, settings export/import, cache
clearing, and more.

---

## Tools

### FLEX
- **Open FLEX Now**, **Three-finger Hold**, **Open on App Launch**, **Open on App Focus**. Requires `libFLEX.dylib` to be bundled (build the ipa with `--flex` flag or install `libFLEX.dylib` if jailbroken).

### Tweak
- **Quick Settings Access**: Long-press the Home tab to open Sparkle Settings. **(restart)** If the Home tab is hidden or claimed by the Gallery shortcut, the long-press automatically falls back to another visible tab so Settings is always reachable. Additionally, you can long-press the new message composer button in DMs to open Sparkle Settings (when the tab bar is hidden).
- **Shortcut Haptics**: Light haptic feedback when opening Settings / Gallery.
- **Show Settings on App Launch**.
- **Disable All Settings**: Master kill switch; only Settings access remains. **(restart)**
- **Show Onboarding**: Replays the first-run introduction sheet at any time.
- **Show What's New**: Replays this release's What's New sheet at any time.
- **Reset Safe Startup Mode**: Clears Sparkle's failed-launch counters and re-enables feature hooks after the launch failsafe kicked in.

### Settings Lock
- **Enable Settings Passcode Lock** + **Change Settings Passcode**: Uses an independent keychain-backed passcode and Face ID / Touch ID unlock. Protects full Settings and topic sheets opened from action buttons; Settings remains unlocked until its modal is dismissed.

### Instagram
- **Hide TestFlight Popup**: Suppresses the Instagram Beta update popup. This is always active on release builds to support sideloading (and is configurable on developer builds).
- **Fix Duplicate Notifications**: Drops the local copy Instagram re-adds for a push its notification extension is already delivering. Instagram normally handles this itself, so leave it off unless duplicates actually reach you.
- **Disable Safe Mode**: Prevents Instagram from resetting settings after repeated crashes (use with care).

---

## Data & Settings

### Storage
- **Storage Usage**: Total on-device space used by all Sparkle data, with a per-feature breakdown (Gallery, Downloads, Deleted Messages, Profile Analyzer, the shared Profile Pictures cache, and imported Fonts). Includes **Clear Cached Profile Pictures**, which frees the app-wide avatar cache (pictures re-download as needed). Instagram's own cache is not included.

### Backup & Transfer
- **Export / Import**: Export/import any combination of **Settings**, **Gallery** media + metadata, **Deleted Messages**, and **Profile Analyzer** data to a single `.zip` file. Media Recovery Cache assets are intentionally excluded until they belong to an unsent message. Imports also accept backups re-compressed by Files, iCloud, or desktop tools.

### Reset
- **Reset All Settings**: Restore every preference to its default value. When **per-account settings** is on, a prompt first asks whether to reset **All Accounts** or **This Account Only** (like Export) — a per-account reset clears only the active account's overrides and leaves other accounts untouched.
- Individual **configurable** settings can also be reset in place, without wiping everything: **Reset Encoding Settings** on the Advanced Encoding page, and **Reset to Default** at the bottom of each surface's **Configure Actions** editor (resets that surface's menu sections, default action, and bulk menus only).
