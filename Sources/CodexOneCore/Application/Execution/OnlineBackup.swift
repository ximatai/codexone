/// Process-local backup health; successful history is recovered from retained manifests at startup.
public struct BackupObservation: Encodable, Sendable {
  public var enabled = false
  public var enabledUnixSeconds: Int64 = 0
  public var lastSuccessUnixSeconds: Int64?
  public var lastFailureUnixSeconds: Int64?
  public var lastFailure: BackupFailure?
  public var lastSkippedUnixSeconds: Int64?
  public var skippedPressure: StoragePressure?
  public var retainedCount = 0
  public var totalBytes: Int64 = 0
  public var largestBundleBytes: Int64 = 0
  public init() {}
}

public enum BackupFailure: String, Encodable, Sendable {
  case directoryUnavailable = "directory_unavailable"
  case insufficientSpace = "insufficient_space"
  case snapshotFailed = "snapshot_failed"
  case verificationFailed = "verification_failed"
  case retentionFailed = "retention_failed"
  case cancelled
}

public protocol BackupMaintaining: Sendable {
  var backupObservation: BackupObservation { get }
  /// Single-flight and best effort: a failed backup must never fail the core service.
  func performBackup() async
  func cancelBackup()
}
