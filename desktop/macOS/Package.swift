// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrokDesktop",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GrokDesktop", targets: ["GrokDesktop"])],
    // Vendored in-tree (see third_party/README.md): the embedded terminal's emulator, and the
    // Libraries.dev effects the app's look is built with (liquid metal, border beam, thinking orbs,
    // voice glow). Their Metal shaders are compiled by scripts/build-app.sh.
    dependencies: [
        .package(path: "../../third_party/SwiftTerm"),
        .package(path: "../../third_party/LibrariesDev"),
    ],
    targets: [
        .executableTarget(name: "GrokDesktop", dependencies: [
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "LibrariesDevSupport", package: "LibrariesDev"),
            .product(name: "MetalFxKit", package: "LibrariesDev"),
            .product(name: "BorderBeamKit", package: "LibrariesDev"),
            .product(name: "ThinkingOrbsKit", package: "LibrariesDev"),
            .product(name: "VoiceGlowKit", package: "LibrariesDev"),
        ]),
        .testTarget(name: "GrokDesktopTests", dependencies: ["GrokDesktop"])
    ]
)
