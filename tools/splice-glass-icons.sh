#!/usr/bin/env bash
# splice-glass-icons.sh <App.app>
#
# Compiles every Icon Composer package in resources/*.icon with actool and
# splices the result into the app's existing Assets.car, then registers each one
# as an alternate icon by CFBundleIconName. Instagram's own catalog is kept
# byte-for-byte; only new facets and renditions are added (tools/car-splice).
#
# Asset names are namespaced as SPKAppIcon-<name> because Instagram already
# ships unrelated assets with short names such as "sparkle". The alternate icon
# key stays <name>. Alongside each icon, two appearance-aware imagesets are
# rendered with Icon Composer's ictool for the in-app picker, since an icon stack
# cannot be loaded as a UIImage: SPKAppIconPreview-<name> (default and dark) and
# SPKAppIconPreview-<name>-Clear (clear and clear dark).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:?usage: splice-glass-icons.sh <App.app>}"
CATALOG="$APP_DIR/Assets.car"
PLIST="$APP_DIR/Info.plist"

if [ ! -f "$CATALOG" ]; then
    echo "splice-glass-icons: $CATALOG not found" >&2
    exit 1
fi

shopt -s nullglob
packages=("$ROOT_DIR"/resources/*.icon)
shopt -u nullglob
if [ ${#packages[@]} -eq 0 ]; then
    echo "  No .icon packages in resources/, skipping app icons"
    exit 0
fi

# Icon Composer's ictool, not the unrelated asset catalog ictool xcrun finds.
ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
if [ ! -x "$ictool" ]; then
    ictool="/Applications/Icon Composer.app/Contents/Executables/ictool"
fi
if [ ! -x "$ictool" ]; then
    echo "splice-glass-icons: Icon Composer ictool not found (install Xcode 26+)" >&2
    exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-glass-icons.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

clang -fobjc-arc -framework Foundation -framework CoreGraphics \
    "$ROOT_DIR/tools/car-splice/car-splice.m" -o "$work_dir/car-splice"

render_preview() {
    local package="$1" rendition="$2" scale="$3" output="$4"
    "$ictool" "$package" --export-image --output-file "$output" --platform iOS \
        --rendition "$rendition" --width 72 --height 72 --scale "$scale" >/dev/null
}

# Each preview imageset gets a catalog of its own. Compiled together, actool
# packs small images into shared atlases whose keys are the same in every
# catalog, so they would land on top of Instagram's atlases.
#
# preview_imageset <package> <asset name> <light rendition> <dark rendition>
preview_catalogs=()
preview_imageset() {
    local package="$1" asset="$2" light="$3" dark="$4" scale
    local catalog="$work_dir/$asset.xcassets"
    local imageset="$catalog/$asset.imageset"
    mkdir -p "$imageset"
    printf '{"info":{"author":"xcode","version":1}}\n' > "$catalog/Contents.json"
    preview_catalogs+=("$catalog")
    for scale in 2 3; do
        render_preview "$package" "$light" "$scale" "$imageset/light@${scale}x.png"
        render_preview "$package" "$dark" "$scale" "$imageset/dark@${scale}x.png"
    done
    cat > "$imageset/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "light@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "filename" : "light@3x.png", "idiom" : "universal", "scale" : "3x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "dark@2x.png", "idiom" : "universal", "scale" : "2x" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "dark@3x.png", "idiom" : "universal", "scale" : "3x" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
}

names=()
inputs=()
for package in "${packages[@]}"; do
    name="$(basename "$package" .icon)"
    cp -R "$package" "$work_dir/SPKAppIcon-$name.icon"
    names+=("$name")
    inputs+=("$work_dir/SPKAppIcon-$name.icon")

    preview_imageset "$package" "SPKAppIconPreview-$name" Default Dark
    preview_imageset "$package" "SPKAppIconPreview-$name-Clear" ClearLight ClearDark
done

min_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$PLIST" 2>/dev/null || echo 15.0)"
# compile_and_splice <label> <actool inputs and flags...>
compile_and_splice() {
    local output="$work_dir/compiled-$1"
    shift
    mkdir -p "$output"
    xcrun actool "$@" \
        --compile "$output" \
        --platform iphoneos \
        --minimum-deployment-target "$min_os" \
        --output-partial-info-plist "$output/partial.plist" \
        --output-format human-readable-text >/dev/null
    "$work_dir/car-splice" "$CATALOG" "$output/Assets.car" "$work_dir/Assets.car" >/dev/null
    mv -f "$work_dir/Assets.car" "$CATALOG"
}

compile_and_splice icons "${inputs[@]}" --include-all-app-icons
for catalog in "${preview_catalogs[@]}"; do
    compile_and_splice "$(basename "$catalog" .xcassets)" "$catalog"
done

SPK_PLIST="$PLIST" SPK_ICON_NAMES="$(IFS=,; echo "${names[*]}")" python3 -I - <<'PY'
import os
import plistlib

path = os.environ["SPK_PLIST"]
names = [n for n in os.environ["SPK_ICON_NAMES"].split(",") if n]

with open(path, "rb") as fh:
    raw = fh.read()
fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist") else plistlib.FMT_XML
root = plistlib.loads(raw)

for container in ("CFBundleIcons", "CFBundleIcons~ipad"):
    icons = root.setdefault(container, {})
    alternates = icons.setdefault("CFBundleAlternateIcons", {})
    for name in names:
        alternates[name] = {"CFBundleIconName": f"SPKAppIcon-{name}"}

with open(path, "wb") as fh:
    plistlib.dump(root, fh, fmt=fmt)
PY

echo "  Spliced ${#names[@]} app icon(s) into Assets.car: ${names[*]}"
