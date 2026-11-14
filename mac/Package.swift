// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VRDesktopHost",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Prebuilt Google WebRTC (libwebrtc) for Apple platforms.
        .package(url: "https://github.com/stasel/WebRTC.git", "125.0.0"..<"300.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "VRDesktopHost",
            dependencies: [.product(name: "WebRTC", package: "WebRTC")],
            path: "Sources/VRDesktopHost"
        ),
    ]
)
