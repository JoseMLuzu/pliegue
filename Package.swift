// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Pliegue",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PliegueCore", targets: ["PliegueCore"]),
        .executable(name: "Pliegue", targets: ["PliegueApp"]),
    ],
    targets: [
        .target(name: "PliegueCore", linkerSettings: [.linkedLibrary("z")]),
        .executableTarget(name: "PliegueApp", dependencies: ["PliegueCore"]),
        .testTarget(name: "PliegueCoreTests", dependencies: ["PliegueCore"], resources: [.copy("Fixtures")]),
    ]
)
