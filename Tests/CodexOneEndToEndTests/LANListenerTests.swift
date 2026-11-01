import CodexOneAdapters
import CodexOneRuntime
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing

@testable import CodexOneCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Uses a second loopback literal solely through Core's internal test initializer. Production env
/// validation rejects 127/8, so this never enables a public or wildcard binding in the gateway.
@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func lanListenersFilterSilentPeersKeepLoopbackAndReleaseAllSockets(denyPeer: Bool) async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = try await SQLiteExecutionStore.open(
    path: root.appendingPathComponent("core.sqlite").path,
    limits: .init(requests: 10, active: 2, unresolved: 2, budgetMicros: 100))
  let finalizer = try ExecutionFinalizer(store: store)
  let configuration = try JSONDecoder().decode(
    SingleIdentityConfiguration.self,
    from: JSONSerialization.data(withJSONObject: [
      "principal": "synthetic", "keyID": "synthetic",
      "keySHA256": String(repeating: "a", count: 64),
      "namespace": "synthetic", "identity": "synthetic", "reservedMicros": 1,
      "models": [["id": "synthetic", "inputMicrosPerMillion": 0, "outputMicrosPerMillion": 0]],
      "upstreamBaseURL": "http://127.0.0.1:9/v1",
    ]))
  #if os(Linux)
    let secondAddress = "127.0.0.2"
    let secondHost = secondAddress
  #else
    let secondAddress = "::1"
    let secondHost = "[::1]"
  #endif
  let policy = try ListenerConfiguration(
    testLoopbackAddress: secondAddress,
    allowedNetworks: denyPeer ? "10.0.0.0/8" : "127.0.0.0/8,::1/128")
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let bound = Mutex<[Int]>([])
  let runtime = GatewayRuntime(services: [
    finalizer,
    DataPlaneService(group: group, port: 0, report: .unconfigured, listeners: policy) { port in
      bound.withLock { $0.append(port) }
    },
    try ResponsesDataService(
      group: group, port: 0, configuration: configuration, store: store, finalizer: finalizer,
      listeners: policy
    ) { port in bound.withLock { $0.append(port) } },
    AdminService(group: group, port: 0, report: .unconfigured, listeners: policy) {
      port in
      bound.withLock { $0.append(port) }
    },
  ])
  let owner = Task { try await runtime.run(handleSignals: false) }
  var phase = "startup"
  do {
    for _ in 0..<300 {
      if bound.withLock({ $0.count }) == 3 { break }
      try await Task.sleep(for: .milliseconds(10))
    }
    let ports = bound.withLock { $0 }
    try #require(ports.count == 3, "All listeners must bind before testing")
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    phase = "health requests"
    for port in ports {
      // Loopback remains exempt even when 127/8 is absent from the LAN allow list.
      var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health/live")!)
      request.timeoutInterval = 2
      let (_, response) = try await session.data(for: request)
      #expect((response as? HTTPURLResponse)?.statusCode == 200)
      if denyPeer {
        // Send zero bytes: closing before a head/body/deadline proves admission does not wait for
        // HTTP parsing. A forged forwarded header cannot affect this pre-request decision.
        let socket = try await ClientBootstrap(group: group)
          .connect(host: secondAddress, port: port).get()
        let deadline = socket.eventLoop.scheduleTask(in: .seconds(2)) {
          Issue.record("Disallowed silent peer was not closed before the read deadline")
          socket.close(promise: nil)
        }
        try await socket.closeFuture.get()
        deadline.cancel()
      } else {
        request.url = URL(string: "http://\(secondHost):\(port)/health/live")!
        let (_, response) = try await session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
      }
    }
    owner.cancel()
    try await owner.value
    for port in ports {
      for host in ["127.0.0.1", secondAddress] {
        phase = "rebind after shutdown: " + host
        let rebound = try await ServerBootstrap(group: group)
          .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
          .bind(host: host, port: port).get()
        try await rebound.close().get()
      }
    }
  } catch {
    Issue.record("LAN socket check failed during \(phase)")
    owner.cancel()
    _ = await owner.result
    await store.close()
    try await group.shutdownGracefully()
    throw error
  }
  await store.close()
  try await group.shutdownGracefully()
}
