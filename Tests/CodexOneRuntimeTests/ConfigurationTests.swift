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

@Test func accountMasterConfigurationRequiresPersistentStorageAndAdministrator() throws {
  var environment = ["CODEXONE_ACCOUNT_MASTER_KEY_FILE": "/synthetic/master"]
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAccountMasterKeyFile) {
    try RuntimeConfiguration(environment: environment)
  }
  environment["CODEXONE_DATA_DIRECTORY"] = "/synthetic/data"
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAccountMasterKeyFile) {
    try RuntimeConfiguration(environment: environment)
  }
  environment["CODEXONE_ADMIN_TOKEN_FILE"] = "/synthetic/admin"
  #expect(
    try RuntimeConfiguration(environment: environment).accountMasterKeyFile == "/synthetic/master")
}

@Test func poolConfigurationRequiresPrivateAssemblyAndExcludesSingleIdentity() throws {
  let valid = [
    "CODEXONE_DATA_DIRECTORY": "/synthetic/data", "CODEXONE_ADMIN_TOKEN_FILE": "/synthetic/admin",
    "CODEXONE_ACCOUNT_MASTER_KEY_FILE": "/synthetic/master",
    "CODEXONE_ACCOUNT_POOL_CONFIG": "/synthetic/pool",
  ]
  #expect(
    try RuntimeConfiguration(environment: valid).accountPoolConfigurationPath == "/synthetic/pool")
  for field in [
    "CODEXONE_DATA_DIRECTORY", "CODEXONE_ADMIN_TOKEN_FILE", "CODEXONE_ACCOUNT_MASTER_KEY_FILE",
  ] {
    var missing = valid
    missing.removeValue(forKey: field)
    #expect(throws: (any Error).self) { try RuntimeConfiguration(environment: missing) }
  }
  var conflicting = valid
  conflicting["CODEXONE_IDENTITY_CONFIG"] = "/synthetic/identity"
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAccountPoolConfiguration) {
    try RuntimeConfiguration(environment: conflicting)
  }
  var relative = valid
  relative["CODEXONE_ACCOUNT_POOL_CONFIG"] = "relative"
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidAccountPoolConfiguration) {
    try RuntimeConfiguration(environment: relative)
  }
}

@Test func backupConfigurationIsOptionalAndRequiresAbsolutePathAndCoreStorage() throws {
  #expect(try RuntimeConfiguration(environment: [:]).backupDirectory == nil)
  for path in ["relative", "", "/synthetic/\0invalid"] {
    #expect(throws: RuntimeConfiguration.ConfigurationError.invalidBackupDirectory) {
      try RuntimeConfiguration(environment: [
        "CODEXONE_DATA_DIRECTORY": "/synthetic/data", "CODEXONE_BACKUP_DIRECTORY": path,
      ])
    }
  }
  #expect(throws: RuntimeConfiguration.ConfigurationError.invalidBackupDirectory) {
    try RuntimeConfiguration(environment: ["CODEXONE_BACKUP_DIRECTORY": "/synthetic/backups"])
  }
  #expect(
    try RuntimeConfiguration(environment: [
      "CODEXONE_DATA_DIRECTORY": "/synthetic/data",
      "CODEXONE_BACKUP_DIRECTORY": "/synthetic/backups",
    ]).backupDirectory == "/synthetic/backups")
}
