#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="NotchNotes"
APP_VERSION="${APP_VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-3}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/.build/release-universal}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist.noindex}"
APP_DIR="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.png"
SOURCE_PLIST="$ROOT_DIR/Resources/Info.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

cd "$ROOT_DIR"
swift build \
  -c release \
  --arch arm64 \
  --arch x86_64 \
  --scratch-path "$BUILD_DIR"

BINARY_PATH="$BUILD_DIR/apple/Products/Release/$APP_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
  echo "找不到构建产物：$BINARY_PATH" >&2
  exit 1
fi

ARCHS="$(lipo -archs "$BINARY_PATH")"
if [[ "$ARCHS" != *"arm64"* || "$ARCHS" != *"x86_64"* ]]; then
  echo "构建产物不是通用架构：$ARCHS" >&2
  exit 1
fi

rm -rf "$APP_DIR"
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
cp "$SOURCE_PLIST" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"

if [[ -f "$SOURCE_ICON" ]]; then
  TMP_ICON_DIR="$(mktemp -d)"
  trap 'rm -rf "$TMP_ICON_DIR"' EXIT
  ICONSET_DIR="$TMP_ICON_DIR/AppIcon.iconset"
  mkdir -p "$ICONSET_DIR"

  sips -z 16 16 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32.png" >/dev/null
  sips -z 64 64 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
  sips -z 1024 1024 "$SOURCE_ICON" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
  iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
  rm -rf "$TMP_ICON_DIR"
  trap - EXIT
fi

xattr -cr "$APP_DIR"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_DIR"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

create_archive() {
  rm -f "$ZIP_PATH"
  ditto --norsrc -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
}

create_archive

if [[ -n "$NOTARY_PROFILE" ]]; then
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "公证需要 Developer ID 签名，请设置 SIGN_IDENTITY。" >&2
    exit 1
  fi

  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  codesign --verify --deep --strict --verbose=2 "$APP_DIR"
  spctl --assess --type execute --verbose=2 "$APP_DIR"
  create_archive
fi

(
  cd "$DIST_DIR"
  shasum -a 256 "$APP_NAME.zip" > "$APP_NAME.zip.sha256"
)

echo "Built $APP_DIR"
echo "Architectures: $ARCHS"
echo "Archive: $ZIP_PATH"
echo "Checksum: $CHECKSUM_PATH"
