import CodexOneCore
import Foundation

extension SQLiteExecutionStore {
  /// Called only after COMMIT, on the existing writer queue. No SQL or throwing operation.
  func publishOverview(_ admission: ExecutionAdmission, at: Int64) {
    overviewActivity.publish {
      .admitted(
        id: admission.attempt,
        row: .object([
          "id": .string(admission.attempt), "keyID": .string(admission.owner.key),
          "principal": .string(admission.owner.principal), "displayName": .null,
          "accountID": .string(admission.owner.identity), "accountDisplayName": .null,
          "model": admission.model.map(JSONValue.string) ?? .null,
          "mode": .string(admission.executionMode.rawValue),
          "reasoningEffort": admission.reasoningEffort.map(JSONValue.string) ?? .null,
          "requestMetadataRecorded": .bool(admission.requestMetadataRecorded ?? false),
          "startedAtUnixSeconds": .number(Decimal(at)),
          "elapsedSeconds": .number(0),
          "hasFirstEvent": .bool(false),
        ]))
    }
  }
}
