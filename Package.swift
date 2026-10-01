// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BitcoinLedger",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"]),
        .executable(name: "BitcoinLedger", targets: ["BitcoinLedger"])
    ],
    targets: [
        .target(name: "LedgerCore"),
        .executableTarget(name: "BitcoinLedger", dependencies: ["LedgerCore"]),
        .testTarget(name: "LedgerCoreTests", dependencies: ["LedgerCore"])
    ]
)
