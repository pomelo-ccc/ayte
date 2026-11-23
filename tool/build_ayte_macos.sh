#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER="${FLUTTER:-$(command -v flutter || echo "$HOME/flutter/bin/flutter")}"
SDK_ROOT="$(xcrun --sdk macosx --show-sdk-path)"
CLANG="${CLANG:-/Library/Developer/CommandLineTools/usr/bin/clang}"
BASE_APP="${BASE_APP:-/Applications/Ayte.app}"
if [[ ! -d "$BASE_APP" ]]; then
  BASE_APP="/Applications/Byte.app"
fi

if [[ ! -d "$BASE_APP" ]]; then
  echo "Error: base macOS .app bundle not found at /Applications/Ayte.app" >&2
  exit 1
fi

STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
ditto "$BASE_APP" "$STAGE_DIR/Template.app"

cd "$REPO"
"$FLUTTER" assemble --no-version-check \
  --output=build/macos/Build/Products/Release/ \
  -dTargetPlatform=darwin \
  -dTargetFile=lib/main.dart \
  -dBuildMode=release \
  -dConfiguration=Release \
  -dDarwinArchs=arm64 \
  -dSdkRoot="$SDK_ROOT" \
  -dSplitDebugInfo= \
  -dDartObfuscation=false \
  -dTreeShakeIcons=true \
  -dTrackWidgetCreation=true \
  -dSrcRoot="$REPO/macos" \
  -dXcodeBuildScript=prepare \
  release_macos_bundle_flutter_assets

ditto "$STAGE_DIR/Template.app" "$STAGE_DIR/Ayte.app"
FULL_VER="$(sed -n 's/^version:[[:space:]]*//p' "$REPO/pubspec.yaml")"
SHORT_VER="${FULL_VER%%+*}"
BUILD_VER="${FULL_VER#*+}"
if [[ "$BUILD_VER" == "$FULL_VER" ]]; then BUILD_VER="0"; fi

PLIST="$STAGE_DIR/Ayte.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Ayte" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ayte" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Ayte" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.ayte.desktop" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VER" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright 'Copyright © 2026 Ayte. All rights reserved.'" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSAppleEventsUsageDescription 'A program run in Ayte wants to control another app.'" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :NSMicrophoneUsageDescription 'Ayte uses your microphone for voice input and hands-free voice conversation.'" "$PLIST" 2>/dev/null || \
  /usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'Ayte uses your microphone for voice input and hands-free voice conversation.'" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :NSLocalNetworkUsageDescription 'Ayte lets the phones paired with it find it on the local network.'" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName dev.ayte.desktop" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 ayte" "$PLIST" 2>/dev/null || true

EXT_PLIST="$STAGE_DIR/Ayte.app/Contents/PlugIns/FinderExtension.appex/Contents/Info.plist"
if [[ -f "$EXT_PLIST" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Ayte" "$EXT_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Ayte" "$EXT_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.ayte.desktop.FinderExtension" "$EXT_PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SHORT_VER" "$EXT_PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VER" "$EXT_PLIST" 2>/dev/null || true
fi

rm -f "$STAGE_DIR/Ayte.app/Contents/Resources/Assets.car"
ICONSET_DIR="$STAGE_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
APPICON_SRC="$REPO/macos/Runner/Assets.xcassets/AppIcon.appiconset"
if [[ -d "$APPICON_SRC" ]]; then
  cp "$APPICON_SRC/app_icon_16.png"   "$ICONSET_DIR/icon_16x16.png"
  cp "$APPICON_SRC/app_icon_32.png"   "$ICONSET_DIR/icon_16x16@2x.png"
  cp "$APPICON_SRC/app_icon_32.png"   "$ICONSET_DIR/icon_32x32.png"
  cp "$APPICON_SRC/app_icon_64.png"   "$ICONSET_DIR/icon_32x32@2x.png"
  cp "$APPICON_SRC/app_icon_128.png"  "$ICONSET_DIR/icon_128x128.png"
  cp "$APPICON_SRC/app_icon_256.png"  "$ICONSET_DIR/icon_128x128@2x.png"
  cp "$APPICON_SRC/app_icon_256.png"  "$ICONSET_DIR/icon_256x256.png"
  cp "$APPICON_SRC/app_icon_512.png"  "$ICONSET_DIR/icon_256x256@2x.png"
  cp "$APPICON_SRC/app_icon_512.png"  "$ICONSET_DIR/icon_512x512.png"
  cp "$APPICON_SRC/app_icon_1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
  iconutil -c icns "$ICONSET_DIR" -o "$STAGE_DIR/Ayte.app/Contents/Resources/AppIcon.icns"
fi

rm -rf "$STAGE_DIR/Ayte.app/Contents/Frameworks/App.framework"
cp -R "$REPO/build/macos/Build/Products/Release/App.framework" "$STAGE_DIR/Ayte.app/Contents/Frameworks/"
"$CLANG" -isysroot "$SDK_ROOT" -dynamiclib -fobjc-arc -framework Cocoa -framework Carbon \
  -x objective-c "$REPO/macos/Runner/KestrelNotch.m" \
  -o "$STAGE_DIR/Ayte.app/Contents/Frameworks/libKestrelNotch.dylib"
"$CLANG" -isysroot "$SDK_ROOT" -dynamiclib -fobjc-arc \
  -framework Cocoa -framework WebKit -framework Carbon -framework ApplicationServices -framework CoreGraphics \
  -install_name "@rpath/libAyteNative.dylib" \
  -x objective-c "$REPO/macos/Runner/AyteNative.m" \
  -o "$STAGE_DIR/Ayte.app/Contents/Frameworks/libAyteNative.dylib"

xattr -cr "$STAGE_DIR/Ayte.app"
codesign --force --deep --sign - "$STAGE_DIR/Ayte.app"
codesign --verify --deep --strict "$STAGE_DIR/Ayte.app"
rm -rf "/Applications/Ayte.app"
mv "$STAGE_DIR/Ayte.app" "/Applications/Ayte.app"
touch "/Applications/Ayte.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/Ayte.app" || true
killall iconservicesagent usernoted NotificationCenter 2>/dev/null || true
echo "✓ Built and installed /Applications/Ayte.app"
