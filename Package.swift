// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TP7VibeInput",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TP7VibeInput", targets: ["TP7VibeInput"]),
        .executable(name: "TP7MIDICapture", targets: ["TP7MIDICapture"])
    ],
    targets: [
        .executableTarget(
            name: "TP7VibeInput",
            path: "Sources/TP7VibeInput",
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("IOKit"),
                .linkedFramework("SceneKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .executableTarget(
            name: "TP7MIDICapture",
            path: "Sources/TP7MIDICapture",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreMIDI"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
