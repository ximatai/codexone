import CodexOneCore
import Foundation

extension SQLiteExecutionStore {
  /// Called only after COMMIT, on the existing writer queue. No SQL or throwing operation.
  func publishOverview(_ admission: ExecutionAdmission, at: Int64, outcome: String? = nil) {
    overviewActivity.publish {
      .init(
        id: admission.attempt,
        row: .object([
          "id": .string(admission.attempt), "keyID": .string(admission.owner.key),
          "principal": .string(admission.owner.principal), "displayName": .null,
          "accountID": .string(admission.owner.identity), "accountDisplayName": .null,
          "model": admission.model.map(JSONValue.string) ?? .null,
          "mode": .string(admission.executionMode.rawValue),
          "reasoningEffort": admission.reasoningEffort.map(JSONValue.string) ?? .null,
          "requestMetadataRecorded": .bool(admission.requestMetadataRecorded ?? false),
          "startedAtUnixSeconds": outcome == nil ? .number(Decimal(at)) : .null,
          "elapsedSeconds": outcome == nil ? .number(0) : .null,
          "hasFirstEvent": outcome == nil ? .bool(false) : .null,
        ]), outcome: outcome, at: at, first: false)
    }
  }
}
