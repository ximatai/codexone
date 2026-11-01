import CodexOneCore
import CodexOneRuntime
import Testing

@Test(arguments: [
  "10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254", "192.168.1.10",
  "100.64.0.1", "100.127.255.254", "fc00::1", "fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
])
func privateLANListenAddressesAreAccepted(_ address: String) throws {
  #expect(
    try RuntimeConfiguration(environment: ["CODEXONE_LISTEN_ADDRESS": address])
      .listeners.additionalAddress == address)
}

@Test(arguments: [
  "8.8.8.8", "192.0.2.1", "0.0.0.0", "::", "::1", "127.0.0.2", "localhost",
  "gateway.example", "169.254.1.10", "172.15.0.1", "172.32.0.1", "100.63.255.255",
  "100.128.0.1", "2001:db8::1", "fe80::1", "fd00::1%en0", "::ffff:192.168.1.10",
  "192.168.1.10/24", "192.168.01.10", " 10.0.0.1", "10.0.0.1\0ignored", "not-an-address",
])
func invalidLANListenAddressesHaveValueFreeErrors(_ address: String) {
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidListenAddress) {
    try RuntimeConfiguration(environment: ["CODEXONE_LISTEN_ADDRESS": address])
  }
}

@Test(arguments: [
  "not-a-network", "192.168.1.0", "192.168.1.0/-1", "192.168.1.0/33", "fd00::/129",
  "192.168.1.0/24,", ",192.168.1.0/24", "localhost/24", "0.0.0.0/0", "::/0",
  "192.168.1.0/24/1", "192.168.1.0/２４", "192.168.1.0/ 24", "fd00::%en0/64",
])
func malformedOrWidenedSourceNetworksHaveValueFreeErrors(_ networks: String) {
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAllowedNetworks) {
    try RuntimeConfiguration(environment: ["CODEXONE_ALLOWED_NETWORKS": networks])
  }
}

@Test func networkMatchingAndDefaultsIncludePrivateRangesAndLoopback() throws {
  let defaults = try ListenerConfiguration(address: "192.168.1.10")
  for address in [
    "10.0.0.1", "172.31.255.254", "192.168.1.10", "100.64.0.1", "fd00::1", "127.0.0.1", "::1",
  ] {
    #expect(defaults.allows(peer: address))
  }
  for address in ["8.8.8.8", "100.128.0.1", "fe80::1", "::ffff:10.0.0.1"] {
    #expect(!defaults.allows(peer: address))
  }
  #expect(!defaults.allows(peer: nil))
  let narrowed = try ListenerConfiguration(allowedNetworks: "192.168.1.0/24,fd00::/64")
  #expect(narrowed.allows(peer: "192.168.1.254"))
  #expect(!narrowed.allows(peer: "192.168.2.1"))
  #expect(narrowed.allows(peer: "fd00::ffff"))
  #expect(!narrowed.allows(peer: "fd00:0:0:1::1"))
}

@Test func nonLoopbackHTTPOriginMustMatchConfiguredListenLiteral() throws {
  var environment = [
    "CODEXONE_DATA_DIRECTORY": "/synthetic/data", "CODEXONE_ADMIN_TOKEN_FILE": "/synthetic/admin",
    "CODEXONE_ADMIN_PUBLIC_ORIGIN": "http://192.168.1.10:18081",
  ]
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAdminOrigin) {
    try RuntimeConfiguration(environment: environment)
  }
  environment["CODEXONE_LISTEN_ADDRESS"] = "192.168.1.11"
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAdminOrigin) {
    try RuntimeConfiguration(environment: environment)
  }
  environment["CODEXONE_LISTEN_ADDRESS"] = "192.168.1.10"
  _ = try RuntimeConfiguration(environment: environment)
  environment["CODEXONE_LISTEN_ADDRESS"] = "fd00::10"
  environment["CODEXONE_ADMIN_PUBLIC_ORIGIN"] = "http://[fd00:0:0:0::10]:18081"
  _ = try RuntimeConfiguration(environment: environment)
  environment["CODEXONE_ADMIN_PUBLIC_ORIGIN"] = "http://admin.example:18081"
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAdminOrigin) {
    try RuntimeConfiguration(environment: environment)
  }
}
