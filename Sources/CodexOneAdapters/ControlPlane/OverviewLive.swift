import CodexOneCore
import Foundation
import Synchronization

/// One signal slot. Execution publishers never create a task or wait for a consumer.
public final class OverviewActivity: Sendable {
  enum Signal: Sendable { case changed, tick }
  struct Event: Sendable {
    let id: String
    let row: JSONValue?
    let outcome: String?
    let at: Int64
    let first: Bool
  }
  private struct State {
    var watching = false
    var events: [Event] = []
    var overflow = 0
    var clients: [UUID: (key: String, name: String?, at: Int64)] = [:]
  }
  private let state = Mutex(State())
  private let watching = Atomic(false)
  private let dropped = Atomic(0)
  let signals: AsyncStream<Signal>
  let signal: AsyncStream<Signal>.Continuation
  public init() {
    (signals, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
  }
  func watch(_ enabled: Bool) {
    if !enabled { watching.store(false, ordering: .relaxed) }
    state.withLock {
      $0.watching = enabled
      $0.events.removeAll()
      $0.overflow = 0
    }
    dropped.store(0, ordering: .relaxed)
    if enabled { watching.store(true, ordering: .relaxed) }
  }
  // The closure is not evaluated with zero viewers: no projection, SQL, encoding or allocation.
  func publish(_ event: () -> Event?) {
    guard watching.load(ordering: .relaxed) else { return }
    let changed = state.withLockIfAvailable { value in
      guard value.watching else { return false }
      guard let event = event() else { return false }
      if value.events.count < 512 { value.events.append(event) } else { value.overflow += 1 }
      return true
    }
    if changed == nil { _ = dropped.wrappingAdd(1, ordering: .relaxed) }
    if changed != false { signal.yield(.changed) }
  }
  func drain() -> ([Event], Int) {
    state.withLock { value in
      let result = (value.events, value.overflow + dropped.exchange(0, ordering: .relaxed))
      value.events.removeAll(keepingCapacity: true)
      value.overflow = 0
      return result
    }
  }
  func register(key: String, name: String?, capacity: Int) -> UUID? {
    let id = UUID()
    let watching = state.withLock { value -> Bool? in
      guard value.clients.count < capacity else { return nil }
      value.clients[id] = (key, name, Int64(Date().timeIntervalSince1970))
      return value.watching
    }
    guard let watching else { return nil }
    if watching { signal.yield(.changed) }
    return id
  }
  func unregister(_ id: UUID) {
    let watching = state.withLock { value in
      value.clients.removeValue(forKey: id)
      return value.watching
    }
    if watching { signal.yield(.changed) }
  }
  func clients() -> JSONValue {
    let clients = state.withLock { $0.clients }
    let groups = Dictionary(grouping: clients.values, by: \.key)
    return .array(
      groups.keys.sorted().map { key in
        let items = groups[key]!
        return .object([
          "keyID": .string(key), "displayName": items.first?.name.map(JSONValue.string) ?? .null,
          "count": .number(Decimal(items.count)),
          "connectedAtUnixSeconds": .number(Decimal(items.map(\.at).min()!)),
        ])
      })
  }
}

/// The transport owns one mailbox: two pending messages/2 MiB plus one in-flight frame.
final class OverviewMailbox: Sendable {
  struct Message: Sendable {
    let snapshot: Bool
    let data: Data
  }
  private struct State {
    var messages: [Message] = []
    var waiter: CheckedContinuation<Message?, Never>?
    var closed = false
  }
  private let state = Mutex(State())
  let close: @Sendable (UInt16) -> Void
  init(close: @escaping @Sendable (UInt16) -> Void) { self.close = close }
  func offer(_ message: Message) {
    let result = state.withLock { value -> (CheckedContinuation<Message?, Never>?, Bool) in
      guard !value.closed else { return (nil, false) }
      if let waiter = value.waiter {
        value.waiter = nil
        return (waiter, false)
      }
      if value.messages.count == 2
        || value.messages.reduce(0, { $0 + $1.data.count }) + message.data.count > 2_097_152
      {
        return (nil, true)
      }
      value.messages.append(message)
      return (nil, false)
    }
    result.0?.resume(returning: message)
    if result.1 {
      finish()
      close(1013)
    }
  }
  func next() async -> Message? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let result = state.withLock { value -> (Bool, Message?) in
          if !value.messages.isEmpty { return (true, value.messages.removeFirst()) }
          if value.closed || Task.isCancelled { return (true, nil) }
          precondition(value.waiter == nil)
          value.waiter = continuation
          return (false, nil)
        }
        if result.0 { continuation.resume(returning: result.1) }
      }
    } onCancel: {
      self.finish()
    }
  }
  func finish() {
    let waiter = state.withLock { value in
      value.closed = true
      value.messages.removeAll()
      let waiter = value.waiter
      value.waiter = nil
      return waiter
    }
    waiter?.resume(returning: nil)
  }
}

