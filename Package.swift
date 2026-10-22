// swift-tools-version:6.0
import PackageDescription

// Library only. The runnable demo lives in a separate repository
// (app-intent-contract-demo-app) that consumes this package as a remote,
// version-pinned dependency. There is deliberately no executable target here.
let package = Package(
    name: "IntentContracts",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "IntentContracts", targets: ["IntentContracts"]),
        .library(name: "IntentContractsUI", targets: ["IntentContractsUI"])
    ],
    targets: [
        .target(name: "IntentContracts"),
        .target(name: "IntentContractsUI", dependencies: ["IntentContracts"]),
        .testTarget(name: "IntentContractsTests", dependencies: ["IntentContracts"])
    ]
)
