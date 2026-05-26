// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.
//
// Generated file. Do not edit.
//

import PackageDescription

let package = Package(
    name: "FlutterGeneratedPluginSwiftPackage",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "FlutterGeneratedPluginSwiftPackage", type: .static, targets: ["FlutterGeneratedPluginSwiftPackage"])
    ],
    dependencies: [
        .package(name: "integration_test", path: "../.packages/integration_test"),
        .package(name: "flutter_native_splash", path: "../.packages/flutter_native_splash-2.4.7"),
        .package(name: "video_player_avfoundation", path: "../.packages/video_player_avfoundation-2.9.4"),
        .package(name: "url_launcher_ios", path: "../.packages/url_launcher_ios-6.4.1"),
        .package(name: "shared_preferences_foundation", path: "../.packages/shared_preferences_foundation-2.5.6"),
        .package(name: "package_info_plus", path: "../.packages/package_info_plus-9.0.0"),
        .package(name: "image_picker_ios", path: "../.packages/image_picker_ios-0.8.13+6"),
        .package(name: "device_info_plus", path: "../.packages/device_info_plus-12.3.0"),
        .package(name: "camera_avfoundation", path: "../.packages/camera_avfoundation-0.9.23+2"),
        .package(name: "sqlite3_flutter_libs", path: "../.packages/sqlite3_flutter_libs-0.5.42"),
        .package(name: "FlutterFramework", path: "../.packages/FlutterFramework")
    ],
    targets: [
        .target(
            name: "FlutterGeneratedPluginSwiftPackage",
            dependencies: [
                .product(name: "integration-test", package: "integration_test"),
                .product(name: "flutter-native-splash", package: "flutter_native_splash"),
                .product(name: "video-player-avfoundation", package: "video_player_avfoundation"),
                .product(name: "url-launcher-ios", package: "url_launcher_ios"),
                .product(name: "shared-preferences-foundation", package: "shared_preferences_foundation"),
                .product(name: "package-info-plus", package: "package_info_plus"),
                .product(name: "image-picker-ios", package: "image_picker_ios"),
                .product(name: "device-info-plus", package: "device_info_plus"),
                .product(name: "camera-avfoundation", package: "camera_avfoundation"),
                .product(name: "sqlite3-flutter-libs", package: "sqlite3_flutter_libs"),
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ]
        )
    ]
)
