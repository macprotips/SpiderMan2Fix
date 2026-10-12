#!/usr/bin/env bash
# Builds build/fix/d3d12.dll, the fix the app installs (Windows x86_64). Needs a MinGW-w64
# cross compiler (brew install mingw-w64 / apt install mingw-w64) or Zig (brew install zig,
# or pip install ziglang).
set -euo pipefail
cd "$(dirname "$0")"

FLAGS=(-O2 -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type -shared)

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    CC=(x86_64-w64-mingw32-gcc)
    FLAGS+=(-static-libgcc)
elif command -v zig >/dev/null 2>&1; then
    CC=(zig cc -target x86_64-windows-gnu)
elif python3 -c "import ziglang" >/dev/null 2>&1; then
    CC=(python3 -m ziglang cc -target x86_64-windows-gnu)
else
    echo "Need x86_64-w64-mingw32-gcc or zig. Try: brew install mingw-w64" >&2
    exit 1
fi

mkdir -p build/fix
"${CC[@]}" "${FLAGS[@]}" -o build/fix/d3d12.dll shim/fix.c shim/sm2fix_core.c shim/fix.def
echo "built build/fix/d3d12.dll"
