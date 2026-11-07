import CodexOneCore
import Foundation
import Synchronization

/// One signal slot. Execution publishers never create a task or wait for a consumer.
public final class OverviewActivity: Sendable {
  enum Signal: Sendable { case changed, tick }
  enum Event: Sendable {
    case admitted(id: String, row: JSONValue)
    case firstEvent(id: String)
    case finished(id: String)
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
      let pending = Task { await self.sample(generation: turn) }
      worker = pending
      await withTaskCancellationHandler {
        await pending.value
      } onCancel: {
        pending.cancel()
      }
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
  }
  private func sample(generation turn: Int) async {
    let time = now()
    let initial = sections.count != Self.names.count
    let events = activity.drain()
    let activityChanged = !events.0.isEmpty || events.1 > 0
    overflow += events.1
    dirty = dirty || events.1 > 0
    for event in events.0 {
      switch event {
      case .firstEvent(let id):
        if var row = rows[id]?.object {
          row["hasFirstEvent"] = .bool(true)
          rows[id] = .object(row)
        }
      case .admitted(let id, let row):
        if rows.count < 200 {
          rows[id] = row
        } else {
          overflow += 1
        }
      case .finished(let id):
        rows.removeValue(forKey: id)
        dirty = true
      }
    }
    var changed: [String: JSONValue] = [:]
    for name in Self.names {
      let period: Int64 =
        name == "storage" ? 2 : (["accounts", "attention"].contains(name) ? 15 : 5)
      let aggregate = ["daily", "keys", "headroom"].contains(name)
      guard initial || time >= (due[name] ?? 0) || (aggregate && dirty && time - lastAggregate >= 2)
      else { continue }
      let previous = sections[name]
      do {
        let data = try JSONValue.decode(try await read(name))
        guard turn == generation, !viewers.isEmpty, !Task.isCancelled else { return }
        if name == "inFlight" {
          rows = Dictionary(
            uniqueKeysWithValues: (data["rows"]?.array ?? []).compactMap { row in
              row["id"]?.string.map { ($0, row) }
            })
        }
        replace(name, data: name == "inFlight" ? flight() : data, at: time, error: nil)
      } catch {
        guard turn == generation, !viewers.isEmpty, !Task.isCancelled else { return }
        replace(name, data: nil, at: time, error: "source_unavailable")
      }
      due[name] = time + period
      changed[name] = delta(name, previous: previous)
    }
    if dirty && time - lastAggregate >= 2 {
      lastAggregate = time
      dirty = false
    }
    // A connection registry wake has no execution event but still updates the activity section.
    if let source = sections["inFlight"], source["data"] != .null {
      let data = flight()
      if activityChanged || sections["inFlight"]?["data"]?["clients"] != data["clients"] {
        let previous = sections["inFlight"]
        // Activity observation does not prove that SQLite reconciliation recovered.
        replace("inFlight", data: data, at: time, error: source["code"]?.string)
        if let update = delta("inFlight", previous: previous) { changed["inFlight"] = update }
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
  private func flight() -> JSONValue {
    .object([
      "rows": .array(rows.keys.sorted().compactMap { rows[$0] }),
      "recentlyFinished": .array([]), "overflow": .number(Decimal(overflow)),
      "clients": activity.clients(),
    ])
  }
  private func replace(_ name: String, data: JSONValue?, at: Int64, error: String?) {
    let old = sections[name]
    let contents = data ?? old?["data"] ?? .null
    let version = (old?["version"]?.integer ?? 0) + (old?["data"] != contents ? 1 : 0)
    sections[name] = .object([
      "version": .number(Decimal(version)), "sampledAtUnixSeconds": .number(Decimal(at)),
      "lastSuccessAt": error == nil ? .number(Decimal(at)) : (old?["lastSuccessAt"] ?? .null),
      "freshness": .string(
        error == nil
          ? "fresh"
          : (old?["lastSuccessAt"] == nil || old?["lastSuccessAt"] == .null
            ? "unavailable" : "stale")),
      "code": error.map(JSONValue.string) ?? .null, "data": contents,
    ])
  }
  // Same content advances freshness without copying the full DTO onto every viewer's queue.
  // Full snapshots always use the complete cache; a missing data member means keep this version.
  private func delta(_ name: String, previous: JSONValue?) -> JSONValue? {
    guard let current = sections[name], current != previous else { return nil }
    if previous?["data"] == current["data"] {
      var metadata = current.object!
      metadata.removeValue(forKey: "data")
      return .object(metadata)
    }
    return current
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
