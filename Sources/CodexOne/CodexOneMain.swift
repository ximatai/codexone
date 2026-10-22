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
      case .invalidAccountPoolConfiguration: message = "Invalid account pool configuration."
      case .invalidAdminTokenFile: message = "Invalid admin credential configuration."
      case .invalidAccountMasterKeyFile: message = "Invalid account master key configuration."
      case .invalidDataDirectory: message = "Invalid data directory configuration."
      case .conflictingPorts: message = "Data and admin ports must differ."
      }
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(78)
    } catch SnapshotMaintenanceError.incompleteRestore {
      FileHandle.standardError.write(
        Data("Incomplete restore target; preserve the backup and use a new empty target.\n".utf8))
      exit(1)
    } catch SnapshotMaintenanceError.requiresManagedKeys {
      FileHandle.standardError.write(
        Data("Restored databases require managed Keys or account-pool configuration.\n".utf8))
      exit(1)
    } catch ExecutionError.storagePressure {
      FileHandle.standardError.write(
        Data("Insufficient storage headroom; free space and retry offline.\n".utf8))
      exit(1)
    } catch KeyMaintenanceError.incompleteReencryption {
      FileHandle.standardError.write(
        Data(
          "Incomplete credential reencryption; retain all keys and run --resume-reencryption offline.\n"
            .utf8))
      exit(1)
    } catch KeyMaintenanceError.wrongActiveKey {
      FileHandle.standardError.write(
        Data(
          "Reencryption requires the original target active key; retain all decrypt-only keys.\n"
            .utf8))
      exit(1)
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
        "Usage: codexone [--check-config | --migrate | --backup ABSOLUTE_NEW_BUNDLE | --restore ABSOLUTE_BUNDLE | --maintenance-status | --reconcile-restored ABSOLUTE_BASELINE_JSON | --key-status | --reencrypt-credentials ABSOLUTE_NEW_BUNDLE | --resume-reencryption | --verify-backup ABSOLUTE_BUNDLE | --check-key-retirement ABSOLUTE_INVENTORY_JSON | --help]\nEnvironment: CODEXONE_DATA_PORT, CODEXONE_ADMIN_PORT (0 = ephemeral), CODEXONE_DATA_DIRECTORY CODEXONE_IDENTITY_CONFIG and CODEXONE_ADMIN_TOKEN_FILE and CODEXONE_WEB_DIRECTORY and CODEXONE_ACCOUNT_MASTER_KEY_FILE and CODEXONE_ACCOUNT_POOL_CONFIG (optional absolute paths), CODEXONE_ADMIN_PUBLIC_ORIGIN (optional trusted browser origin). Listeners are loopback-only."
      )
      return
    }
    let maintenance =
      [["--maintenance-status"], ["--key-status"], ["--resume-reencryption"]].contains(arguments)
      || (arguments.count == 2
        && [
          "--backup", "--restore", "--reconcile-restored", "--reencrypt-credentials",
          "--verify-backup", "--check-key-retirement",
        ].contains(arguments[0])
        && arguments[1].hasPrefix("/"))
    guard
      arguments.isEmpty || arguments == ["--check-config"] || arguments == ["--migrate"]
        || maintenance
    else {
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
    if maintenance {
      guard let directory = configuration.dataDirectory else {
        throw RuntimeConfiguration.ConfigurationError.invalidDataDirectory
      }
      let path = directory + "/core.sqlite"
      let protection: AccountCredentialCipher?
      if let keyFile = configuration.accountMasterKeyFile {
        let maintenanceIdentity: SingleIdentityConfiguration?
        if let identityPath = configuration.identityConfigurationPath {
          maintenanceIdentity = try await SingleIdentityConfiguration.load(path: identityPath)
        } else {
          maintenanceIdentity = nil
        }
        protection = try await AccountCredentialCipher.load(
          path: keyFile, adminCredentialPath: configuration.adminTokenFile,
          forbiddenDigest: maintenanceIdentity?.keySHA256)
      } else {
        protection = nil
      }
      if arguments[0] == "--verify-backup" {
        let manifest = try await SQLiteSnapshotMaintenance.verifyBackup(
          bundle: arguments[1], protection: protection)
        FileHandle.standardOutput.write(try JSONEncoder().encode(manifest) + Data([10]))
        return
      }
      if [
        "--key-status", "--reencrypt-credentials", "--resume-reencryption",
        "--check-key-retirement",
      ].contains(arguments[0]) {
        guard let protection else {
          throw RuntimeConfiguration.ConfigurationError.invalidAccountMasterKeyFile
        }
        let result: Data
        if arguments[0] == "--check-key-retirement" {
          result = try await SQLiteKeyMaintenance.checkRetirement(
            path: path, protection: protection, inventoryFile: arguments[1])
        } else {
          let status: KeyMaintenanceStatus
          if arguments[0] == "--key-status" {
            status = try await SQLiteKeyMaintenance.status(path: path, protection: protection)
          } else {
            status = try await SQLiteKeyMaintenance.reencrypt(
              path: path, protection: protection,
              backupDestination: arguments[0] == "--reencrypt-credentials" ? arguments[1] : nil)
          }
          result = try JSONEncoder().encode(status)
        }
        FileHandle.standardOutput.write(result + Data([10]))
        return
      }
      if arguments[0] == "--backup" {
        let manifest = try await SQLiteSnapshotMaintenance.backup(
          path: path, destination: arguments[1], protection: protection)
        FileHandle.standardOutput.write(try JSONEncoder().encode(manifest) + Data([10]))
      } else {
        let record: RestoreRecord?
        switch arguments[0] {
        case "--restore":
          record = try await SQLiteSnapshotMaintenance.restore(
            bundle: arguments[1], path: path, protection: protection)
        case "--reconcile-restored":
          record = try await SQLiteSnapshotMaintenance.reconcileFile(
            path: path, baselineFile: arguments[1])
        default: record = try await SQLiteSnapshotMaintenance.status(path: path)
        }
        let state =
          record == nil
          ? "normal"
          : record!.baseline == nil
            ? "restored_unreconciled"
            : record!.allowsAdmission(at: Int64(Date().timeIntervalSince1970))
              ? "reconciled" : "frozen"
        let encoded = try record.map {
          try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
        }
        let report: [String: Any] = [
          "state": state, "restore": encoded ?? NSNull(),
          "minimumFreezeUntilUnixSeconds": record?.minimumReconciliationFreeze(
            at: Int64(Date().timeIntervalSince1970)) as Any?
            ?? NSNull(),
          "missingUnresolvedRequests": record?.unresolvedRequests ?? 0,
          "missingUnresolvedMicros": record?.unresolvedMicros ?? 0,
        ]
        FileHandle.standardOutput.write(
          try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) + Data([10]))
      }
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
    let poolConfiguration: AccountPoolConfiguration?
    if let path = configuration.accountPoolConfigurationPath {
      poolConfiguration = try await AccountPoolConfiguration.load(path: path)
    } else {
      poolConfiguration = nil
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
    if let store, store.hasRestoredSnapshot, let identityConfiguration,
      identityConfiguration.managedKeys != true
    {
      await store.close()
      throw SnapshotMaintenanceError.requiresManagedKeys
    }
    let usageReader: SQLiteUsageReader?
    if configuration.adminTokenFile != nil, let store {
      usageReader = try await store.makeUsageReader()
    } else {
      usageReader = nil
    }
    let keyAdmin: KeyAdminAPI?
    if let path = configuration.adminTokenFile, let store {
      keyAdmin = try await KeyAdminAPI.load(
        path: path, store: store, forbiddenDigest: identityConfiguration?.keySHA256,
        publicOrigin: configuration.adminPublicOrigin,
        availableModels: poolConfiguration?.models.map(\.id) ?? identityConfiguration?.models.map(
          \.id) ?? [],
        imageModels: poolConfiguration?.imageGeneration?.models.map(\.id) ?? identityConfiguration?
          .imageGeneration?.models.map(\.id) ?? [],
        usage: usageReader.map { UsageAdminAPI(querying: $0) }, storageMonitoring: store)
    } else {
      keyAdmin = nil
    }
    let finalizer = try store.map { try ExecutionFinalizer(store: $0) }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let report = ReadinessReport(checks: [
      .init(name: "execution_store", ready: store != nil),
      .init(
        name: "upstream_accounts", ready: (identityConfiguration != nil || poolConfiguration != nil)
      ),
      .init(
        name: "authorization", ready: (identityConfiguration != nil || poolConfiguration != nil)),
    ])
    var services: [any Service] = []
    if let store { services.append(StorageMonitor(storage: store)) }
    let accountAdmin: AccountAdminAPI?
    var poolDataService: ResponsesDataService?
    if let credentialProtection, let store {
      let application = AccountCredentials(store: store, protection: credentialProtection)
      let provider = try SubscriptionOAuthProvider(group: group)
      let authorization = try AccountAuthorizationSupervisor(
        application: application, provider: provider)
      let refreshing = try AccountRefreshSupervisor(application: application, provider: provider)
      let quota = try SubscriptionQuotaProvider(group: group, verifier: provider)
      let observing = try AccountObservationSupervisor(
        store: store, application: application, refresher: refreshing, provider: quota)
      services.append(provider)
      services.append(quota)
      services.append(authorization)
      services.append(refreshing)
      services.append(observing)
      if let poolConfiguration, let finalizer {
        poolDataService = try ResponsesDataService(
          group: group, port: configuration.dataPort,
          configuration: poolConfiguration, store: store, finalizer: finalizer,
          credentials: application, refresher: refreshing, provider: provider
        ) { announce("data", port: $0) }
      }
      accountAdmin = AccountAdminAPI(
        store: store, authorization: authorization, refreshing: refreshing, observing: observing)
    } else {
      accountAdmin = nil
    }
    if let poolDataService {
      services.append(poolDataService)
    } else if let identityConfiguration, let store, let finalizer {
      services.append(
        try ResponsesDataService(
          group: group, port: configuration.dataPort,
          configuration: identityConfiguration, store: store, finalizer: finalizer
        ) { announce("data", port: $0) })
    } else {
      services.append(
        DataPlaneService(group: group, port: configuration.dataPort, report: report) {
          announce("data", port: $0)
        })
    }
    let activePoolDataService = poolDataService
    services.append(
      AdminService(
        group: group, port: configuration.adminPort,
        reportProvider: {
          if let activePoolDataService { return await activePoolDataService.readiness() }
          return .init(checks: [
            .init(name: "execution_store", ready: store?.isAdmissionReady == true),
            .init(
              name: "upstream_accounts",
              ready: (identityConfiguration != nil || poolConfiguration != nil)),
            .init(
              name: "authorization",
              ready: (identityConfiguration != nil || poolConfiguration != nil)
                && finalizer?.isAccepting == true),
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
      await usageReader?.close()
      await store?.close()
      try await group.shutdownGracefully()
      throw error
    }
    await usageReader?.close()
    await store?.close()
    try await group.shutdownGracefully()
  }

  private static func announce(_ listener: String, port: Int) {
    FileHandle.standardOutput.write(Data("LISTENING \(listener) 127.0.0.1:\(port)\n".utf8))
  }

  private enum CommandError: Error { case unsupportedArguments }
}
