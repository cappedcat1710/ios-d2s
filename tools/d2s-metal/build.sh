#!/bin/bash
# Build D2SMetal.bundle's executable for iOS 16 arm64 (macOS runner with Xcode).
# Output: tools/d2s-metal/out/D2SMetal (Mach-O bundle) and out/Info.plist.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$HERE/out
mkdir -p "$OUT"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=$(xcrun --sdk iphoneos -f clang)
"$CC" -arch arm64 -isysroot "$SDK" -miphoneos-version-min=16.0 -O2 -fobjc-arc -fno-objc-arc-exceptions \
	-I"$HERE/../d2s-gpu" -bundle -framework Foundation -framework IOKit \
	-o "$OUT/D2SMetal" "$HERE/D2SMetal.m"
cp "$HERE/Info.plist" "$OUT/Info.plist"
file "$OUT/D2SMetal" || true
