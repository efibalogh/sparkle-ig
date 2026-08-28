# SPKSideloadFix

Sparkle-local sideload app-group/keychain fix library.

This is derived from [`asdfzxcvbn/zxPluginsInject`](https://github.com/asdfzxcvbn/zxPluginsInject),
which is itself a rewrite of choco's original patch. It also vendors Facebook's
[`fishhook`](https://github.com/facebook/fishhook) for C symbol rebinding.

Compared with upstream `zxPluginsInject`, this variant changes app-group
container handling so `NSUserDefaults` uses the same redirected container policy
as `NSFileManager` in app-extension processes:

- retry app-group lookup until `LSBundleProxy` returns a usable group URL
- fall back to a Documents-backed group path when no app-group URL is available
- create redirected suite container directories before passing them to defaults
- leave main-app `NSUserDefaults` on its original container so Instagram's
  cold-launch UI dismissal flags can persist normally, while mirroring writes
  from `group.*` suites into the shared container used by app extensions

The additive group-defaults mirror keeps notification-extension account state
in sync with the main app. This matters for multi-account installs where the
extension can otherwise treat a signed-in recipient as logged out and redact or
misroute its notification. Extension diagnostics log missing suite/key names,
redacting long numeric identifiers, but never preference values or account
credentials.

It also normalizes Keychain access groups for sideloaded signatures. The four
intercepted `SecItem` operations resolve a usable group from a sentinel Keychain
item first and fall back to runtime entitlements. Existing access-group values
in add/query/delete dictionaries are replaced, and missing values are injected.
For `SecItemUpdate`, the query is normalized the same way while the separate
attributes-to-update dictionary is changed only when it already contains an
access group, avoiding an unintended item migration.

Keychain diagnostics report only the operation, result status, timing, and
whether a group was found/replaced/injected. Access-group strings, Keychain
values, cookies, and credentials are never logged.

Persistent diagnostics are opt-in from Sparkle's Tools settings. When enabled,
both Instagram and its notification extension append timestamped process,
container, defaults-key, and Keychain-result events to a shared log. The log is
bounded to 1 MiB and can be viewed, copied, shared, or cleared in-app. It never
records notification content, defaults values, access-group strings, tokens,
cookies, or credentials.

For duplicate-app sideloads, main-bundle runtime queries are normalized to
Instagram's original `com.burbn.instagram` identifier through both
`bundleIdentifier` and `objectForInfoDictionaryKey:`. The packaged identifier
is not changed, and non-main bundles keep their actual identities. This matches
Instagram's original runtime namespace for code that derives persisted-state
identifiers while still allowing a distinct identifier at install time.

The spoof is scoped to the app process and never applies inside an app
extension. In an appex the extension's own bundle *is* the main bundle, so an
unscoped spoof rewrites the extension's identifier too, and
`ExtensionFoundation` derives its XPC listener name from it. The notification
extension then listened on `com.burbn.instagram.apple-extension-service`
(`Operation not permitted`) while SpringBoard connected to
`com.burbn.instagram.notificationextension.apple-extension-service`. Nothing
answered, so the extension burned its full startup budget and was killed:

    Extension will be killed because it used its runtime in starting up
    Did not mutate content for notification request, will deliver original
    content; runtime: 30.013551

That single condition produced three separate-looking symptoms: empty
lock-screen previews (content was never mutated), duplicate banners
(Instagram's own notification dedupe runs in that extension and never
executed), and pushes arriving around a minute late (the 30 second timeout,
across retries).

Build with:

```sh
make -C modules/SPKSideloadFix DEBUG=0 FINALPACKAGE=1
```

`build.sh ipa --patch` builds this dylib and passes it to `ipapatch --dylib`
automatically.
