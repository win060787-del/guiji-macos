// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NovaContext",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "NovaContext", targets: ["NovaContext"]), .library(name: "ContextCore", targets: ["ContextCore"])],
    dependencies: [
        .package(path: "../Packages/MiaoYanCore"),
        .package(path: "Vendor/swift-cmark-gfm"),
        .package(path: "Vendor/ZIPFoundation"),
    ],
    targets: [
        .binaryTarget(name: "NativeOCR", path: "Vendor/NativeOCR.xcframework"),
        .target(
            name: "ContextCore",
            dependencies: [
                "NativeOCR", "MiaoYanCore", "ZIPFoundation", .product(name: "CMarkGFM", package: "swift-cmark-gfm"),
            ], resources: [.copy("Resources")], linkerSettings: [.linkedLibrary("c++")]),
        .executableTarget(name: "NovaContext", dependencies: ["ContextCore"], resources: [.copy("Resources"), .process("BrandAssets.xcassets")]),
        .testTarget(name: "ContextCoreTests", dependencies: ["ContextCore", "ZIPFoundation"]),
        .testTarget(name: "StoreAssetTests", dependencies: ["NovaContext", "ContextCore"]),
    ],
    swiftLanguageModes: [.v5]
)
