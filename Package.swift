// swift-tools-version: 6.0
// MumbleKit: the client core for the iOS app (and a macOS build of it, so it can be tested without a
// simulator). Native code comes in as one prebuilt xcframework (tools/build-deps.sh) behind the small C
// bridge in Sources/CMumbleBridge.
import PackageDescription

let package = Package(
    name: "MumbleKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MumbleKit", targets: ["MumbleKit"]),
    ],
    targets: [
        .binaryTarget(name: "MumbleNative", path: "Frameworks/MumbleNative.xcframework"),
        .target(
            name: "CMumbleBridge",
            dependencies: ["MumbleNative"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(name: "MumbleKit", dependencies: ["CMumbleBridge"]),
        .testTarget(name: "MumbleKitTests", dependencies: ["MumbleKit"], resources: [.copy("Resources")]),
    ],
    cxxLanguageStandard: .cxx20
)
