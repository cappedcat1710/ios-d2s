#!/bin/bash
# Build Mesa's panfrost Gallium driver (+ the AIR frontend) for iOS 16 arm64 ON LINUX
# with clang + lld and an iPhoneOS SDK (no macOS runner needed).
#   build-linux.sh SDK WORKDIR        e.g. build-linux.sh ~/ios-d2s-src/sdk/iPhoneOS16.5.sdk /data/mesa-work
# Needs: llvm clang lld libclc spirv-llvm-translator spirv-tools meson ninja python-mako python-yaml bison flex.
# Stage 1 builds the host tools natively, stage 2 cross-builds the static libraries.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SDK=$1 W=$2
MESA_TAG=mesa-26.2.6
mkdir -p "$W/pc"
if [ ! -d "$W/mesa" ]; then
	git clone -q --depth 1 --branch $MESA_TAG https://gitlab.freedesktop.org/mesa/mesa.git "$W/mesa"
fi
python3 "$HERE/patch-mesa.py" "$W/mesa" >/dev/null
# the AIR frontend (tools/d2s-metal/air) and the line of meson that reaches it
rm -rf "$W/mesa/src/compiler/air" && cp -r "$REPO/tools/d2s-metal/air" "$W/mesa/src/compiler/air"
grep -q "subdir('air')" "$W/mesa/src/compiler/meson.build" ||
	sed -i "s/^subdir('spirv')$/subdir('spirv')\n\nsubdir('air')/" "$W/mesa/src/compiler/meson.build"
sed "s#@PREFIX@#$HERE/libdrm#" "$HERE/libdrm/libdrm.pc.in" > "$W/pc/libdrm.pc"

COMMON=(-Dbuildtype=release -Dgallium-drivers=panfrost -Dvulkan-drivers= -Dplatforms=
	-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true
	-Dshader-cache=disabled -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled
	-Dbuild-tests=false -Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled)

echo "=== stage 1: native host tools"
if [ ! -f "$W/native/build.ninja" ]; then
	PKG_CONFIG_PATH="$W/pc" meson setup "$W/native" "$W/mesa" "${COMMON[@]}" \
		-Dllvm=enabled -Dmesa-clc=enabled -Dprecomp-compiler=enabled
fi
ninja -C "$W/native" src/compiler/clc/mesa_clc src/compiler/spirv/vtn_bindgen2 src/panfrost/clc/panfrost_compile
mkdir -p "$W/bin"
cp "$W/native/src/compiler/clc/mesa_clc" "$W/native/src/compiler/spirv/vtn_bindgen2" \
	"$W/native/src/panfrost/clc/panfrost_compile" "$W/bin/"
export PATH="$W/bin:$PATH"

echo "=== stage 2: iOS cross build"
FLAGS="'-target', 'arm64-apple-ios16.0', '-isysroot', '$SDK', '-Wno-unused-command-line-argument'"
LFLAGS="$FLAGS, '-fuse-ld=lld'"
cat > "$W/ios-cross.txt" <<EOT
[binaries]
c = ['clang']
cpp = ['clang++']
objc = ['clang']
ar = 'llvm-ar'
strip = 'llvm-strip'
pkg-config = 'pkg-config'

[built-in options]
c_args = [$FLAGS]
cpp_args = [$FLAGS]
objc_args = [$FLAGS]
c_link_args = [$LFLAGS]
cpp_link_args = [$LFLAGS]
objc_link_args = [$LFLAGS]

[properties]
needs_exe_wrapper = true
pkg_config_libdir = ['$W/pc']

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOT
if [ ! -f "$W/ios/build.ninja" ]; then
	meson setup "$W/ios" "$W/mesa" --cross-file "$W/ios-cross.txt" "${COMMON[@]}" \
		-Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system \
		-Ddefault_library=static -Db_ndebug=true
fi
ninja -C "$W/ios" -k 0
ninja -C "$W/ios" -t targets all | sed -n 's/^\([^:]*\.a\): .*/\1/p' | sort -u > "$W/static-targets.txt"
echo "$(wc -l < "$W/static-targets.txt") static library targets"
ninja -C "$W/ios" -k 0 $(cat "$W/static-targets.txt")
