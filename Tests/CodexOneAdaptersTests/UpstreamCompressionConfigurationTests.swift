import Foundation
import Testing

@testable import CodexOneAdapters

@Test func compressionConfigurationIsTrustedAndValidatedForBothSources() throws {
  let base: [String: Any] = [
    "models": [["id": "synthetic", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0]],
    "reservedMicros": 1,
  ]
  for (mode, threshold, valid) in [
    ("zstd", 0, true), ("off", 8_388_608, true), ("gzip", 0, false), ("zstd", -1, false),
  ] {
    var pool = base
    pool["upstreamRequestCompression"] = mode
    pool["upstreamZstdMinimumBytes"] = threshold
    let data = try JSONSerialization.data(withJSONObject: pool)
    if valid {
      let config = try JSONDecoder().decode(AccountPoolConfiguration.self, from: data)
      #expect(config.responses.upstreamRequestCompression == mode)
      #expect(config.responses.upstreamZstdMinimumBytes == threshold)
    } else {
      #expect(throws: (any Error).self) {
        try JSONDecoder().decode(AccountPoolConfiguration.self, from: data)
      }
    }
    var single = pool
    single["namespace"] = "synthetic"
    single["identity"] = "synthetic"
    single["managedKeys"] = true
    single["upstreamBaseURL"] = "http://127.0.0.1:12345/v1"
    let config = try JSONDecoder().decode(
      SingleIdentityConfiguration.self, from: JSONSerialization.data(withJSONObject: single))
    if valid {
      try config.validate()
      #expect(config.responses.upstreamRequestCompression == mode)
      #expect(config.responses.upstreamZstdMinimumBytes == threshold)
    } else {
      #expect(throws: (any Error).self) { try config.validate() }
    }
  }
}