/// Shared read-only producer. Runtime calls run; no producer exists per viewer.
public actor OverviewLive: OverviewLiveRunning {
  public typealias Read = @Sendable (String) async throws -> Data
  public let activity: OverviewActivity
  let epoch = UUID().uuidString
  private let read: Read
  private let now: @Sendable () -> Int64
  private var viewers: [UUID: OverviewMailbox] = [:]
  private var sections: [String: JSONValue] = [:]
  private var due: [String: Int64] = [:]
  private var generation = 0
  private var stopping = false
  private var draining = false
  private var worker: Task<Void, Never>?
  private var ticker: Task<Void, Never>?
  private var rows: [String: JSONValue] = [:]
  private var recent: [JSONValue] = []
  private var overflow = 0
  private var dirty = false
  private var lastAggregate: Int64 = 0
  static let names = [
    "system", "inFlight", "daily", "keys", "accounts", "storage", "attention", "headroom",
  ]
  public init(
    activity: OverviewActivity, read: @escaping Read,
    now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
  ) {
    self.activity = activity
    self.read = read
    self.now = now
  }
  func subscribe(id: UUID, mailbox: OverviewMailbox) throws {
    guard !stopping, !draining, viewers.count < 8 else { throw ExecutionError.capacity }
    viewers[id] = mailbox
    if viewers.count == 1 {
      activity.watch(true)
      activity.signal.yield(.tick)
    } else if sections.count == Self.names.count {
      try send(to: [mailbox], snapshot: true, sections: sections)
    }
  }
  func unsubscribe(id: UUID) async {
    viewers.removeValue(forKey: id)?.finish()
    guard viewers.isEmpty else { return }
    draining = true
    defer { draining = false }
    generation += 1
    activity.watch(false)
    ticker?.cancel()
    worker?.cancel()
    await worker?.value
    await ticker?.value
    ticker = nil
    sections.removeAll()
    due.removeAll()
    rows.removeAll()
    recent.removeAll()
    overflow = 0
    dirty = false
  }
  public func run() async throws {
    for await signal in activity.signals {
      if Task.isCancelled { break }
      guard !viewers.isEmpty, !stopping, !draining else { continue }
      if ticker == nil {
        ticker = Task { [activity] in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            activity.signal.yield(.tick)
          }
        }
      }
      // Coalesce bounded publication into one activity update without querying away short requests.
      if case .changed = signal { try? await Task.sleep(for: .milliseconds(100)) }
      let turn = generation
      worker = Task { await self.sample(generation: turn) }
      await worker?.value
      worker = nil
    }
  }
  public func shutdown() async {
    stopping = true
    generation += 1
    activity.watch(false)
    worker?.cancel()
    await worker?.value
    worker = nil
    ticker?.cancel()
    await ticker?.value
    ticker = nil
    for mailbox in viewers.values {
      mailbox.finish()
      mailbox.close(1001)
    }
    viewers.removeAll()
    sections.removeAll()
    due.removeAll()
    rows.removeAll()
    recent.removeAll()
  }
  private func sample(generation turn: Int) async {
    let time = now()
    let initial = sections.count != Self.names.count
    let events = activity.drain()
    var activityChanged = !events.0.isEmpty || events.1 > 0
    overflow += events.1
    dirty = dirty || events.1 > 0
    for event in events.0 {
      if event.first {
        if var row = rows[event.id]?.object {
          row["hasFirstEvent"] = .bool(true)
          rows[event.id] = .object(row)
        }
      } else if let row = event.row {
        if let outcome = event.outcome {
          var value = (rows[event.id] ?? row).object!
          rows.removeValue(forKey: event.id)
          value["outcome"] = .string(outcome)
          value["finishedAtUnixSeconds"] = .number(Decimal(event.at))
          if let start = value["startedAtUnixSeconds"]?.integer {
            value["elapsedSeconds"] = .number(Decimal(max(0, event.at - start)))
          }
          recent.removeAll { $0["id"]?.string == event.id }
          if recent.count == 64 {
            recent.removeFirst()
            overflow += 1
          }
          recent.append(.object(value))
          dirty = true
        } else if rows.count < 200 {
          rows[event.id] = row
        } else {
          overflow += 1
        }
      }
    }
    let oldCount = recent.count
    recent.removeAll { ($0["finishedAtUnixSeconds"]?.integer ?? 0) <= time - 10 }
    activityChanged = activityChanged || recent.count != oldCount
    var changed: [String: JSONValue] = [:]
    for name in Self.names {
      let period: Int64 =
        name == "storage" ? 2 : (["accounts", "attention"].contains(name) ? 15 : 5)
      let aggregate = ["daily", "keys", "headroom"].contains(name)
      guard initial || time >= (due[name] ?? 0) || (aggregate && dirty && time - lastAggregate >= 2)
      else { continue }
      do {
        let data = try JSONValue.decode(try await read(name))
        guard turn == generation, !viewers.isEmpty, !Task.isCancelled else { return }
        if name == "inFlight" {
          rows = Dictionary(
            uniqueKeysWithValues: (data["rows"]?.array ?? []).compactMap { row in
              row["id"]?.string.map { ($0, row) }
            })
        }
        replace(name, data: name == "inFlight" ? flight(at: time) : data, at: time, error: nil)
      } catch {
        guard turn == generation, !viewers.isEmpty else { return }
        replace(name, data: nil, at: time, error: "source_unavailable")
      }
      due[name] = time + period
      changed[name] = sections[name]
    }
    if dirty && time - lastAggregate >= 2 {
      lastAggregate = time
      dirty = false
    }
    // A connection registry wake has no execution event but still updates the activity section.
    if sections["inFlight"] != nil {
      let data = flight(at: time)
      if activityChanged || sections["inFlight"]?["data"]?["clients"] != data["clients"] {
        replace("inFlight", data: data, at: time, error: nil)
        changed["inFlight"] = sections["inFlight"]
      }
    }
    do {
      try send(to: Array(viewers.values), snapshot: initial, sections: initial ? sections : changed)
    } catch {
      for mailbox in viewers.values {
        mailbox.finish()
        mailbox.close(1013)
      }
    }
  }
  private func flight(at time: Int64) -> JSONValue {
    .object([
      "rows": .array(rows.keys.sorted().compactMap { rows[$0] }),
      "recentlyFinished": .array(recent), "overflow": .number(Decimal(overflow)),
      "clients": activity.clients(),
    ])
  }
  private func replace(_ name: String, data: JSONValue?, at: Int64, error: String?) {
    let old = sections[name]
    let version = (old?["version"]?.integer ?? 0) + (old?["data"] != data || error != nil ? 1 : 0)
    sections[name] = .object([
      "version": .number(Decimal(version)), "sampledAtUnixSeconds": .number(Decimal(at)),
      "lastSuccessAt": error == nil ? .number(Decimal(at)) : (old?["lastSuccessAt"] ?? .null),
      "freshness": .string(
        error == nil
          ? "fresh"
          : (old?["lastSuccessAt"] == nil || old?["lastSuccessAt"] == .null
            ? "unavailable" : "stale")),
      "code": error.map(JSONValue.string) ?? .null, "data": data ?? old?["data"] ?? .null,
    ])
  }
  private func send(
    to recipients: [OverviewMailbox], snapshot: Bool, sections changes: [String: JSONValue]
  ) throws {
    guard !changes.isEmpty else { return }
    let data = try JSONValue.object(changes).data()
    let cached = try JSONValue.object(sections).data()
    // Leave room for the envelope. Cache plus both encoded working copies <= 3 MiB.
    guard data.count <= 1_048_000, cached.count <= 1_048_000 else { throw ExecutionError.capacity }
    for recipient in recipients { recipient.offer(.init(snapshot: snapshot, data: data)) }
  }
}
