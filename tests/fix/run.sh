#!/usr/bin/env bash
# End-to-end test of the fix's d3d12.dll under Wine: fake game -> build/fix/d3d12.dll -> mock driver.
set -euo pipefail
cd "$(dirname "$0")/../.."
./build.sh >/dev/null
if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then CC=(x86_64-w64-mingw32-gcc)
elif command -v zig >/dev/null 2>&1; then CC=(zig cc -target x86_64-windows-gnu)
else CC=(python3 -m ziglang cc -target x86_64-windows-gnu); fi
OUT=build/fix-test
rm -rf "$OUT" && mkdir -p "$OUT"
cp build/fix/d3d12.dll "$OUT/"
"${CC[@]}" -O1 -shared -o "$OUT/mock_d3d12.dll" tests/fix/mock_d3d12.c shim/sm2fix_dxbc.c shim/sm2fix_core.c tests/fix/mock_d3d12.def
"${CC[@]}" -O1 -o "$OUT/fix_game.exe" tests/fix/fix_game.c shim/sm2fix_core.c
export WINEPREFIX="${WINEPREFIX:-$PWD/build/wineprefix}" WINEDEBUG=-all WINEDLLOVERRIDES="d3d12=n,b"
cd "$OUT"
status=0
expect_log() { grep -q "$1" sm2fix.log || { echo "FAIL ($2): log lacks: $1"; cat sm2fix.log; status=1; }; }
wine fix_game.exe match || status=1
expect_log "Game build .* matches. Applying the fix (2 shaders)." match
expect_log "Replaced shader .*: ok" match
expect_log "Wide typed view (536346624 elements) created as a raw view" match
expect_log "Wide typed UAV (536346624 elements) created as a raw view" match
expect_log "Exit: 2 shaders replaced, 1 wide views and 1 wide UAVs made raw" match
wine fix_game.exe other-build || status=1
expect_log "the game was updated" other-build
wine fix_game.exe missing-shader || status=1
expect_log "Missing or damaged sm2fix-pool-" missing-shader
wine fix_game.exe no-ini || status=1
expect_log "No sm2fix.ini: not applying the fix." no-ini
[[ $status == 0 ]] && echo "fix tests passed"
exit $status
