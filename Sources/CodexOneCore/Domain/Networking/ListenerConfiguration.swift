import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Literal addresses only. Parsing never resolves a hostname or includes input in errors.
public struct IPAddress: Sendable, Equatable {
  fileprivate let bytes: [UInt8]

  public init?(_ literal: String) {
    guard !literal.isEmpty, literal.utf8.count <= 45,
      literal.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
          || $0 == 46 || $0 == 58
      })
    else { return nil }
    if literal.contains(".") {
      let dotted = literal.split(separator: ":", omittingEmptySubsequences: false).last!
      let octets = dotted.split(separator: ".", omittingEmptySubsequences: false)
      guard octets.count == 4,
        octets.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") && UInt8($0) != nil })
      else { return nil }
    }
    var v4 = in_addr()
    if literal.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
      bytes = withUnsafeBytes(of: v4) { Array($0) }
      return
    }
    var v6 = in6_addr()
    guard literal.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
    bytes = withUnsafeBytes(of: v6) { Array($0) }
  }
}

public struct IPNetwork: Sendable, Equatable {
  private let address: IPAddress
  private let prefix: Int

  public init?(_ cidr: String) {
    let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let address = IPAddress(String(parts[0])),
      !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
      let prefix = Int(parts[1]), (0...address.bytes.count * 8).contains(prefix)
    else { return nil }
    self.address = address
    self.prefix = prefix
  }

  public func contains(_ peer: IPAddress) -> Bool {
    guard peer.bytes.count == address.bytes.count else { return false }
    for bit in 0..<prefix {
      let mask: UInt8 = 1 << (7 - bit % 8)
      if peer.bytes[bit / 8] & mask != address.bytes[bit / 8] & mask { return false }
    }
    return true
  }

  fileprivate func isSubnet(of other: Self) -> Bool {
    prefix >= other.prefix && other.contains(address)
  }
}

public struct ListenerConfiguration: Sendable, Equatable {
  public enum ConfigurationError: Error { case invalidAddress, invalidNetworks }
  public static let privateNetworks =
    "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10,fc00::/7"
  public static let defaultNetworks = privateNetworks + ",127.0.0.0/8,::1/128"
  public static let loopback = try! Self()
  public let additionalAddress: String?
  public let allowedNetworks: [IPNetwork]

  public init(address: String? = nil, allowedNetworks: String? = nil) throws {
    if let address, !address.isEmpty {
      guard let ip = IPAddress(address),
        Self.privateNetworks.split(separator: ",").contains(where: {
          IPNetwork(String($0))!.contains(ip)
        })
      else { throw ConfigurationError.invalidAddress }
      additionalAddress = address
    } else {
      additionalAddress = nil
    }
    self.allowedNetworks = try Self.networks(allowedNetworks)
  }

  private static func networks(_ input: String?) throws -> [IPNetwork] {
    let defaults = defaultNetworks.split(separator: ",").map { IPNetwork(String($0))! }
    guard let input, !input.isEmpty else { return defaults }
    let parts = input.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count <= 64 else { throw ConfigurationError.invalidNetworks }
    return try parts.map {
      guard let network = IPNetwork(String($0)),
        defaults.contains(where: { network.isSubnet(of: $0) })
      else { throw ConfigurationError.invalidNetworks }
      return network
    }
  }

  public func allows(peer: String?) -> Bool {
    guard let peer, let address = IPAddress(peer) else { return false }
    return allowedNetworks.contains { $0.contains(address) }
  }

  /// Internal socket-test seam: unavailable to the executable's normal imports. Never accepts a
  /// public address; avoids requiring a host interface alias (::1 on macOS, 127/8 on Linux).
  init(testLoopbackAddress: String, allowedNetworks: String) throws {
    guard let ip = IPAddress(testLoopbackAddress),
      IPNetwork("127.0.0.0/8")!.contains(ip) || IPNetwork("::1/128")!.contains(ip),
      testLoopbackAddress != "127.0.0.1"
    else { throw ConfigurationError.invalidAddress }
    additionalAddress = testLoopbackAddress
    self.allowedNetworks = try Self.networks(allowedNetworks)
  }
}
