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
        .executableTarget(
            name: "Tokiwatari",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "TokiwatariTests",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
