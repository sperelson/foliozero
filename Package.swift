// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FolioZero",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "foliozero", targets: ["foliozero"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/multipart-kit.git", from: "4.7.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        // Unreleased revision: the 0.9.20 manifest causes a deprecation warning (fixed upstream
        // in 676ffa3). Go back to `from: "0.9.21"` once that release exists.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", revision: "e7a17d57c583067eaa6659cd6d9521265b7664e9"),
    ],
    targets: [
        // Jinja-subset template engine: filename formats, storage paths, workflow titles.
        .target(name: "FolioTemplating"),

        // Document parsers: type detection, text extraction, OCR, archive PDFs,
        // thumbnails, barcodes, PDF page operations. No database knowledge.
        .target(
            name: "FolioParsing",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // Domain: config, database, models, storage, matching, search, consumer,
        // workflows, tasks, scheduler.
        .target(
            name: "FolioCore",
            dependencies: [
                "FolioTemplating",
                "FolioParsing",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),

        // HTTP server and Paperless-ngx compatible REST API.
        .target(
            name: "FolioServer",
            dependencies: [
                "FolioCore",
                "FolioParsing",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "MultipartKit", package: "multipart-kit"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),

        .executableTarget(
            name: "foliozero",
            dependencies: [
                "FolioCore",
                "FolioServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        .testTarget(name: "FolioTemplatingTests", dependencies: ["FolioTemplating"]),
        .testTarget(name: "FolioParsingTests", dependencies: ["FolioParsing"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FolioCoreTests", dependencies: ["FolioCore"]),
        .testTarget(
            name: "FolioServerTests",
            dependencies: [
                "FolioServer",
                "FolioCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "HummingbirdTesting", package: "hummingbird"),
                .product(name: "HummingbirdWSTesting", package: "hummingbird-websocket"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
    ]
)
