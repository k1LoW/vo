// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vo",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "vo", targets: ["vo"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")
    ],
    targets: [
        // Objective-C only because Swift cannot catch an NSException, which AVFAudio
        // raises on a tap format mismatch. See Sources/VoObjC/include/VoObjC.h.
        .target(
            name: "VoObjC",
            path: "Sources/VoObjC"
        ),
        .executableTarget(
            name: "vo",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "VoObjC"
            ],
            path: "Sources/vo"
        ),
        .testTarget(
            name: "voTests",
            dependencies: ["vo", "VoObjC"],
            path: "Tests/voTests"
        )
    ]
)
