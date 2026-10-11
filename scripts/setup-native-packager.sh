#!/usr/bin/env bash
# The runtime SDK predates the signing/notarization packager.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF=064ca9890cc0cf8adc198215bd0ddaeb586c220a
export NATIVE_PACKAGER_SDK_PATH="${NATIVE_PACKAGER_SDK_PATH:-${XDG_CACHE_HOME:-$HOME/.cache}/petdex/native-packager-$REF}"
if [[ ! -d "$NATIVE_PACKAGER_SDK_PATH/.git" ]]; then
  git init "$NATIVE_PACKAGER_SDK_PATH"
  git -C "$NATIVE_PACKAGER_SDK_PATH" remote add origin https://github.com/vercel-labs/native.git
  git -C "$NATIVE_PACKAGER_SDK_PATH" fetch --depth 1 origin "$REF"
  git -C "$NATIVE_PACKAGER_SDK_PATH" checkout --detach "$REF"
fi
[[ "$(git -C "$NATIVE_PACKAGER_SDK_PATH" rev-parse HEAD)" == "$REF" ]] || {
  echo "packager checkout must be at $REF" >&2; exit 1;
}
(cd "$NATIVE_PACKAGER_SDK_PATH" && zig build cli)
DMG_TOOLS="${XDG_CACHE_HOME:-$HOME/.cache}/petdex/dmgbuild"
"${PETDEX_PYTHON:-python3}" -m venv --clear "$DMG_TOOLS"
"$DMG_TOOLS/bin/python" -m pip install --disable-pip-version-check --require-hashes \
  -r "$ROOT/scripts/macos-packaging-requirements.txt"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  echo "NATIVE_PACKAGER_SDK_PATH=$NATIVE_PACKAGER_SDK_PATH" >> "$GITHUB_ENV"
  echo "NATIVE_PACKAGER_CLI=$NATIVE_PACKAGER_SDK_PATH/zig-out/bin/native" >> "$GITHUB_ENV"
  echo "DMGBUILD=$DMG_TOOLS/bin/dmgbuild" >> "$GITHUB_ENV"
fi
echo "Packager: $NATIVE_PACKAGER_SDK_PATH/zig-out/bin/native"
