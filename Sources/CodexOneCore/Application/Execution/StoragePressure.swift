import Foundation

public enum StoragePressure: String, Codable, Sendable { case normal, degraded, blocked, unknown }

public struct StorageSpacePolicy: Sendable {
  public let reserveBytes: Int64
  public let stopBytes: Int64
  public let resumeBytes: Int64
  public let optionalBytes: Int64
  public let walSoftBytes: Int64
  public let walStopBytes: Int64
  public static let standard = try! Self()
  public init(
    reserveBytes: Int64 = 64 * 1024 * 1024, stopBytes: Int64 = 128 * 1024 * 1024,
    resumeBytes: Int64 = 192 * 1024 * 1024, optionalBytes: Int64 = 256 * 1024 * 1024,
    walSoftBytes: Int64 = 64 * 1024 * 1024, walStopBytes: Int64 = 128 * 1024 * 1024
  ) throws {
    guard reserveBytes >= 1_048_576, reserveBytes <= 1_073_741_824,
      stopBytes >= reserveBytes, resumeBytes > stopBytes, optionalBytes > resumeBytes,
      optionalBytes <= 1_099_511_627_776, walSoftBytes >= 1_048_576, walStopBytes > walSoftBytes,
      walStopBytes <= 1_073_741_824
    else { throw ExecutionError.invalidCommand }
    self.reserveBytes = reserveBytes
    self.stopBytes = stopBytes
    self.resumeBytes = resumeBytes
    self.optionalBytes = optionalBytes
    self.walSoftBytes = walSoftBytes
    self.walStopBytes = walStopBytes
  }
  public func pressure(
    availableBytes: Int64?, reserveBytes: Int64, walBytes: Int64, previous: StoragePressure
  ) -> StoragePressure {
    guard let availableBytes else { return .unknown }
    if reserveBytes < self.reserveBytes || availableBytes < stopBytes || walBytes >= walStopBytes {
      return .blocked
    }
    if previous == .blocked || previous == .unknown {
      if availableBytes < resumeBytes || walBytes > walSoftBytes / 2 { return .blocked }
    }
    return availableBytes < optionalBytes || walBytes >= walSoftBytes ? .degraded : .normal
  }
}

/// Fixed low-cardinality counters only. No paths, accounts or request identifiers.
public struct StorageObservation: Encodable, Sendable {
  public var coreAvailable = true
  public var sampledUnixSeconds: Int64 = 0
  public var pressure: StoragePressure = .unknown
  public var availableBytes: Int64?
  public var databaseBytes: Int64 = 0
  public var walBytes: Int64 = 0
  public var reserveBytes: Int64 = 0
  public var reserveTargetBytes: Int64 = 0
  public var checkpointLogFrames: Int32 = 0
  public var checkpointedFrames: Int32 = 0
  public var checkpointBusy = false
  public var regularQueued = 0
  public var criticalQueued = 0
  public var recentQueueWaitMicros: UInt64 = 0
  public var maximumQueueWaitMicros: UInt64 = 0
  public var usageReaderActive = false
  public var peakResidentBytes: Int64 = 0
  public var observedFDs = 0
  public let fdScanLimit = 1024
  public var admissionAllowed: Bool {
    coreAvailable && (pressure == .normal || pressure == .degraded)
  }
  public var optionalWorkAllowed: Bool { coreAvailable && pressure == .normal }
  public init() {}
}
public protocol StorageMonitoring: Sendable {
  var storageObservation: StorageObservation { get }
  func maintainStorage() async throws
}
