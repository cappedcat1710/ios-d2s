#!/bin/bash
# Build D2SMetal.bundle's executable and metaltest.dylib for iOS 16 arm64
# (macOS runner with Xcode). Output: tools/d2s-metal/out/.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
FLAGS=(-arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -O2 -Wall -I"$HERE/../d2s-gpu")
"$CC" "${FLAGS[@]}" -fno-objc-arc -bundle -framework Foundation -framework IOKit -framework IOSurface -framework Metal \
	-o "$OUT/D2SMetal" "$HERE/D2SMetal.m"
"$CC" "${FLAGS[@]}" -fobjc-arc -dynamiclib -install_name /usr/lib/metaltest.dylib \
	-framework Foundation -framework IOKit -framework Metal -framework QuartzCore -framework CoreGraphics \
	-o "$OUT/metaltest.dylib" "$HERE/metaltest.m"
cp "$HERE/Info.plist" "$OUT/Info.plist"
file "$OUT/D2SMetal" "$OUT/metaltest.dylib" || true
