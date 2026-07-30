#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="$(/usr/bin/xcode-select -p)"
TESTING_FRAMEWORKS="$DEVELOPER_DIR/Library/Developer/Frameworks"
TESTING_FRAMEWORK="$TESTING_FRAMEWORKS/Testing.framework"
TESTING_MACROS="$DEVELOPER_DIR/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
TESTING_LIBRARIES="$DEVELOPER_DIR/Library/Developer/usr/lib"
TESTING_INTEROP="$TESTING_LIBRARIES/lib_TestingInterop.dylib"
TOOLCHAIN_ARGUMENTS=(--enable-swift-testing --disable-xctest)

if [[ "$DEVELOPER_DIR" == *"/CommandLineTools" ]]; then
    if [[ ! -d "$TESTING_FRAMEWORK" ]]; then
        echo "Swift Testing is unavailable: missing $TESTING_FRAMEWORK" >&2
        echo "Active developer directory: $DEVELOPER_DIR" >&2
        echo "Install matching Command Line Tools or select a complete Xcode toolchain." >&2
        exit 1
    fi

    if [[ ! -f "$TESTING_MACROS" ]]; then
        echo "Swift Testing is unavailable: missing macro plugin $TESTING_MACROS" >&2
        echo "Active developer directory: $DEVELOPER_DIR" >&2
        echo "Install matching Command Line Tools or select a complete Xcode toolchain." >&2
        exit 1
    fi

    if [[ ! -f "$TESTING_INTEROP" ]]; then
        echo "Swift Testing is unavailable: missing runtime $TESTING_INTEROP" >&2
        echo "Active developer directory: $DEVELOPER_DIR" >&2
        echo "Install matching Command Line Tools or select a complete Xcode toolchain." >&2
        exit 1
    fi

    TOOLCHAIN_ARGUMENTS+=(
        -Xswiftc -F
        -Xswiftc "$TESTING_FRAMEWORKS"
        -Xswiftc -load-plugin-library
        -Xswiftc "$TESTING_MACROS"
        -Xlinker -F
        -Xlinker "$TESTING_FRAMEWORKS"
        -Xlinker -rpath
        -Xlinker "$TESTING_FRAMEWORKS"
        -Xlinker -rpath
        -Xlinker "$TESTING_LIBRARIES"
    )
fi

export DYLD_FRAMEWORK_PATH="$TESTING_FRAMEWORKS${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
export DYLD_LIBRARY_PATH="$TESTING_LIBRARIES${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"

exec swift test \
    --package-path "$ROOT_DIR" \
    "${TOOLCHAIN_ARGUMENTS[@]}" \
    "$@"
