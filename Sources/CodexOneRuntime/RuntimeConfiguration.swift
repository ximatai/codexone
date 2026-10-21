public struct RuntimeConfiguration: Sendable, Equatable {
  public let dataPort: Int
  public let adminPort: Int

  public enum ConfigurationError: Error, Equatable {
    case invalidPort(String)
    case conflictingPorts
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
    dataPort = try port("CODEXONE_DATA_PORT", fallback: 18080)
    adminPort = try port("CODEXONE_ADMIN_PORT", fallback: 18081)
    guard dataPort == 0 || dataPort != adminPort else {
      throw ConfigurationError.conflictingPorts
    }
  }
}
