#!/usr/bin/env bash
#
# Builds MediaRemoteAdapter.framework from the vendored sources in
# Vendor/mediaremote-adapter.
#
# Usage: ./scripts/build-adapter.sh <output-dir> [signing-identity]
#
# Produces <output-dir>/MediaRemoteAdapter.framework, universal (arm64 +
# x86_64), ad-hoc signed unless an identity is passed.
#
# Why clang and not CMake
# -----------------------
# Upstream ships a CMakeLists.txt, but CMake is not installed on every machine
# that builds NotchHub and there is no Homebrew here. The framework is fifteen
# Objective-C files linked against three system frameworks — reproducing that
# with clang directly costs a dozen lines and removes a build dependency
# entirely. Keep this in step with Vendor/mediaremote-adapter/CMakeLists.txt
# semantics on every version bump: ARC on, default symbol visibility (the Perl
# script resolves exported functions by name, so hidden visibility silently
# breaks it at runtime, not at build time).
set -euo pipefail

OUT_DIR="${1:-}"
IDENTITY="${2:-}"
if [[ -z "$OUT_DIR" ]]; then
  echo "usage: $0 <output-dir> [signing-identity]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/mediaremote-adapter"
NAME="MediaRemoteAdapter"

[[ -d "$SRC/src" && -f "$SRC/bin/mediaremote-adapter.pl" ]] || {
  echo "error: vendored adapter sources missing at $SRC" >&2
  exit 1
}

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
FW="$OUT_DIR/$NAME.framework"

SOURCES=(
  "$SRC"/src/adapter/env.m
  "$SRC"/src/adapter/get.m
  "$SRC"/src/adapter/globals.m
  "$SRC"/src/adapter/keys.m
  "$SRC"/src/adapter/now_playing.m
  "$SRC"/src/adapter/repeat.m
  "$SRC"/src/adapter/seek.m
  "$SRC"/src/adapter/send.m
  "$SRC"/src/adapter/shuffle.m
  "$SRC"/src/adapter/speed.m
  "$SRC"/src/adapter/stream.m
  "$SRC"/src/adapter/test.m
  "$SRC"/src/private/MediaRemote.m
  "$SRC"/src/utility/Debounce.m
  "$SRC"/src/utility/helpers.m
)

echo "▸ Building $NAME.framework (arm64 + x86_64)…"
rm -rf "$FW"
mkdir -p "$FW/Versions/A/Resources" "$FW/Versions/A/Headers"

clang \
  -arch arm64 -arch x86_64 \
  -mmacosx-version-min=14.0 \
  -dynamiclib -fobjc-arc -fvisibility=default -O2 \
  -I"$SRC/src" -I"$SRC/include" \
  -framework Foundation -framework AppKit -framework UniformTypeIdentifiers \
  -install_name "@rpath/$NAME.framework/Versions/A/$NAME" \
  -o "$FW/Versions/A/$NAME" \
  "${SOURCES[@]}"

cp "$SRC/include/$NAME.h" "$FW/Versions/A/Headers/$NAME.h"

cat > "$FW/Versions/A/Resources/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$NAME</string>
	<key>CFBundleIdentifier</key>
	<string>com.vandenbe.$NAME</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$NAME</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1</string>
	<key>CFBundleVersion</key>
	<string>0.1.0</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
</dict>
</plist>
PLIST

# Framework bundles are versioned directories held together by symlinks.
ln -sfn A "$FW/Versions/Current"
ln -sfn "Versions/Current/$NAME" "$FW/$NAME"
ln -sfn Versions/Current/Resources "$FW/Resources"
ln -sfn Versions/Current/Headers "$FW/Headers"

xattr -cr "$FW" 2>/dev/null || true
if [[ -n "$IDENTITY" ]]; then
  echo "▸ Signing $NAME.framework with \"$IDENTITY\"…"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW"
else
  codesign --force --sign - "$FW"
fi
codesign --verify --strict "$FW"

echo "✓ Built $FW"
