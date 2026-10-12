#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g -o build/test_core tests/test_core.c shim/sm2fix_core.c shim/sm2fix_dxbc.c
./build/test_core
