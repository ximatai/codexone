import CodexOneCore
import CodexOneRuntime
import Testing

@Test func businessDayConfigurationRejectsUnsupportedSettings() throws {
  #expect(try RuntimeConfiguration(environment: [:]).businessDay == .utc)
  for value in [
    "", " UTC", "utc", "+8:00", "+05:30", "+05:45", "+14:01", "-13:00", "+15:00", "Asia/Shanghai",
    "+08:00\n",
  ] {
    #expect(throws: RuntimeConfiguration.ConfigurationError.invalidBusinessDayOffset) {
      try RuntimeConfiguration(environment: ["CODEXONE_BUSINESS_DAY_OFFSET": value])
    }
  }
  for value in ["-12:00", "+14:00", "+08:00", "+00:00", "-00:00"] {
    _ = try RuntimeConfiguration(environment: ["CODEXONE_BUSINESS_DAY_OFFSET": value])
  }
}
