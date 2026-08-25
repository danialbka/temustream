// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StremioSkeleton",
    platforms: [
        .iOS(.v16),
        .tvOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "StremioSkeletonCore", targets: ["StremioSkeletonCore"]),
        .executable(name: "CatalogPagingBenchmark", targets: ["CatalogPagingBenchmark"]),
    ],
    targets: [
        .target(name: "StremioSkeletonCore"),
        .executableTarget(
            name: "CatalogPagingBenchmark",
            dependencies: ["StremioSkeletonCore"]
        ),
        .testTarget(
            name: "StremioSkeletonCoreTests",
            dependencies: ["StremioSkeletonCore"]
        ),
    ]
)
