import CodexOneRuntime
import Testing

@Test func loopbackListenerConfigurationValidatesPorts() throws {
  let defaults = try RuntimeConfiguration(environment: [:])
  #expect(defaults.dataPort == 18080)
  #expect(defaults.adminPort == 18081)
  #expect(
    try RuntimeConfiguration(environment: ["CODEXONE_DATA_PORT": "0", "CODEXONE_ADMIN_PORT": "0"])
      .dataPort == 0)
  #expect(throws: RuntimeConfiguration.ConfigurationError.conflictingPorts) {
    try RuntimeConfiguration(environment: [
      "CODEXONE_DATA_PORT": "19000", "CODEXONE_ADMIN_PORT": "19000",
    ])
  }
}

@Test(arguments: ["", "-1", "65536", "1.5", "secret-port-value", "１２３", " 123"])
func invalidConfigurationIsRejectedWithoutEchoingRawValue(_ value: String) {
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidPort("CODEXONE_DATA_PORT")) {
    try RuntimeConfiguration(environment: ["CODEXONE_DATA_PORT": value])
  }
}

@Test func dataDirectoryValidationNeverEchoesRawPaths() throws {
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidDataDirectory) {
    try RuntimeConfiguration(environment: ["CODEXONE_DATA_DIRECTORY": "relative-private-value"])
  }
  #expect(
    try RuntimeConfiguration(environment: ["CODEXONE_DATA_DIRECTORY": "/synthetic/data"])
      .dataDirectory == "/synthetic/data")
}
