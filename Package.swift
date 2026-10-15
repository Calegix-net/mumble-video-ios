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
        // Screen sharing: the H.264 encoder and the socket to the app. Apple frameworks only, so the
        // broadcast extension (50 MB memory limit) links nothing else.
        .library(name: "MumbleShare", targets: ["MumbleShare"]),
        .executable(name: "mv-test-peer", targets: ["mv-test-peer"]),
    ],
    dependencies: [
        // Keep in step with SWIFT_PROTOBUF_VERSION in tools/versions.sh (the code generator).
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .binaryTarget(name: "MumbleNative", path: "Frameworks/MumbleNative.xcframework"),
        .target(
            name: "CMumbleBridge",
            dependencies: ["MumbleNative"],
            linkerSettings: [.linkedLibrary("c++")]
        ),
        .target(
            name: "MumbleKit",
            dependencies: ["CMumbleBridge", .product(name: "SwiftProtobuf", package: "swift-protobuf")]
        ),
        .target(name: "MumbleShare"),
        .executableTarget(name: "mv-test-peer", dependencies: ["MumbleKit"]),
        .testTarget(name: "MumbleKitTests", dependencies: ["MumbleKit", "MumbleShare"], resources: [.copy("Resources")]),
    ],
    cxxLanguageStandard: .cxx20
)
