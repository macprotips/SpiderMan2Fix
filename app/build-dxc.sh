#!/bin/bash
# Builds Microsoft's DirectX Shader Compiler tools (dxc, dxa, dxv and libdxcompiler) for
# this Mac into ./.dxc. The app uses them to build the fix's two shaders on the user's
# Mac from their own copy of the game, so no game data ships with the fix.
#
# Pinned to the DXC commit the fix was verified with: the shaders it produces must be
# byte-identical to the verified ones (the app checks their hashes).
#   ./build-dxc.sh      (about 30-60 minutes; needs cmake, ninja and Xcode)
set -euo pipefail
cd "$(dirname "$0")"
DXC_COMMIT=6e0fab36dc9ac8c423e1b08fed3aeb0e739d9e54
OUT="$PWD/.dxc"
WORK="${DXC_WORK:-$PWD/.dxc-build}"

mkdir -p "$WORK"
if [[ ! -d "$WORK/src/.git" ]]; then
    git init -q "$WORK/src"
    git -C "$WORK/src" remote add origin https://github.com/microsoft/DirectXShaderCompiler.git
fi
git -C "$WORK/src" fetch -q --depth 1 origin "$DXC_COMMIT"
git -C "$WORK/src" checkout -q FETCH_HEAD
git -C "$WORK/src" submodule update -q --init --depth 1 --recursive

cmake -S "$WORK/src" -B "$WORK/build" -G Ninja -C "$WORK/src/cmake/caches/PredefinedParams.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DSPIRV_WERROR=OFF -DCLANG_FORMAT_EXE=OFF -DHLSL_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_TESTS=OFF \
    -DCLANG_INCLUDE_TESTS=OFF -DENABLE_SPIRV_CODEGEN=OFF -DSPIRV_BUILD_TESTS=OFF
ninja -C "$WORK/build" dxc dxa dxv

rm -rf "$OUT"
mkdir -p "$OUT/bin" "$OUT/lib" "$OUT/licenses"
for tool in dxc dxa dxv; do
    cp "$(cd "$WORK/build/bin" && pwd -P)/$(readlink "$WORK/build/bin/$tool" || echo "$tool")" "$OUT/bin/$tool"
done
cp "$WORK/build/lib/libdxcompiler.dylib" "$OUT/lib/"
[[ -f "$WORK/build/lib/libdxil.dylib" ]] && cp "$WORK/build/lib/libdxil.dylib" "$OUT/lib/"
strip -x "$OUT"/bin/* "$OUT"/lib/*.dylib
cp "$WORK/src/LICENSE.TXT" "$OUT/licenses/DXC-LICENSE.txt"
cp "$WORK/src/ThirdPartyNotices.txt" "$OUT/licenses/DXC-ThirdPartyNotices.txt"
echo "$DXC_COMMIT" > "$OUT/COMMIT"
"$OUT/bin/dxc" --version
otool -L "$OUT/bin/dxa" | grep -i dx
du -sh "$OUT"
