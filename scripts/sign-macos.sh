#!/usr/bin/env bash
# Build, sign, notarize and staple the macOS desktop app, then stage the
# release zips beside it.
#
# Runs on GitHub-hosted macOS or a workstation. Environment credentials take
# precedence; ~/.config/petdex-apple/env remains a local fallback.
# APPLE_NOTARY_PROFILE may name credentials already stored with notarytool.
# Otherwise provide APPLE_API_KEY (path), APPLE_API_KEY_ID, APPLE_API_ISSUER.
# SIGN_IDENTITY must be a Developer ID Application identity in the keychain.
#
# Usage: scripts/sign-macos.sh [output-dir] [arm64|x64] [--unsigned]
# --unsigned is packaging QA only; its files have different, non-release names.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$REPO_ROOT/dist/macos}"
if [[ "$OUT" != /* ]]; then
  OUT="$REPO_ROOT/$OUT"
fi
if [[ -n "${NATIVE_CLI:-}" && "$NATIVE_CLI" != /* ]]; then
  NATIVE_CLI="$REPO_ROOT/$NATIVE_CLI"
  export NATIVE_CLI
fi
if [[ -n "${NATIVE_SDK_PATH:-}" && "$NATIVE_SDK_PATH" != /* ]]; then
  NATIVE_SDK_PATH="$REPO_ROOT/$NATIVE_SDK_PATH"
  export NATIVE_SDK_PATH
fi
if [[ -n "${NATIVE_PACKAGER_CLI:-}" && "$NATIVE_PACKAGER_CLI" != /* ]]; then
  NATIVE_PACKAGER_CLI="$REPO_ROOT/$NATIVE_PACKAGER_CLI"
  export NATIVE_PACKAGER_CLI
fi
# Which Mac this build runs on. arm64 by default so the common case is
# unchanged; pass x64 for the Intel build (#609). Cross-compiled from
# either host: Zig does not need an Intel machine, but the signature and
# notarization still come from this keychain, so both architectures ship
# from the same workstation run.
ARCH="${2:-arm64}"
case "$ARCH" in
  arm64) ZIG_TARGET="aarch64-macos" ;;
  x64)   ZIG_TARGET="x86_64-macos" ;;
  *) echo "unknown arch: $ARCH (expected arm64 or x64)" >&2; exit 1 ;;
esac
PKG="$REPO_ROOT/packages/petdex-desktop-native"
CREDS="$HOME/.config/petdex-apple/env"

UNSIGNED=false
case "${3:-}" in
  --unsigned) UNSIGNED=true ;;
  "") ;;
  *) echo "unknown option: $3" >&2; exit 1 ;;
esac
SUFFIX=""
SIGNING=(--signing adhoc)
if [[ "$UNSIGNED" == true ]]; then
  SUFFIX="-unsigned"
else
  if [[ -z "${SIGN_IDENTITY:-}" || ( -z "${APPLE_NOTARY_PROFILE:-}" && -z "${APPLE_API_KEY:-}" ) ]]; then
    [[ -f "$CREDS" ]] || { echo "Set signing/notarization environment variables or provide $CREDS" >&2; exit 1; }
    # shellcheck disable=SC1090
    set -a; . "$CREDS"; set +a
  fi
  : "${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
  [[ "$SIGN_IDENTITY" == "Developer ID Application: "* ]] || {
    echo "Release signing requires a Developer ID Application identity" >&2; exit 1;
  }
  if [[ -z "${APPLE_NOTARY_PROFILE:-}" ]]; then
    : "${APPLE_API_KEY:?set APPLE_API_KEY to the notarization key path}"
    : "${APPLE_API_KEY_ID:?set APPLE_API_KEY_ID}"
    : "${APPLE_API_ISSUER:?set APPLE_API_ISSUER}"
    KEY="$APPLE_API_KEY"
    [[ -f "$KEY" ]] || KEY="$(dirname "$CREDS")/$(basename "$APPLE_API_KEY")"
    [[ -f "$KEY" ]] || { echo "missing notarization key" >&2; exit 1; }
    APPLE_NOTARY_PROFILE=petdex-notary
    xcrun notarytool store-credentials "$APPLE_NOTARY_PROFILE" \
      --key "$KEY" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER"
  fi
  SIGNING=(--signing identity --identity "$SIGN_IDENTITY" --notarize --notary-profile "$APPLE_NOTARY_PROFILE")
fi

: "${NATIVE_CLI:?set NATIVE_CLI to the native CLI built from the pinned SDK}"
: "${NATIVE_SDK_PATH:?set NATIVE_SDK_PATH to the pinned SDK checkout}"
: "${NATIVE_PACKAGER_CLI:?set NATIVE_PACKAGER_CLI to the Native SDK 0.10.1 CLI}"
DMGBUILD="${DMGBUILD:-${XDG_CACHE_HOME:-$HOME/.cache}/petdex/dmgbuild/bin/dmgbuild}"
[[ -x "$DMGBUILD" ]] || { echo "run scripts/setup-native-packager.sh first" >&2; exit 1; }

"$(dirname "${BASH_SOURCE[0]}")/patch-native-sdk.sh"

mkdir -p "$OUT"
# Only this arch's outputs: a second run for the other arch must not
# delete what the first one produced.
rm -rf "$OUT/Petdex.app" "$OUT/petdex-desktop-darwin-$ARCH$SUFFIX.zip" \
  "$OUT/petdex-desktop-native-darwin-$ARCH$SUFFIX.zip" "$OUT/Petdex-$ARCH$SUFFIX.dmg"

echo "==> build ($ARCH)"
# -Dcpu=baseline for the same reason the release workflow uses it: Zig
# targets the host CPU otherwise, and a Mac newer than the user's would
# emit instructions their machine cannot decode (#604 was exactly this
# on Windows).
(cd "$PKG" && "$NATIVE_CLI" build -Dtarget="$ZIG_TARGET" -Dcpu=baseline -Dtrace=off)

echo "==> package + sign"
# The bundle must be named Petdex.app: the name is baked into the
# signature, so renaming it afterwards breaks the seal.
(cd "$PKG" && "$NATIVE_PACKAGER_CLI" package \
  --target macos \
  --manifest app.package.json \
  --binary zig-out/bin/petdex-desktop-native \
  --output "$OUT/Petdex.app" \
  "${SIGNING[@]}")

PLIST="$OUT/Petdex.app/Contents/Info.plist"
PACKAGE_VERSION="$(bun -e 'console.log((await Bun.file(process.argv[1]).json()).version)' "$PKG/app.package.json")"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" == "$PACKAGE_VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$PLIST")" == petdex ]]
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
MACH_ARCH=arm64
[[ "$ARCH" != x64 ]] || MACH_ARCH=x86_64
lipo "$OUT/Petdex.app/Contents/MacOS/$EXECUTABLE" -verify_arch "$MACH_ARCH"
test -f "$OUT/Petdex.app/Contents/Resources/assets/icon.png"
codesign --verify --deep --strict "$OUT/Petdex.app"
if [[ "$UNSIGNED" == false ]]; then
  xcrun stapler validate "$OUT/Petdex.app"
  spctl -a -vvv "$OUT/Petdex.app"
fi

echo "==> dmg"
# Stage the already-stapled app. dmgbuild writes .DS_Store directly, so CI
# never needs Apple Events, Finder permissions or an interactive desktop.
DMG="$OUT/Petdex-$ARCH$SUFFIX.dmg"
BACKGROUND="$(bun -e 'console.log((await Bun.file(process.argv[1]).json()).dmg.background)' "$PKG/app.package.json")"
RETINA_BACKGROUND="${BACKGROUND%.*}@2x.${BACKGROUND##*.}"
export PETDEX_DMG_BACKGROUND="$PKG/$BACKGROUND"
if [[ -f "$PKG/$RETINA_BACKGROUND" ]]; then
  tiffutil -cathidpicheck "$PKG/$BACKGROUND" "$PKG/$RETINA_BACKGROUND" -out "$OUT/background.tiff"
  export PETDEX_DMG_BACKGROUND="$OUT/background.tiff"
fi
export PETDEX_PACKAGE_MANIFEST="$PKG/app.package.json"
export PETDEX_PACKAGED_APP="$OUT/Petdex.app"
VOLUME_NAME="$(bun -e 'console.log((await Bun.file(process.argv[1]).json()).dmg.volume_name)' "$PKG/app.package.json")"
"$DMGBUILD" -s "$PKG/packaging/dmg/settings.py" "$VOLUME_NAME" "$DMG"
# Verify what users actually copy out of the image. Packaging tools can add
# FinderInfo/resource forks that invalidate even a previously verified app.
VERIFY_MOUNT="$(mktemp -d "$OUT/dmg-verify.XXXXXX")"
cleanup_mount() {
  if [[ -n "$VERIFY_MOUNT" ]]; then
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
    rmdir "$VERIFY_MOUNT" 2>/dev/null || true
  fi
}
trap cleanup_mount EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$VERIFY_MOUNT" "$DMG" >/dev/null
codesign --verify --deep --strict "$VERIFY_MOUNT/Petdex.app"
[[ "$(readlink "$VERIFY_MOUNT/Applications")" == /Applications ]]
test -f "$VERIFY_MOUNT/.DS_Store"
if [[ "$UNSIGNED" == false ]]; then
  xcrun stapler validate "$VERIFY_MOUNT/Petdex.app"
fi
hdiutil detach "$VERIFY_MOUNT" >/dev/null
rmdir "$VERIFY_MOUNT"
VERIFY_MOUNT=""
if [[ "$UNSIGNED" == false ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --strict "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$APPLE_NOTARY_PROFILE" \
    --wait --output-format json > "$OUT/notarization-$ARCH.json"
  bun -e 'const r = await Bun.file(process.argv[1]).json(); if (r.status !== "Accepted") { console.error(r); process.exit(1); }' "$OUT/notarization-$ARCH.json"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vvv -t open --context context:primary-signature "$DMG"
fi

echo "==> stage release assets"
# Both zip names carry the same notarized bundle. petdex-desktop-<target>
# is the name existing installs update through; shipping a bare
# executable under it does not work, since a lone Mach-O outside its
# bundle fails Gatekeeper the same way an unsigned app does.
ditto -c -k --keepParent "$OUT/Petdex.app" "$OUT/petdex-desktop-native-darwin-$ARCH$SUFFIX.zip"
cp "$OUT/petdex-desktop-native-darwin-$ARCH$SUFFIX.zip" "$OUT/petdex-desktop-darwin-$ARCH$SUFFIX.zip"

ls -lh "$OUT"/*.zip "$DMG"
if [[ "$UNSIGNED" == true ]]; then
  echo "Packaging preview only: ad-hoc signed, not notarized, not for distribution."
fi
