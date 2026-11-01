// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HermeticaSDK",
    // macOS is only there so `swift test` runs on a Mac; the SDK targets iOS apps.
    platforms: [.iOS(.v13), .macOS(.v10_15)],
    products: [.library(name: "HermeticaSDK", targets: ["HermeticaSDK"])],
    targets: [
        .target(name: "HermeticaSDK"),
        .testTarget(name: "HermeticaSDKTests", dependencies: ["HermeticaSDK"]),
    ]
)
