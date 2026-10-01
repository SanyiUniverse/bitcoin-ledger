#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

# This Mac has CLT with a 27.0 SDK but no SwiftUIMacros plugin. Use the
# installed stable SDK when available. Do not change global developer settings.
if [ -n "${BITCOIN_LEDGER_SDK:-}" ]; then
    LEDGER_SDK="$BITCOIN_LEDGER_SDK"
elif [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
    LEDGER_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
else
    LEDGER_SDK="$(xcrun --show-sdk-path)"
fi
swift build --sdk "$LEDGER_SDK" -c release --product BitcoinLedger
LEDGER_BIN_DIR="$(swift build --sdk "$LEDGER_SDK" -c release --show-bin-path)"
# Build the signed bundle outside Documents: File Provider attaches FinderInfo
# there immediately, which Apple's strict signature verification rejects.
PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bitcoin-ledger-package.XXXXXX")"
trap 'rm -r "$PACKAGE_DIR"' EXIT
APP_DIR="$PACKAGE_DIR/Bitcoin Ledger.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$LEDGER_BIN_DIR/BitcoinLedger" "$APP_DIR/Contents/MacOS/BitcoinLedger"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
chmod 755 "$APP_DIR/Contents/MacOS/BitcoinLedger"
# Only clean metadata on the app bundle this script has just created.
xattr -dr com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP_DIR" 2>/dev/null || true
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist"
ARCHIVE_PATH="$PROJECT_DIR/../Bitcoin Ledger.zip"
ditto -c -k --keepParent --norsrc --noextattr "$APP_DIR" "$ARCHIVE_PATH"
printf 'Built: %s\n' "$ARCHIVE_PATH"
if [ "${1:-}" = "--install" ]; then
    if [ -e "/Applications/Bitcoin Ledger.app" ]; then
        printf 'Existing installed app retained. Quit it and replace it manually in Finder.\n' >&2
        exit 1
    fi
    ditto --norsrc --noextattr "$APP_DIR" "/Applications/Bitcoin Ledger.app"
    codesign --verify --strict "/Applications/Bitcoin Ledger.app"
    printf 'Installed: %s\n' "/Applications/Bitcoin Ledger.app"
fi
