import CodexOneCore
import Testing

@Test func wallClockPreservesTimestampUnitsAndTruncation() {
  let fractional = WallClock { 86_400.125 }
  #expect(fractional.unixSeconds == 86_400)
  #expect(fractional.unixMicroseconds == 86_400_125_000)
  #expect(fractional.utcDay == 1)
  let beforeEpoch = WallClock { -0.125 }
  #expect(beforeEpoch.unixSeconds == 0)
  #expect(beforeEpoch.unixMicroseconds == -125_000)
  #expect(beforeEpoch.utcDay == 0)
}
