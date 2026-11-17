#!/bin/bash
# Build D2SMetal and metaltest.dylib on Linux with clang + lld and an
# iPhoneOS SDK (e.g. theos/sdks iPhoneOS16.5.sdk). Usage: build-linux.sh SDK OUT
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SDK=$1 OUT=$2
mkdir -p "$OUT"
F=(-target arm64-apple-ios16.0 -isysroot "$SDK" -fuse-ld=lld -O2 -Wall -Wno-unused-function -I"$HERE/../d2s-gpu")
clang "${F[@]}" -fno-objc-arc -bundle -framework Foundation -framework IOKit -framework IOSurface -framework Metal -o "$OUT/D2SMetal" "$HERE/D2SMetal.m"
clang "${F[@]}" -fobjc-arc -dynamiclib -install_name /usr/lib/metaltest.dylib -framework Foundation \
	-framework IOKit -framework Metal -framework QuartzCore -framework CoreGraphics \
	-o "$OUT/metaltest.dylib" "$HERE/metaltest.m"
cp "$HERE/Info.plist" "$OUT/Info.plist"
file "$OUT/D2SMetal" "$OUT/metaltest.dylib"
