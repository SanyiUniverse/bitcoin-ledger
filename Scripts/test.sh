#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [ -n "${BITCOIN_LEDGER_SDK:-}" ]; then
    LEDGER_SDK="$BITCOIN_LEDGER_SDK"
elif [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    LEDGER_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
    LEDGER_SDK="$(xcrun --show-sdk-path)"
fi

# XCTest is not included in this Mac's CLT; Apple Swift Testing is. Explicitly
# load its installed macro plugin. An isolated temporary build also avoids
# Documents/File Provider metadata invalidating signed test bundles.
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitcoin-ledger-tests.XXXXXX")"
trap 'rm -r "$TEST_BUILD_DIR"' EXIT
TEST_FLAGS=(--sdk "$LEDGER_SDK" --scratch-path "$TEST_BUILD_DIR" --disable-xctest --enable-swift-testing)
TEST_PLUGIN_DIR="$(dirname "$(xcrun --find swift)")/../lib/swift/host/plugins/testing"
if [ -d "$TEST_PLUGIN_DIR" ]; then
    TEST_FLAGS+=(-Xswiftc -plugin-path -Xswiftc "$TEST_PLUGIN_DIR")
fi
swift test "${TEST_FLAGS[@]}" "$@"
