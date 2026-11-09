// swift-tools-version: 5.9
// The Swift Package Manager build of the plugin. ../qvp_flutter.podspec is the CocoaPods
// build, and both read the same sources and the same QvpEngine.xcframework.
// scripts/build-engine-ios.sh puts the framework next to this file. Git does not track it.

import PackageDescription

let package = Package(
    name: "qvp_flutter",
    platforms: [
        .macOS("12.0")
    ],
    products: [
        // Dynamic, like the framework CocoaPods builds under use_frameworks!. Dart finds the
        // engine with DynamicLibrary.process(), so its symbols must stay exported. Linked
        // statically into the app, a release build strips them.
        .library(name: "qvp-flutter", type: .dynamic, targets: ["qvp_flutter"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "qvp_flutter",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "QvpEngine",
            ]
        ),
        .binaryTarget(name: "QvpEngine", path: "QvpEngine.xcframework"),
    ]
)
