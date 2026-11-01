import AsyncHTTPClient
import CodexOneCore
import Foundation
import NIOCore
import ServiceLifecycle
import Synchronization

/// Owns only transport lifetime; ordinary response execution owns protocol and accounting.
public final class SubscriptionWindowPriming: Service, QuotaPrimingExecuting, Sendable {
  private let client = Mutex<HTTPClient?>(nil)
  private let group: any EventLoopGroup
  private let configuration: AccountPoolConfiguration
  private let store: any QuotaPrimingStore
  private let finalizer: any FinalizationSink
  private let credentials: AccountCredentials
  private let refresher: any AccountDispatchRefreshing
  private let provider: SubscriptionOAuthProvider
  private let target: SubscriptionDataTarget
  private let proxy: UpstreamHTTPProxy?
  private let clock: WallClock
  var isAccepting: Bool { client.withLock { $0 != nil } }
  public var models: [String] { configuration.models.map(\.id) }
  public var defaultModel: String? {
    configuration.models.sorted {
      let a = $0.inputMicrosPerMillion + $0.outputMicrosPerMillion
      let b = $1.inputMicrosPerMillion + $1.outputMicrosPerMillion
      return a == b ? $0.id < $1.id : a < b
    }.first?.id
  }
  public init(
    group: any EventLoopGroup, configuration: AccountPoolConfiguration,
    store: any QuotaPrimingStore, finalizer: any FinalizationSink,
    credentials: AccountCredentials, refresher: any AccountDispatchRefreshing,
    provider: SubscriptionOAuthProvider, proxy: UpstreamHTTPProxy? = nil, clock: WallClock = .system
  ) {
    self.group = group
    self.configuration = configuration
    self.store = store
    self.finalizer = finalizer
    self.credentials = credentials
    self.refresher = refresher
    self.provider = provider
    self.proxy = proxy
    self.clock = clock
    self.target = .openAI
  }
  init(
    group: any EventLoopGroup, configuration: AccountPoolConfiguration,
    store: any QuotaPrimingStore, finalizer: any FinalizationSink,
    credentials: AccountCredentials, refresher: any AccountDispatchRefreshing,
    provider: SubscriptionOAuthProvider, target: SubscriptionDataTarget, clock: WallClock
  ) {
    self.group = group
    self.configuration = configuration
    self.store = store
    self.finalizer = finalizer
    self.credentials = credentials
    self.refresher = refresher
    self.provider = provider
    self.target = target
    self.clock = clock
    self.proxy = nil
  }
  public func run() async throws {
    var pool = HTTPClient.Configuration.ConnectionPool(
      idleTimeout: .seconds(10), concurrentHTTP1ConnectionsPerHostSoftLimit: 1)
    pool.retryConnectionEstablishment = false
    var config = HTTPClient.Configuration(
      redirectConfiguration: .disallow,
      timeout: .init(connect: .seconds(10), read: .seconds(20)),
      connectionPool: pool, proxy: proxy?.clientProxy, decompression: .disabled)
    config.httpVersion = .http1Only
    config.maximumUsesPerConnection = 1
    let transport = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
    client.withLock { $0 = transport }
    do { try await gracefulShutdown() } catch is CancellationError {} catch {
      client.withLock { $0 = nil }
      try await transport.shutdown()
      throw error
    }
    client.withLock { $0 = nil }
    try await transport.shutdown()
  }
  public func executePriming(id: String, settings: QuotaPrimingSettings) async throws {
    guard let modelID = settings.model ?? defaultModel,
      let model = configuration.models.first(where: { $0.id == modelID }),
      let transport = client.withLock({ $0 })
    else { throw ExecutionError.denied }
    let saved = try await store.quotaPrimingState(id: id)
    guard saved.settings == settings else { throw ExecutionError.conflict }
    let work = try await credentials.prepareDispatch(id: id, continuation: false)
    guard work.account.revision == saved.revision else { throw ExecutionError.conflict }
    let request = try Self.request(model: model, message: settings.message)
    let command = ExecutionAdmission(
      attempt: UUID().uuidString,
      owner: .init(
        principal: QuotaPrimingIdentity.principal, key: QuotaPrimingIdentity.principal,
        namespace: work.account.namespace, identity: id),
      window: "utc-day-\(clock.utcDay)", policyVersion: "quota-priming-v1",
      pricingVersion: keyDigest(
        String(model.inputMicrosPerMillion) + ":" + String(model.outputMicrosPerMillion)),
      reservedMicros: configuration.reservedMicros, mode: .priming, model: modelID,
      accountSnapshot: work.snapshot, reasoningEffort: request.reasoningEffort)
    let responses = configuration.responses
    let executor = HTTPResponseExecution(
      imageCapacity: ImageCapacity(limit: 1),
      clientHeaders: forwardedClientHeaders(.init(), fingerprint: responses.clientFingerprint),
      client: transport,
      webSocket: .init(group: group, configuration: responses, token: nil, proxy: proxy),
      configuration: responses, token: nil, report: { .init(checks: []) },
      access: .init(
        source: .pool(configuration, credentials, refresher, provider, target), token: nil,
        store: store, finalizer: finalizer, clock: clock),
      gateway: .priming(
        ExecutionCoordinator(store: store, finalizer: finalizer, clock: clock), command, work,
        provider, target),
      effectiveModels: [model])
    try await executor.execute(request, requestID: command.attempt) { _ in }
  }
  static func request(model: SingleIdentityConfiguration.Model, message: String) throws
    -> ResponseRequest
  {
    _ = try QuotaPrimingSettings(message: message)
    let declared =
      model.catalog?.reasoningEfforts
      ?? model.upstream?["supported_reasoning_levels"]?.array?.compactMap { $0["effort"]?.string }
      ?? []
    let effort =
      ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"].first {
        declared.contains($0)
      } ?? "low"
    var fields: [String: JSONValue] = [
      "model": .string(model.id), "input": .string(message), "store": .bool(false),
      "stream": .bool(true), "tools": .array([]),
      "instructions": .string("Reply with one word."),
      "reasoning": .object(["effort": .string(effort)]),
    ]
    if model.upstream?["support_verbosity"]?.bool != false {
      fields["text"] = .object(["verbosity": .string("low")])
    }
    return try ResponseRequest(data: JSONValue.object(fields).data(), mode: .priming)
  }
}
