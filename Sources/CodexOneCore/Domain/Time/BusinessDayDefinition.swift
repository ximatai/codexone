import Foundation

/// Fixed whole-hour calendar boundary; independent of host and browser time zones.
public struct BusinessDayDefinition: Sendable, Equatable {
  public let offsetMinutes: Int
  public static let utc = try! Self(offsetMinutes: 0)
  public var offsetSeconds: Int64 { Int64(offsetMinutes) * 60 }
  public var timezone: String {
    offsetMinutes == 0
      ? "UTC"
      : String(format: "UTC%@%02d:00", offsetMinutes < 0 ? "-" : "+", abs(offsetMinutes) / 60)
  }
  public init(offsetMinutes: Int) throws {
    guard (-720...840).contains(offsetMinutes), offsetMinutes % 60 == 0 else {
      throw ExecutionError.invalidCommand
    }
    self.offsetMinutes = offsetMinutes
  }
  public init(setting: String) throws {
    if setting == "UTC" {
      self = .utc
      return
    }
    let bytes = Array(setting.utf8)
    guard bytes.count == 6, [43, 45].contains(bytes[0]), bytes[3...] == [58, 48, 48],
      (48...57).contains(bytes[1]), (48...57).contains(bytes[2])
    else { throw ExecutionError.invalidCommand }
    try self.init(
      offsetMinutes: (Int(bytes[1] - 48) * 10 + Int(bytes[2] - 48)) * 60 * (bytes[0] == 45 ? -1 : 1)
    )
  }
  public func start(containing epoch: Int64) throws -> Int64 {
    let (shifted, overflow) = epoch.addingReportingOverflow(offsetSeconds)
    guard !overflow else { throw ExecutionError.invalidCommand }
    let quotient = shifted / 86400 - (shifted % 86400 < 0 ? 1 : 0)
    let (day, multiplyOverflow) = quotient.multipliedReportingOverflow(by: 86400)
    let (start, subtractOverflow) = day.subtractingReportingOverflow(offsetSeconds)
    guard !multiplyOverflow, !subtractOverflow else { throw ExecutionError.invalidCommand }
    return start
  }
  public func end(containing epoch: Int64) throws -> Int64 {
    let (end, overflow) = try start(containing: epoch).addingReportingOverflow(86400)
    guard !overflow else { throw ExecutionError.invalidCommand }
    return end
  }
  public func isBoundary(_ epoch: Int64) throws -> Bool { try start(containing: epoch) == epoch }
  public func window(containing epoch: Int64) throws -> String {
    "business-day-\(try start(containing: epoch))"
  }
}
