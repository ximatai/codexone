public struct RuntimeConfiguration: Sendable, Equatable {
  public let dataPort: Int
  public let adminPort: Int
  public let dataDirectory: String?
  public let identityConfigurationPath: String?
  public let accountPoolConfigurationPath: String?
  public let adminTokenFile: String?
  public let accountMasterKeyFile: String?
  public let adminPublicOrigin: String?
  public let webDirectory: String?
  public let upstreamHTTPProxy: String?

  public enum ConfigurationError: Error, Equatable {
    case invalidPort(String)
    case conflictingPorts
    case invalidDataDirectory
    case invalidIdentityConfiguration
    case invalidAccountPoolConfiguration
    case invalidAdminTokenFile
    case invalidAccountMasterKeyFile
    case invalidAdminOrigin
    case invalidWebDirectory
  }

  public init(environment: [String: String]) throws {
    func port(_ key: String, fallback: Int) throws -> Int {
      guard let value = environment[key] else { return fallback }
      guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
        let port = Int(value), (0...65535).contains(port)
      else {
        // Never include raw configuration values in errors.
        throw ConfigurationError.invalidPort(key)
      }
      return port
    }
    if let path = environment["CODEXONE_DATA_DIRECTORY"] {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
        throw ConfigurationError.invalidDataDirectory
      }
      dataDirectory = path
    } else {
      dataDirectory = nil
    }
    if let path = environment["CODEXONE_IDENTITY_CONFIG"] {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
        dataDirectory != nil
      else { throw ConfigurationError.invalidIdentityConfiguration }
      identityConfigurationPath = path
    } else {
      identityConfigurationPath = nil
    }
    if let path = environment["CODEXONE_ADMIN_TOKEN_FILE"] {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
        dataDirectory != nil
      else {
        throw ConfigurationError.invalidAdminTokenFile
      }
      adminTokenFile = path
    } else {
      adminTokenFile = nil
    }
    if let path = environment["CODEXONE_ACCOUNT_MASTER_KEY_FILE"] {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
        dataDirectory != nil, adminTokenFile != nil
      else { throw ConfigurationError.invalidAccountMasterKeyFile }
      accountMasterKeyFile = path
    } else {
      accountMasterKeyFile = nil
    }
    if let path = environment["CODEXONE_ACCOUNT_POOL_CONFIG"] {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096,
        dataDirectory != nil, adminTokenFile != nil, accountMasterKeyFile != nil,
        identityConfigurationPath == nil
      else { throw ConfigurationError.invalidAccountPoolConfiguration }
      accountPoolConfigurationPath = path
    } else {
      accountPoolConfigurationPath = nil
    }
    if let origin = environment["CODEXONE_ADMIN_PUBLIC_ORIGIN"] {
      guard !origin.isEmpty, origin.utf8.count <= 2048, !origin.utf8.contains(0),
        adminTokenFile != nil
      else { throw ConfigurationError.invalidAdminOrigin }
      adminPublicOrigin = origin
    } else {
      adminPublicOrigin = nil
    }
    if let path = environment["CODEXONE_WEB_DIRECTORY"] {
      guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 4096 else {
        throw ConfigurationError.invalidWebDirectory
      }
      webDirectory = path
    } else {
      webDirectory = nil
    }
    upstreamHTTPProxy = environment["CODEXONE_UPSTREAM_HTTP_PROXY"].flatMap {
      $0.isEmpty ? nil : $0
    }
    dataPort = try port("CODEXONE_DATA_PORT", fallback: 18080)
    adminPort = try port("CODEXONE_ADMIN_PORT", fallback: 18081)
    guard dataPort == 0 || dataPort != adminPort else {
      throw ConfigurationError.conflictingPorts
    }
  }
}
