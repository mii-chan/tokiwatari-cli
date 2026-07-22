// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tokiwatari-cli",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(name: "tokiwatari", targets: ["Tokiwatari"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "TokiwatariCore",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .executableTarget(
            name: "Tokiwatari",
            dependencies: ["TokiwatariCore"]
        ),
        .testTarget(
            name: "TokiwatariTests",
            dependencies: [
                "TokiwatariCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
