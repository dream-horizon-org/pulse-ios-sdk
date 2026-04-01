// swift-tools-version: 5.9
//
// Default: PulseKit from **source** via the repository root (`../..`).
// For **prebuilt xcframeworks** under `../../build/`, see `README.md` and swap in the manifest shown there.

import PackageDescription

let package = Package(
    name: "PulseSPMExample",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(name: "PulseSPMExampleSupport", targets: ["PulseKitWrapper"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "PulseKitWrapper",
            dependencies: [
                .product(name: "PulseKit", package: "pulse-ios-sdk"),
            ],
            path: "PulseKitWrapper"
        ),
    ]
)
