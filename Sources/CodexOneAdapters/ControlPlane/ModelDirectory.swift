import CodexOneCore
import Foundation
import Synchronization

struct ModelDirectorySnapshot: Codable, Sendable {
  let revision: Int64
  var active: [SingleIdentityConfiguration.Model]
  var retired: [SingleIdentityConfiguration.Model]
  var accountForModel: [String: String] = [:]
}

public actor ModelDirectory {
  private struct Discovery: Sendable {
    let account: String
    let candidateRevision: String
    let accountRevision: Int64
    let fetchedAt: Int64
    let entries: [JSONValue]
  }
  private let configuration: AccountPoolConfiguration
  private let store: SQLiteExecutionStore
  private let clock: WallClock
  private let current: Mutex<ModelDirectorySnapshot>
  private var discovery: Discovery?
  private var refreshing = false

  public init(
    configuration: AccountPoolConfiguration, store: SQLiteExecutionStore, clock: WallClock
  ) async throws {
    self.configuration = configuration
    self.store = store
    self.clock = clock
    current = Mutex(
      try await store.modelDirectorySnapshot()
        ?? .init(revision: 0, active: configuration.models, retired: []))
  }

  nonisolated func snapshot() -> ModelDirectorySnapshot { current.withLock { $0 } }

  func refresh(
    account: String, credentials: AccountCredentials, provider: SubscriptionQuotaProvider
  ) async throws -> JSONValue {
    guard !refreshing else { throw ExecutionError.conflict }
    refreshing = true
    defer { refreshing = false }
    let work = try await credentials.prepareObservation(id: account)
    let fingerprint = configuration.responses.clientFingerprint
    let response = try await provider.modelCandidates(work, fingerprint: fingerprint)
    guard let entries = response["models"]?.array, entries.count <= 128,
      entries.allSatisfy({ Self.validModelID($0["slug"]?.string) }),
      Set(entries.compactMap { $0["slug"]?.string }).count == entries.count
    else { throw QuotaObservationFailure.invalidResponse }
    discovery = Discovery(
      account: account, candidateRevision: UUID().uuidString,
      accountRevision: work.account.revision, fetchedAt: clock.unixSeconds,
      entries: entries.filter { $0["visibility"] == nil || $0["visibility"] == .string("list") })
    return document()
  }

  func document() -> JSONValue {
    let snapshot = snapshot()
    let known = Set((snapshot.active + snapshot.retired).map(\.id))
    let discovered = discovery
    let candidates =
      discovered?.entries.compactMap { entry -> JSONValue? in
        guard let id = entry["slug"]?.string, !known.contains(id) else { return nil }
        let model = Self.discoveredModel(id: id, entry: entry, input: 0, output: 0)
        let complete = (try? validateResponseModels([model])) != nil
        return Self.metadata(model, state: complete ? "candidate" : "incomplete")
      } ?? []
    return .object([
      "revision": .number(Decimal(snapshot.revision)),
      "active": .array(snapshot.active.map { Self.metadata($0, state: "enabled") }),
      "retired": .array(
        snapshot.retired.map { model in
          guard let owner = snapshot.accountForModel[model.id],
            let discovery, discovery.account == owner,
            let entry = discovery.entries.first(where: { $0["slug"]?.string == model.id })
          else { return Self.metadata(model, state: "retired") }
          let refreshed = Self.discoveredModel(
            id: model.id, entry: entry, input: model.inputMicrosPerMillion,
            output: model.outputMicrosPerMillion)
          return Self.metadata(
            refreshed, state: "retired", previousVisionInput: model.visionInput == true)
        }),
      "candidates": .array(candidates),
      "imageModels": .array((configuration.imageGeneration?.models ?? []).map { .string($0.id) }),
      "account": discovered.map { .string($0.account) } ?? .null,
      "candidateRevision": discovered.map { .string($0.candidateRevision) } ?? .null,
      "fetchedAt": discovered.map { .number(Decimal($0.fetchedAt)) } ?? .null,
    ])
  }

  func change(_ body: JSONValue) async throws -> JSONValue {
    guard let fields = body.object,
      let revision = body["revision"]?.integer, revision >= 0, revision < Int64.max,
      let id = body["model"]?.string, Self.validModelID(id),
      let enabled = body["enabled"]?.bool
    else { throw ExecutionError.invalidCommand }
    let baseFields: Set<String> = ["revision", "model", "enabled"]
    let candidateRevision = body["candidateRevision"]?.string
    let suppliedFields = baseFields.union(candidateRevision == nil ? [] : ["candidateRevision"])
    let previous = snapshot()
    guard previous.revision == revision else { throw ExecutionError.conflict }
    var expectedAccount: (id: String, revision: Int64)?
    var next = ModelDirectorySnapshot(
      revision: revision + 1, active: previous.active, retired: previous.retired,
      accountForModel: previous.accountForModel)
    if enabled, next.accountForModel[id] != nil || !next.retired.contains(where: { $0.id == id }) {
      guard let discovery, discovery.candidateRevision == candidateRevision else {
        throw ExecutionError.conflict
      }
    }
    if enabled, let index = next.retired.firstIndex(where: { $0.id == id }) {
      guard Set(fields.keys) == suppliedFields else { throw ExecutionError.invalidCommand }
      if let owner = next.accountForModel[id] {
        guard let discovery, discovery.account == owner,
          discovery.candidateRevision == candidateRevision,
          clock.unixSeconds - discovery.fetchedAt < 900,
          let entry = discovery.entries.first(where: { $0["slug"]?.string == id })
        else { throw ExecutionError.conflict }
        let account = try await store.accountCredential(id: owner).account
        guard account.revision == discovery.accountRevision, account.mode == .enabled,
          account.authorization == .ready
        else { throw ExecutionError.conflict }
        expectedAccount = (account.id, account.revision)
        let previous = next.retired[index]
        let refreshed = Self.discoveredModel(
          id: id, entry: entry, input: previous.inputMicrosPerMillion,
          output: previous.outputMicrosPerMillion)
        try validateResponseModels([refreshed])
        next.retired[index] = refreshed
      }
      next.active.append(next.retired.remove(at: index))
    } else if enabled {
      guard !next.active.contains(where: { $0.id == id }),
        Set(fields.keys)
          == suppliedFields.union(["inputMicrosPerMillion", "outputMicrosPerMillion"]),
        let input = body["inputMicrosPerMillion"]?.integer,
        let output = body["outputMicrosPerMillion"]?.integer,
        let discovery, discovery.candidateRevision == candidateRevision,
        clock.unixSeconds - discovery.fetchedAt < 900,
        let entry = discovery.entries.first(where: { $0["slug"]?.string == id })
      else { throw ExecutionError.invalidCommand }
      let account = try await store.accountCredential(id: discovery.account).account
      guard account.revision == discovery.accountRevision, account.mode == .enabled,
        account.authorization == .ready
      else { throw ExecutionError.conflict }
      expectedAccount = (account.id, account.revision)
      next.active.append(Self.discoveredModel(id: id, entry: entry, input: input, output: output))
      next.accountForModel[id] = account.id
    } else {
      guard Set(fields.keys) == baseFields,
        let index = next.active.firstIndex(where: { $0.id == id })
      else { throw ExecutionError.invalidCommand }
      next.retired.append(next.active.remove(at: index))
    }
    try validateResponseModels(next.active)
    try configuration.imageGeneration?.validate(hosts: next.active)
    guard next.active.count + next.retired.count <= 32 else { throw ExecutionError.capacity }
    try await store.replaceModelDirectory(
      next, expected: revision, imageModels: configuration.imageGeneration?.models.map(\.id) ?? [],
      expectedAccount: expectedAccount)
    current.withLock { if $0.revision < next.revision { $0 = next } }
    return document()
  }

  private static func validModelID(_ id: String?) -> Bool {
    guard let id else { return false }
    return (1...128).contains(id.utf8.count)
      && id.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || [45, 46, 95].contains($0)
      }
  }

  private static func discoveredModel(
    id: String, entry: JSONValue, input: Int64, output: Int64
  ) -> SingleIdentityConfiguration.Model {
    .init(
      id: id, inputMicrosPerMillion: input, outputMicrosPerMillion: output,
      upstream: entry,
      visionInput: entry["input_modalities"]?.array?.contains(.string("image")) == true)
  }

  private static func metadata(
    _ model: SingleIdentityConfiguration.Model, state: String, previousVisionInput: Bool? = nil
  ) -> JSONValue {
    let efforts = model.supportedReasoningEfforts
    let preferred =
      model.catalog?.defaultReasoningEffort
      ?? model.upstream?["default_reasoning_level"]?.string
    return .object([
      "id": .string(model.id),
      "state": .string(state),
      "visionInput": .bool(model.visionInput == true),
      "previousVisionInput": previousVisionInput.map(JSONValue.bool) ?? .null,
      "reasoningEfforts": .array(efforts.map(JSONValue.string)),
      "defaultReasoningEffort": preferred.flatMap { efforts.contains($0) ? .string($0) : nil }
        ?? .null,
    ])
  }
}
