#!/bin/sh
# Builds libKestrelNotch.dylib (KestrelNotch.m) into the app's
# Contents/Frameworks and signs it as the app is: run by Xcode, a build phase
# of Runner's.
set -e
src="$PROJECT_DIR/Runner/KestrelNotch.m"
out_dir="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$out_dir"
out="$out_dir/libKestrelNotch.dylib"
arch_flags=""
for arch in $ARCHS; do arch_flags="$arch_flags -arch $arch"; done
xcrun clang -O2 -dynamiclib -fobjc-arc -framework Cocoa -framework Carbon \
  $arch_flags -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
  -install_name "@rpath/libKestrelNotch.dylib" \
  -x objective-c -o "$out" "$src"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
options=""
if [ "$ENABLE_HARDENED_RUNTIME" = "YES" ]; then options="--options runtime"; fi
codesign --force --sign "$identity" $options --timestamp=none "$out"

# Also build libAyteNative.dylib (embedded WKWebView + Computer Use native bridge).
ayte_src="$PROJECT_DIR/Runner/AyteNative.m"
if [ -f "$ayte_src" ]; then
  ayte_out="$out_dir/libAyteNative.dylib"
  xcrun clang -O2 -dynamiclib -fobjc-arc \
    -framework Cocoa -framework WebKit -framework Carbon \
    -framework ApplicationServices -framework CoreGraphics \
    $arch_flags -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    -install_name "@rpath/libAyteNative.dylib" \
    -x objective-c -o "$ayte_out" "$ayte_src"
  codesign --force --sign "$identity" $options --timestamp=none "$ayte_out"
fi
