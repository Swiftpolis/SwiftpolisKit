// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftpolisKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SwiftpolisDomain", targets: ["SwiftpolisDomain"]),
        .library(name: "SwiftpolisPersistence", targets: ["SwiftpolisPersistence"]),
        .library(name: "SwiftpolisEngines", targets: ["SwiftpolisEngines"]),
    ],
    targets: [
        .target(name: "SwiftpolisDomain"),
        .target(name: "SwiftpolisPersistence", dependencies: ["SwiftpolisDomain"]),
        .target(name: "SwiftpolisEngines", dependencies: ["SwiftpolisDomain"]),
        .target(name: "SwiftpolisTestSupport", dependencies: ["SwiftpolisDomain"]),
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
