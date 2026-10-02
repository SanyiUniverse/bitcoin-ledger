#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
QA_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/bitcoin-ledger-panels.XXXXXX")"
trap 'rm -r "$QA_STAGE"' EXIT
QA_ROOT="$QA_STAGE/work/panel-qa"
QA_PACKAGE="$QA_ROOT/harness"
mkdir -p "$QA_PACKAGE/Sources/LedgerCore" "$QA_PACKAGE/Sources/PanelQA"
cp "$PROJECT_DIR"/Sources/LedgerCore/*.swift "$QA_PACKAGE/Sources/LedgerCore/"
for source in AppStore ContentView DetailViews Editors PanelPresentation BTCChartView BTCChartInput; do
    cp "$PROJECT_DIR/Sources/BitcoinLedger/$source.swift" "$QA_PACKAGE/Sources/PanelQA/"
done
cp "$PROJECT_DIR/Tests/NativePanelChecks/PanelChecks.swift" "$QA_PACKAGE/Sources/PanelQA/"
cat > "$QA_PACKAGE/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PanelQA", platforms: [.macOS(.v14)], targets: [
    .target(name: "LedgerCore"),
    .executableTarget(name: "PanelQA", dependencies: ["LedgerCore"])
])
SWIFT
QA_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
if [[ ! -d "$QA_SDK" ]]; then QA_SDK="$(xcrun --sdk macosx --show-sdk-path)"; fi
swift build --package-path "$QA_PACKAGE" --sdk "$QA_SDK"
QA_BIN="$(swift build --package-path "$QA_PACKAGE" --sdk "$QA_SDK" --show-bin-path)"
QA_RESULT=0
QA_OUTPUT="$QA_ROOT" "$QA_BIN/PanelQA" || QA_RESULT=$?
# Optional retained evidence contains PNGs/report only. Fixtures, copied source,
# and build artifacts are always confined to QA_STAGE and removed on exit.
if [[ -n "${PANEL_QA_ARTIFACTS:-}" ]]; then
    mkdir -p "$PANEL_QA_ARTIFACTS"
    cp "$QA_ROOT"/*.png "$QA_ROOT/report.txt" "$PANEL_QA_ARTIFACTS/"
fi
exit "$QA_RESULT"
