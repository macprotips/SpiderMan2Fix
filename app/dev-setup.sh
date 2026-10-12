#!/bin/bash
# One-time setup and everyday build for working on the app on your own Mac.
#
#   ./dev-setup.sh          check tools, build the shader tools once, test, build, open the app
#   ./dev-setup.sh --no-open    same, without opening the app at the end
#
# Needs an Apple Silicon Mac. Installs nothing without telling you what and why.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -m)" == arm64 ]] || fail "This needs an Apple Silicon Mac (M1 or later)."

say "Checking Apple's developer tools"
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "Apple's command line developer tools aren't installed. A window will open to install them."
    xcode-select --install || true
    fail "When that install finishes, run ./dev-setup.sh again."
fi
swift --version | head -n 1

if [[ ! -x .dxc/bin/dxc ]]; then
    say "Checking Homebrew (needed once, to build Microsoft's shader tools)"
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew isn't installed. Install it from https://brew.sh (one line to paste into Terminal),"
        echo "then run ./dev-setup.sh again."
        fail "Homebrew missing."
    fi
    for tool in cmake ninja; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Installing $tool with Homebrew"; brew install "$tool"; }
    done
    say "Building Microsoft's shader tools (once; about 10-20 minutes, needs ~3 GB free)"
    ./build-dxc.sh
    rm -rf .dxc-build   # the 3 GB source and build folder; only .dxc is kept
fi

# Runs a step with its full output in build-logs/<name>.log; on failure shows the errors.
step() { # name, command...
    local name="$1"; shift
    mkdir -p build-logs
    if "$@" > "build-logs/$name.log" 2>&1; then
        tail -n 2 "build-logs/$name.log"
    else
        echo "Failed. The errors:"
        grep -E -B2 -A8 "error:|FAIL|failed" "build-logs/$name.log" | head -n 80
        fail "$name failed. Full log: $PWD/build-logs/$name.log"
    fi
}

# The tests use XCTest, which comes with the full Xcode app, not the Command Line Tools.
dev="$(xcode-select -p)"
if [[ -d "$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework" \
      || -d "$dev/Library/Developer/Frameworks/XCTest.framework" ]]; then
    say "Running the tests"
    step tests env SM2FIX_DXC="$PWD/.dxc/bin" swift test --disable-swift-testing
else
    say "Skipping the tests: they need the full Xcode app (free in the App Store)."
    echo "That's fine: GitHub runs every test on each change. Install Xcode only if you want to run them here."
fi

say "Building the app"
step build ./build-app.sh
APP="build/Spider-Man 2 T-Pose Fix.app"
"$APP/Contents/MacOS/SM2Fix" --selftest | tail -n 1

say "Done: $PWD/$APP"
[[ "${1:-}" == --no-open ]] || open "$APP"
