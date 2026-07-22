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
  cold-launch UI dismissal flags can persist normally

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

Build with:

```sh
make -C modules/SPKSideloadFix DEBUG=0 FINALPACKAGE=1
```

`build.sh ipa --patch` builds this dylib and passes it to `ipapatch --dylib`
automatically.
