// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Open Speech ASR",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "OpenSpeechASR", targets: ["OpenSpeechASR"]),
        .executable(name: "asr-smoke-test", targets: ["ASRSmokeTest"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.30.0"),
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "OpenSpeechASR",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "Qwen3ASR", package: "speech-swift")
            ],
            path: "Sources",
            exclude: [],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .executableTarget(
            name: "ASRSmokeTest",
            dependencies: [
                .product(name: "Qwen3ASR", package: "speech-swift")
            ],
            path: "Tools/ASRSmokeTest"
        )
    ]
)
