<div align="center">

<img src="resources/screenshots/sparkle.png" width=128 height=128> 

# Sparkle for Instagram

`v1.3.1` · Tested on versions **445.0.0** and **410.1.0**

[📣 IPA Releases](https://t.me/sparkle_ig) · [💬 Chat & Support](https://t.me/+f-Xo21HnfCY3NmE0) · [📦 Jailbreak Repo](https://efibalogh.github.io/sparkle-ig/) · [📥 DEB Releases](https://github.com/efibalogh/sparkle-ig/releases/latest) · [🐛 Issues](https://github.com/efibalogh/sparkle-ig/issues/new/choose) · [❤️ Support](https://ko-fi.com/sparkle_ig)

</div>

---

> [!NOTE]
> - To open Sparkle's settings, see [Opening Sparkle Settings](#opening-sparkle-settings).
> - IPA releases go out on the [Telegram channel](https://t.me/sparkle_ig); for questions and help join the [chat group](https://t.me/+f-Xo21HnfCY3NmE0).
> - Feature request or bug report? [Open an issue](https://github.com/efibalogh/sparkle-ig/issues/new/choose).

## What is Sparkle?

Sparkle is a [Theos](https://theos.dev) tweak that reshapes the iOS Instagram app around you. Download any media, keep a private on-device gallery, recover deleted messages, run each account with its own settings, analyze your followers, and strip out the ads, AI, and annoyances.

It started as a fork of [SoCuul's SCInsta](https://github.com/SoCuul/SCInsta), but has since been rewritten and extended far beyond it.

- Targets **iOS 15.0+**, built with the iOS 16.2 SDK.
- Works **jailbroken** (tested via Dopamine on iOS 16.7.16) and **sideloaded** (Feather, SideStore, LiveContainer etc.).
- Written in Objective-C / Objective-C++ / Logos.

## Highlights

For the full list of features, check out [`FEATURES.md`](FEATURES.md).

- **Media downloads**:
  - Save feed posts, reels, stories, DMs, Instants, and comments.
  - Auto-save stories, view-once DM media, and instants straight to the Gallery or Photos as you view them.
  - An action-based download manager with a queue, retries, duplicate detection, and configurable concurrency.
  - High-quality DASH video+audio merging via FFmpegKit.
- **Private Gallery**:
  - An on-device media library with folders, search, metadata, source overlays, and an optional passcode / Face ID / Touch ID lock. Nothing ever leaves your device.
  - Import your own media from Files with editable metadata, or bring your whole Regram Media Vault over in one go.
  - Browse saved Instants by user straight from the Instants camera.
  - Send any photo or video you already have as an Instant, from Photos, Files, or the Gallery.
  - Confirm recorded video Instants before Instagram sends them. Photo Instants are not supported.
- **Built-in editors**:
  - Trim any video down to a clip, a single still frame, or audio-only.
  - Crop, pan/zoom, rotate, and flip a video's framing, applied in the same pass as the trim.
  - A photo editor with crop / pan-zoom / rotate / flip.
  - Reachable from the gallery, media preview, or an opt-in action button.
- **Action buttons everywhere**:
  - Fully customizable action-button menus on feed, reels, stories, DMs, Instants, and profiles.
  - Reorder, rename, re-icon, and set per-surface default tap actions.
  - An optional feed-header shortcut button for one-tap access to Gallery, Profile Analyzer, Deleted Messages, Downloads or Settings.
- **Keep deleted messages**:
  - Preserve unsent DMs, log removed reactions, and recover view-once media, with a browsable log.
- **Hidden chats**:
  - Hide any 1:1 or group chat from the DM inbox with a long press, reveal them again by holding the inbox title, and optionally mute them on Instagram itself, messages and calls both, so no push or vibration arrives while they stay hidden. Hidden chats stay out of the recipients Instagram suggests when sharing and can be kept out of the unread badge, and revealing them can be put behind Face ID, Touch ID, or a passcode of its own.
- **Activity notifications**:
  - Get notified when a tracked user comes online, goes offline, starts typing, or reads a message you sent, and make Instagram's own green dot accurate with an early-installed presence refresh and no grace period.
- **Profile Analyzer**:
  - Fetches your followers/following and surfaces mutuals, non-followbacks, and a durable change log (new/lost followers, profile updates) across scans.
- **Per-account settings**:
  - Each logged-in account keeps its own preferences, gallery scope, and download history, including account-scoped history clearing.
- **Story viewer tools**:
  - Search everyone who saw your story, filter non-followers, and star viewers for quick lookup later.
- **Privacy & focus**:
  - Hide ads, Meta AI, and suggested content.
  - Disable seen receipts, typing status, screenshot detection, and view-once limits.
  - Unlock native message previews from the inbox long-press menu on supported Instagram versions.
  - Block doom-scrolling.
  - Build a custom tab bar with a live preview: reorder or hide destinations, choose launch and swipe behavior, trade a hidden tab for one-tap access to Saved collections in the custom layout, and drop the bar entirely when a single tab is left.
- **Custom app font**:
  - Import your own `.otf`/`.ttf` font and use it across Instagram and Sparkle, matched per weight and previewed face by face before you pick it.
- **Language packs**:
  - Sparkle ships in English. Other languages are community translations you install from the Translate button in Sparkle Settings, as a language pack, and remove again with a swipe. Anything a pack does not translate falls back to English. Dates use the selected language's ordering, punctuation, and month names while respecting the device's 12/24-hour clock. Built-in Action Button section names follow the selected language; names you customize remain exactly as entered. A language ships with Sparkle, no pack needed, once a native speaker has reviewed it. See [Help translate](#help-translate).
- **Confirmations**:
  - Optional "are you sure?" guards for accidental likes, follows, reposts, calls, comments, and more.
- **Liquid Glass (iOS 26+)**:
  - Native Liquid Glass integration across Sparkle's own UI, plus an option to force-enable Instagram's.
  - On iOS 18 and lower, a **Pill-Shaped Tab Bar** toggle brings the floating pill tab bar (shape only; the glass material stays iOS 26+).

## Installation

> [!IMPORTANT]
> Sparkle does **not** ship Instagram itself. Pre-injected IPAs are distributed on the [Telegram channel](https://t.me/sparkle_ig), and the jailbroken `.deb` is on [Releases](https://github.com/efibalogh/sparkle-ig/releases/latest) or from the [Sparkle repo](https://efibalogh.github.io/sparkle-ig/).

### Sideloaded

1. Grab the latest **pre-injected IPA** from the [Telegram channel](https://t.me/sparkle_ig).
2. Install the IPA with your sideloading tool of choice.
   - Use the **`_no-ext`** build for **AltStore / SideStore / LiveContainer** (or if you don't want to have app extensions).

> [!NOTE]
> Sparkle uses Instagram's bundled image assets everywhere. The distributed IPA is a full (un-thinned) build (it contains icons for all screen sizes), so the higher-quality in-app icons render crisply on every device. If you build your own from an IPA that was already thinned to a smaller device, some icon scales may be missing. See [Building from source](#building-from-source).

### Jailbroken

Add the Sparkle repo to your package manager and you will get updates as they ship.

<div align="left">

[![Add the Sparkle repo](https://img.shields.io/badge/%E2%9C%A6%20Add%20the%20Sparkle%20Repo-ED1E9C?style=for-the-badge)](https://efibalogh.github.io/sparkle-ig/)

</div>

Open that page on your device and tap Sileo or Zebra,
or add the URL by hand:

```
https://efibalogh.github.io/sparkle-ig/
```

The repo serves both the rootless (`iphoneos-arm64`) and rootful (`iphoneos-arm`) builds; your
package manager picks the right one for your jailbreak automatically.

Rather not add a repo? Install a single `.deb` instead, and update it yourself each release:

1. Download the rootless or rootful `.deb` from [Releases](https://github.com/efibalogh/sparkle-ig/releases/latest).
2. Open the `.deb` in Sileo/Zebra (or install it with `dpkg -i` over SSH), then respring.

### Build it yourself

You can build from source locally, or fork the repo and run the **Build and Package Sparkle** GitHub Action with your own decrypted IPA URL. The injected IPA lands as a draft release in *your* fork. See [Building from source](#building-from-source).

## Opening Sparkle Settings

By default, **long-press the Home tab** or the **Profile settings button** to open Sparkle Settings. You can also enable *Show Settings on App Launch*. If you hide the Home tab, the long-press automatically moves to another visible tab so Settings is always reachable.

Tap the **Translate** button in the top-right of Sparkle Settings for the language sheet. English is the only language Sparkle ships; the same sheet imports community language packs from zip archives, exports the English strings a translation starts from, and removes an installed pack with a swipe. Importing only makes a language available; switching to it is a separate tap. A System Default row that follows Instagram appears once a pack is installed. A restart applies the choice across every Instagram account. Anything untranslated falls back to English.

## Screenshots

| Settings | How to Access |
|:-------------:|:------------:|
| <img src="resources/screenshots/sparkle_settings.jpg" width="300"> | <img src="resources/screenshots/sparkle_settings_open.jpg" width="300"> |

## Building from source

### Prerequisites

- **Xcode** + Command-Line Developer Tools
- [Homebrew](https://brew.sh)
- [Theos](https://theos.dev/docs/installation) with the **iPhoneOS16.2.sdk** in `~/theos/sdks`
- `brew install ldid dpkg make cmake` (plus the FFmpeg build deps: `autoconf automake libtool meson nasm ninja pkgconf wget yasm`)
- **For sideloading only:** [cyan](https://github.com/asdfzxcvbn/pyzule-rw#install-instructions) and [ipapatch](https://github.com/asdfzxcvbn/ipapatch/releases/latest)

### Setup

1. **Install the iOS 16.2 SDK** for Theos — download from [xybp888/iOS-SDKs](https://github.com/xybp888/iOS-SDKs) and copy `iPhoneOS16.2.sdk` into `~/theos/sdks`.
2. **Clone with submodules:**
   ```sh
   git clone --recurse-submodules https://github.com/efibalogh/sparkle-ig
   cd sparkle-ig
   ```
3. **Fetch the FFmpegKit frameworks** (used for video/audio merging & trimming):
   ```sh
   ./fetch-ffmpegkit.sh
   ```
4. **For sideloading:** obtain a **decrypted, un-thinned** Instagram IPA from a trusted source, rename it to `com.burbn.instagram.ipa`, and place it in a `packages/` folder at the repo root.

> [!IMPORTANT]
> Use a *universal* decrypted IPA. An IPA that was already thinned to a specific device (e.g. dumped on an older iPhone) might be missing higher-scale icons/image assets, which makes icons and image assets blurry on newer devices.
>
> Alternatively, if you own a jailbroken device, I recommend using [ipadecrypt](https://github.com/londek/ipadecrypt), which provides an un-thinned IPA regardless of your device's screen size.

### Build

```sh
./build.sh rootless          # rootless .deb (jailbroken)
./build.sh rootful           # rootful .deb (jailbroken)
./build.sh ipa --release     # sideload IPA (= --inject --patch)
```

The `ipa` command takes composable flags:

| Flag | Effect |
|------|--------|
| `--release` | Shorthand for `--inject --patch` |
| `--inject` | Build Sparkle's rootless `.deb` and pass it to Cyan as a single input. The bundle and FFmpeg frameworks travel inside the deb, so `--bundle` is not needed alongside this. The same deb is usable for jailbreak installs. |
| `--bundle` | Pass `Sparkle.bundle` and the FFmpeg frameworks to Cyan, without injecting the tweak. |
| `--no-ffmpeg` | Stage `Sparkle.bundle` with the localization catalogs but without the FFmpeg frameworks. Media encoding is unavailable in the result. |
| `--flex` | Bundle `libFLEX.dylib` (in-app debugging) |
| `--patch` | Run `ipapatch` |
| `--no-ext` | Strip all `.appex` bundles before injection |
| `--dev` | `DEV=1` build (also enables the developer diagnostics: performance meter and hook bisect, under Settings → Tools → Diagnostics) |
| `--buildonly` | Build the deb and dylibs only, skip IPA packaging |
| `--bundle-id <id>` | Override the bundle ID |

Outputs are named with the Sparkle version (and, for IPAs, the bundled Instagram version) so builds are easy to tell apart:

- **IPA**: `Sparkle[_<flags>]_v<version>_IG_v<ig version>.ipa` (e.g. `Sparkle_v1.0.0_IG_v437.2.0.ipa`, or `Sparkle_no-flex_v1.0.0_IG_v437.2.0.ipa`)
- **deb**: `Sparkle_v<version>_<rootless|rootful>.deb`

Run `./build.sh` with no arguments for the full usage reference.

The jailbreak `.deb` contains `Sparkle.dylib` plus `Sparkle.bundle`. Its FFmpeg frameworks are staged under Sparkle's own `spk.*` names, resolve their siblings through `@loader_path` dependencies, and are ad-hoc signed for jailbroken devices.

Sideload builds hand the same `.deb` to Cyan. Cyan hoists every framework inside it into `App.app/Frameworks`, which is the only place a sideload signer re-signs code: signers in the ldid family only re-sign frameworks one level below the app bundle, so anything left deeper keeps its ad-hoc signature and fails to load on a device without a jailbreak. The frameworks use Sparkle's own `spk.*` names so they never replace Instagram's existing `libavcodec` and `libavutil` frameworks, and the duplicate copies Cyan leaves inside `Sparkle.bundle` are pruned afterwards.

```sh
./build.sh ipa --release --flex
```

Icons, the Safari extension, extension stripping, FLEX, bundle-ID changes, and `SPKSideloadFix` remain explicit IPA stages. Launch and FFmpeg operations still need on-device testing for each release.

### Recompiling the Liquid Glass app icons

The app icons are pre-compiled into `resources/sparkle_icons/` to keep IPA packaging fast. If you change the source `.icon` bundles in `resources/`, recompile them with `actool` before building:

```zsh
mkdir -p resources/compiled_sparkle resources/compiled_sparkle_dark resources/compiled_sparkle_neutral

xcrun actool resources/sparkle.icon         --compile resources/compiled_sparkle         --platform iphoneos --minimum-deployment-target 15.0 --app-icon sparkle         --output-partial-info-plist resources/sparkle_partial.plist         --target-device iphone --target-device ipad
xcrun actool resources/sparkle-dark.icon    --compile resources/compiled_sparkle_dark    --platform iphoneos --minimum-deployment-target 15.0 --app-icon sparkle-dark    --output-partial-info-plist resources/sparkle_dark_partial.plist    --target-device iphone --target-device ipad
xcrun actool resources/sparkle-neutral.icon --compile resources/compiled_sparkle_neutral --platform iphoneos --minimum-deployment-target 15.0 --app-icon sparkle-neutral --output-partial-info-plist resources/sparkle_neutral_partial.plist --target-device iphone --target-device ipad

mkdir -p resources/sparkle_icons
cp resources/compiled_sparkle/*.png resources/compiled_sparkle_dark/*.png resources/compiled_sparkle_neutral/*.png resources/sparkle_icons/
rm -rf resources/compiled_sparkle resources/compiled_sparkle_dark resources/compiled_sparkle_neutral resources/*_partial.plist
```

## Contributing

Contributions are greatly appreciated! Feel free to open a pull request.

- New hooked IG classes/methods go in `src/InstagramHeaders.h`
- Prefix all custom symbols with `spk_` / `SPK`.
- Break new features into `src/Features/<Surface>/` rather than bloating `Tweak.x`.
- Put every user-facing string behind `SPKL`, `SPKLC`, or `SPKLP`, use semantic keys, and add the English string to `resources/Sparkle.bundle/en.lproj`.
- Run `tools/sync-catalog-keys.py` afterwards so the community catalogs in `translations/` keep every key, then `tools/lint-i18n.py` before submitting any UI copy or translation change.

### Help translate

Sparkle ships English only. The 16 catalogs in `translations/` were produced by machine translation and no native speaker has reviewed them, which is why they are a starting point rather than something users are given by default. Expect unnatural phrasing, terms that should have stayed in English, and help text that describes the wrong setting.

If you read one of these languages, correcting it is the single most useful contribution you can make, and it needs no build: edit `translations/<locale>.lproj/Localizable.strings`, run `tools/lint-i18n.py --locale <locale>`, open a pull request. **A reviewed language ships with Sparkle.** Until then, anyone can install it from the language sheet with **Import Language Pack**, and you can test your own work the same way.

For a single correction, no checkout is needed: tap the Translate button in Sparkle Settings, choose **Report a Translation Issue** at the bottom of the language sheet, or [start one](https://github.com/efibalogh/sparkle-ig/issues/new?template=3-translation.yaml) directly. The form asks for the language, where the text appears, what it says now, and what it should say.

Full details, including starting a language that has no catalog yet, are in [TRANSLATING.md](TRANSLATING.md).

Not a coder? Documentation improvements are always appreciated too.

## Support the project

Sparkle takes a lot of time to develop and maintain as Instagram changes constantly, and I can only work on it in my limited amount of free time. If you'd like to support the work:

- ☕ Donate on [Ko-fi](https://ko-fi.com/sparkle_ig).
- 📣 Join and share the [Telegram channel](https://t.me/sparkle_ig).
- ⭐ Star the repo and tell people who'd like it.

## Credits

- [**SoCuul** • SCInsta](https://github.com/SoCuul/SCInsta): the base project Sparkle is built on.
- [**BandarHL** • BHInstagram](https://github.com/BandarHL/BHInstagram): the original tweak SCInsta forked from.
- [**Ryuk** • RyukGram](https://github.com/faroukbmiled): code, inspiration, and help.
- [**@n3d1117** • InstaSane](https://github.com/n3d1117/InstaSane): the Following-feed mode.
- [**@asdfzxcvbn** • zxPluginsInject / ipapatch / cyan](https://github.com/asdfzxcvbn): tooling and fixes for sideloaded installs.
- [**@BillyCurtis** • OpenInstagramSafariExtension](https://github.com/BillyCurtis/OpenInstagramSafariExtension): open Instagram links in Safari in the sideloaded IPA.
- **@grxphxnx**: helped quickstart Sparkle's multi-language support.

## Official builds

Sparkle is free and always will be. It is only distributed here and on the official [Telegram channel](https://t.me/sparkle_ig). There is no paid version, no subscription, and no store that sells it.

Sparkle is licensed under the GPL-3.0. Anyone may modify it and even charge for it, but only if they give their users the complete source of their build and keep the original license and attribution intact.

[**SKInstagram**](https://t.me/ikurdstore/4799?embed=1) (backup links in case the post gets deleted: [link 1](https://archive.ph/znSIh), [link 2](https://web.archive.org/web/20260808011714/https://t.me/ikurdstore/4799?embed=1)), credited to the "SideKit team" and distributed through the iKURD Store, appears to be built from Sparkle and is offered behind that store's paid subscription. It ships no source and no attribution, which means it is not licensed to be distributed at all. If you paid for it, you were charged for free software that you can get here for nothing.

## License

Sparkle is licensed under the [GNU General Public License v3.0](LICENSE).
</content>
</invoke>
