// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "CodexOne",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "codexone", targets: ["CodexOne"]),
    .library(name: "CodexOneCore", targets: ["CodexOneCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.2"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
    .package(url: "https://github.com/apple/swift-nio-extras.git", exact: "1.35.1"),
    .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
    .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.13.0"),
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
    .target(name: "CodexOneCore"),
    .target(
      name: "CodexOneAdapters",
      dependencies: [
        "CodexOneCore", "CSQLite",
        .product(name: "AsyncHTTPClient", package: "async-http-client"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "Vapor", package: "vapor"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
        .product(name: "NIOWebSocket", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOExtras", package: "swift-nio-extras"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]),
    .target(
      name: "CodexOneRuntime",
      dependencies: [
        "CodexOneCore",
        .product(name: "Logging", package: "swift-log"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]),
    .executableTarget(
      name: "CodexOne",
      dependencies: [
        "CodexOneCore", "CodexOneAdapters", "CodexOneRuntime",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]),
    .executableTarget(
      name: "ExecutionProbe", dependencies: ["CodexOneCore", "CodexOneAdapters"],
      path: "Tests/Support/ExecutionProbe"),
    .testTarget(name: "CodexOneCoreTests", dependencies: ["CodexOneCore"]),
    .testTarget(
      name: "CodexOneAdaptersTests",
      dependencies: [
        "CodexOneCore", "CodexOneAdapters", "CSQLite",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOEmbedded", package: "swift-nio"),
        .product(name: "NIOHTTP1", package: "swift-nio"),
      ],
      resources: [.copy("Fixtures")]),
    .testTarget(
      name: "CodexOneRuntimeTests",
      dependencies: [
        "CodexOneRuntime", "CodexOneAdapters", "CodexOneCore",
        .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      ]),
    .testTarget(
      name: "CodexOneEndToEndTests",
      dependencies: [
        "CodexOneCore", "CodexOneAdapters", "CodexOneRuntime",
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
  ],
  swiftLanguageModes: [.v6]
)
