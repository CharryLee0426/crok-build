// swift-tools-version: 5.9
import PackageDescription

// The SwiftUI ports of Libraries.dev (https://github.com/Jakubantalik/Libraries.dev, MIT),
// vendored for Crok Desktop's look. Upstream commit bfcb863 (2026-10-16).
//
// Local patches (see README.md for the details and the re-vendoring checklist):
//   • The .metal shaders live in Shaders/ and are compiled by build-shaders.sh into one
//     LibrariesDev.metallib that the app bundles; SwiftPM alone cannot compile them.
//     `ShaderLibrary.bundle(.module)` reads `LibrariesDevShaders.library` instead.
//   • No SwiftPM resources: a resource bundle sits at an app bundle's root, where it breaks
//     code signing. border-beam's beam-spec.json is compiled in (BeamSpecJSON.swift).
//   • Every TimelineView honours `paused` and the shared frame-rate cap
//     (`LibrariesDevShaders.frameInterval`), so a still effect does no work per frame.
let package = Package(
    name: "LibrariesDev",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LibrariesDevSupport", targets: ["LibrariesDevSupport"]),
        .library(name: "MetalFxKit", targets: ["MetalFxKit"]),
        .library(name: "BorderBeamKit", targets: ["BorderBeamKit"]),
        .library(name: "ThinkingOrbsKit", targets: ["ThinkingOrbsKit"]),
        .library(name: "VoiceGlowKit", targets: ["VoiceGlowKit"]),
    ],
    targets: [
        .target(name: "LibrariesDevSupport"),
        .target(name: "MetalFxKit", dependencies: ["LibrariesDevSupport"]),
        .target(name: "BorderBeamKit", dependencies: ["LibrariesDevSupport"]),
        .target(name: "ThinkingOrbsKit", dependencies: ["LibrariesDevSupport"]),
        .target(name: "VoiceGlowKit", dependencies: ["LibrariesDevSupport"]),
    ]
)
