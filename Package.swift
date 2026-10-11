// swift-tools-version: 6.2

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "ComposableKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        // Reducer, Store, Effect, Dependency, Shared, Bindings, TestStore, TestClock.
        // A single product: the app's test target only `import`s it (without
        // linking it again), so the process never loads two copies of the library.
        .library(name: "ComposableKit", targets: ["ComposableKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .macro(
            name: "ComposableKitMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "ComposableKit",
            dependencies: ["ComposableKitMacros"]
        ),
        .testTarget(
            name: "ComposableKitTests",
            dependencies: ["ComposableKit"]
        ),
        .testTarget(
            name: "ComposableKitMacrosTests",
            dependencies: [
                "ComposableKitMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
