// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Branchline",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Branchline", targets: ["Branchline"]), .executable(name: "branchline-cli", targets: ["BranchlineCLI"])],
    targets: [
        .target(name: "ProgressCore"),
        .executableTarget(name: "Branchline", dependencies: ["ProgressCore"]),
        .executableTarget(name: "BranchlineCLI", dependencies: ["ProgressCore"]),
        .executableTarget(name: "ProgressChecks", dependencies: ["ProgressCore"], path: "Tests/ProgressCoreTests")
    ]
)
