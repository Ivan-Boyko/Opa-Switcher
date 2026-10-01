// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Opa",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Opa", targets: ["Opa"]),
        .library(name: "SwitcherCore", targets: ["SwitcherCore"]),
    ],
    targets: [
        .target(name: "SwitcherCore"),
        .executableTarget(name: "Opa", dependencies: ["SwitcherCore"]),
    ]
)
