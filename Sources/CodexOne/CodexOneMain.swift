import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOPosix
import ServiceLifecycle

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@main
struct CodexOneMain {
  static func main() async {
    do {
      try await run()
    } catch let error as RuntimeConfiguration.ConfigurationError {
      let message: String
      switch error {
      case .invalidPort(let key): message = "Invalid port configuration: \(key)."
      case .invalidIdentityConfiguration: message = "Invalid single-identity configuration."
      case .invalidAdminTokenFile: message = "Invalid admin credential configuration."
      case .invalidDataDirectory: message = "Invalid data directory configuration."
      case .conflictingPorts: message = "Data and admin ports must differ."
      }
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(78)
    } catch is CommandError {
      FileHandle.standardError.write(Data("Unsupported arguments. Use --help.\n".utf8))
      exit(64)
    } catch {
      FileHandle.standardError.write(Data("Service startup or shutdown failed.\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
      print(
        "Usage: codexone [--check-config | --migrate | --help]\nEnvironment: CODEXONE_DATA_PORT, CODEXONE_ADMIN_PORT (0 = ephemeral), CODEXONE_DATA_DIRECTORY CODEXONE_IDENTITY_CONFIG and CODEXONE_ADMIN_TOKEN_FILE (optional absolute paths). Listeners are loopback-only."
      )
      return
    }
    guard arguments.isEmpty || arguments == ["--check-config"] || arguments == ["--migrate"] else {
      throw CommandError.unsupportedArguments
    }
    let configuration = try RuntimeConfiguration(environment: ProcessInfo.processInfo.environment)
    if arguments == ["--migrate"] {
      guard let directory = configuration.dataDirectory else {
        throw RuntimeConfiguration.ConfigurationError.invalidDataDirectory
      }
      try await SQLiteExecutionStore.migrate(path: directory + "/core.sqlite")
      print("Schema migration completed; any pre-upgrade backup is beside the database.")
      return
    }
    let identityConfiguration: SingleIdentityConfiguration?
    if let path = configuration.identityConfigurationPath {
      identityConfiguration = try await SingleIdentityConfiguration.load(path: path)
    } else {
      identityConfiguration = nil
    }
    if identityConfiguration?.managedKeys == true, configuration.adminTokenFile == nil {
      throw RuntimeConfiguration.ConfigurationError.invalidAdminTokenFile
    }
    if arguments == ["--check-config"] {
      if let path = configuration.adminTokenFile {
        try await KeyAdminAPI.validateCredential(
          path: path, forbiddenDigest: identityConfiguration?.keySHA256)
      }
      let data = try JSONSerialization.data(
        withJSONObject: [
          "host": "127.0.0.1", "dataPort": configuration.dataPort,
          "adminPort": configuration.adminPort,
        ], options: [.sortedKeys])
      FileHandle.standardOutput.write(data + Data([10]))
      return
    }
    let store: SQLiteExecutionStore?
    if let directory = configuration.dataDirectory {
      try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      store = try await SQLiteExecutionStore.open(
        path: directory + "/core.sqlite",
        limits: .init(
          requests: 10_000, active: 16, unresolved: 32, budgetMicros: 1_000_000_000))
    } else {
      store = nil
    }
    let keyAdmin: KeyAdminAPI?
    if let path = configuration.adminTokenFile, let store {
      keyAdmin = try await KeyAdminAPI.load(
        path: path, store: store, forbiddenDigest: identityConfiguration?.keySHA256)
    } else {
      keyAdmin = nil
    }
    let finalizer = try store.map { try ExecutionFinalizer(store: $0) }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let report = ReadinessReport(checks: [
      .init(name: "execution_store", ready: store != nil),
      .init(name: "upstream_accounts", ready: identityConfiguration != nil),
      .init(name: "authorization", ready: identityConfiguration != nil),
    ])
    var services: [any Service] = []
    if let identityConfiguration, let store, let finalizer {
      services.append(
        try SingleIdentityDataService(
          group: group, port: configuration.dataPort,
          configuration: identityConfiguration, store: store, finalizer: finalizer
        ) { announce("data", port: $0) })
    } else {
      services.append(
        DataPlaneService(group: group, port: configuration.dataPort, report: report) {
          announce("data", port: $0)
        })
    }
    services.append(
      AdminService(
        group: group, port: configuration.adminPort,
        reportProvider: {
          .init(checks: [
            .init(name: "execution_store", ready: store?.isAvailable == true),
            .init(name: "upstream_accounts", ready: identityConfiguration != nil),
            .init(
              name: "authorization",
              ready: identityConfiguration != nil && finalizer?.isAccepting == true),
          ])
        }, keys: keyAdmin
      ) {
        announce("admin", port: $0)
      })
    if let finalizer { services.insert(finalizer, at: 0) }
    let runtime = GatewayRuntime(services: services)
    do {
      try await runtime.run()
    } catch {
      await store?.close()
      try await group.shutdownGracefully()
      throw error
    }
    await store?.close()
    try await group.shutdownGracefully()
  }

  private static func announce(_ listener: String, port: Int) {
    FileHandle.standardOutput.write(Data("LISTENING \(listener) 127.0.0.1:\(port)\n".utf8))
  }

  private enum CommandError: Error { case unsupportedArguments }
}
