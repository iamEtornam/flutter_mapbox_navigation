// swift-tools-version: 5.9
import PackageDescription

// Flutter plugin Swift package. Navigation SDK v3 for iOS is distributed only via
// Swift Package Manager, so consuming apps must enable Flutter's Swift Package
// Manager support (`flutter config --enable-swift-package-manager`).
let package = Package(
    name: "mapbox_navigation_sdk",
    platforms: [
        .iOS("14.0")
    ],
    products: [
        .library(name: "mapbox-navigation-sdk", targets: ["mapbox_navigation_sdk"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework"),
        .package(url: "https://github.com/mapbox/mapbox-navigation-ios.git", from: "3.24.0"),
        .package(url: "https://github.com/mapbox/mapbox-maps-ios.git", from: "11.0.0")
    ],
    targets: [
        .target(
            name: "mapbox_navigation_sdk",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                .product(name: "MapboxNavigationCore", package: "mapbox-navigation-ios"),
                .product(name: "MapboxNavigationUIKit", package: "mapbox-navigation-ios"),
                .product(name: "MapboxDirections", package: "mapbox-navigation-ios"),
                .product(name: "MapboxMaps", package: "mapbox-maps-ios")
            ]
        )
    ]
)
