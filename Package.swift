// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PhotoCaptureManager",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "PhotoCaptureManager",
            targets: ["PhotoCaptureManager"]
        ),
    ],
    targets: [
        .target(
            name: "PhotoCaptureManager",
            dependencies: []
        ),
        .testTarget(
            name: "PhotoCaptureManagerTests",
            dependencies: ["PhotoCaptureManager"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
