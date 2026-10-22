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
      case .invalidAdminOrigin: message = "Invalid public admin origin configuration."
      case .invalidWebDirectory: message = "Invalid admin web directory configuration."
      case .invalidAdminTokenFile: message = "Invalid admin credential configuration."
      case .invalidAccountMasterKeyFile: message = "Invalid account master key configuration."
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
        "Usage: codexone [--check-config | --migrate | --help]\nEnvironment: CODEXONE_DATA_PORT, CODEXONE_ADMIN_PORT (0 = ephemeral), CODEXONE_DATA_DIRECTORY CODEXONE_IDENTITY_CONFIG and CODEXONE_ADMIN_TOKEN_FILE and CODEXONE_WEB_DIRECTORY and CODEXONE_ACCOUNT_MASTER_KEY_FILE (optional absolute paths), CODEXONE_ADMIN_PUBLIC_ORIGIN (optional trusted browser origin). Listeners are loopback-only."
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
    let webBundle: AdminWebBundle?
    if let directory = configuration.webDirectory {
      webBundle = try await AdminWebBundle.load(path: directory)
    } else {
      webBundle = nil
    }
    let credentialProtection: AccountCredentialCipher?
    if let path = configuration.accountMasterKeyFile {
      do {
        credentialProtection = try await AccountCredentialCipher.load(
          path: path, adminCredentialPath: configuration.adminTokenFile,
          forbiddenDigest: identityConfiguration?.keySHA256)
      } catch { throw RuntimeConfiguration.ConfigurationError.invalidAccountMasterKeyFile }
    } else {
      credentialProtection = nil
    }
    if arguments == ["--check-config"] {
      if let path = configuration.adminTokenFile {
        try await KeyAdminAPI.validateCredential(
          path: path, forbiddenDigest: identityConfiguration?.keySHA256,
          publicOrigin: configuration.adminPublicOrigin)
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
        path: path, store: store, forbiddenDigest: identityConfiguration?.keySHA256,
        publicOrigin: configuration.adminPublicOrigin,
        availableModels: identityConfiguration?.models.map(\.id) ?? [])
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
    let accountAdmin: AccountAdminAPI?
    if let credentialProtection, let store {
      let application = AccountCredentials(store: store, protection: credentialProtection)
      let provider = try SubscriptionOAuthProvider(group: group)
      let authorization = try AccountAuthorizationSupervisor(
        application: application, provider: provider)
      let refreshing = try AccountRefreshSupervisor(application: application, provider: provider)
      services.append(provider)
      services.append(authorization)
      services.append(refreshing)
      accountAdmin = AccountAdminAPI(
        store: store, authorization: authorization, refreshing: refreshing)
    } else {
      accountAdmin = nil
    }
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
        }, keys: keyAdmin, webBundle: webBundle, accounts: accountAdmin
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
