// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CypherTextKit",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v14),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CypherMessaging",
            targets: ["CypherMessaging"]),
        .library(
            name: "MessagingHelpers",
            targets: ["MessagingHelpers"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "4.0.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.0.0"),
//        .package(name: "swift-nio", path: "/Users/joannisorlandos/Project/swift-nio/"),
//        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),
        .package(url: "https://github.com/OpenKitten/BSON.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CypherMessaging",
            dependencies: [
                .target(name: "CypherProtocol"),
                .product(name: "Logging", package: "swift-log"),
            ], swiftSettings: [
                .unsafeFlags([
                    "-cross-module-optimization"
                ], .when(configuration: .release)),
                .unsafeFlags([
                    "-Xfrontend", "-enable-experimental-concurrency",
                    "-Xfrontend", "-disable-availability-checking",
                ])
            ]),
        .target(
            name: "MessagingHelpers",
            dependencies: [
                .target(name: "CypherMessaging"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ], swiftSettings: [
                .unsafeFlags([
                    "-cross-module-optimization"
                ], .when(configuration: .release)),
                .unsafeFlags([
                    "-Xfrontend", "-enable-experimental-concurrency",
                    "-Xfrontend", "-disable-availability-checking",
                ])
            ]),
        .target(
            name: "CypherProtocol",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "_NIOConcurrency", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
//                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "BSON", package: "BSON"),
            ]),
        .testTarget(
            name: "CypherMessagingTests",
            dependencies: ["CypherMessaging"]),
        .testTarget(
            name: "CypherMessagingHelpersTests",
            dependencies: ["MessagingHelpers"]),
    ]
)
