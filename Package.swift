// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pliegue",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PliegueCore", targets: ["PliegueCore"]),
    ],
    targets: [
        .target(name: "PliegueCore", linkerSettings: [.linkedLibrary("z")]),
    ]
)
