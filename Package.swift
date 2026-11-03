// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftpolisKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SwiftpolisDomain", targets: ["SwiftpolisDomain"]),
        .library(name: "SwiftpolisPersistence", targets: ["SwiftpolisPersistence"]),
        .library(name: "SwiftpolisEngines", targets: ["SwiftpolisEngines"]),
        .library(name: "SwiftpolisServices", targets: ["SwiftpolisServices"]),
        .library(name: "SwiftpolisBridge", targets: ["SwiftpolisBridge"]),
    ],
    targets: [
        // Used by the Safari extension and the native-messaging helper, so it stays small.
        .target(name: "SwiftpolisBridge"),
        .testTarget(name: "SwiftpolisBridgeTests", dependencies: ["SwiftpolisBridge"]),
        .target(name: "SwiftpolisDomain"),
        .target(name: "SwiftpolisPersistence", dependencies: ["SwiftpolisDomain"]),
        .target(name: "SwiftpolisEngines", dependencies: ["SwiftpolisDomain"]),
        .target(
            name: "SwiftpolisServices",
            dependencies: ["SwiftpolisBridge", "SwiftpolisDomain", "SwiftpolisEngines", "SwiftpolisPersistence"]
        ),
        .target(name: "SwiftpolisTestSupport", dependencies: ["SwiftpolisDomain", "SwiftpolisEngines"]),
        .testTarget(
            name: "SwiftpolisServicesTests",
            dependencies: [
                "SwiftpolisBridge", "SwiftpolisDomain", "SwiftpolisEngines", "SwiftpolisPersistence",
                "SwiftpolisServices", "SwiftpolisTestSupport",
            ]
        ),
        .testTarget(
            name: "SwiftpolisEnginesTests",
            dependencies: ["SwiftpolisDomain", "SwiftpolisEngines", "SwiftpolisTestSupport"]
        ),
        .testTarget(
            name: "SwiftpolisDomainTests",
            dependencies: ["SwiftpolisDomain", "SwiftpolisTestSupport"]
        ),
        .testTarget(
            name: "SwiftpolisPersistenceTests",
            dependencies: ["SwiftpolisDomain", "SwiftpolisPersistence"]
        ),
    ]
)
