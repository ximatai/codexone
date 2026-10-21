import CodexOneRuntime
import ServiceLifecycle
import Testing

private actor Probe {
  private var started = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  var stopped = false
  func markStarted() {
    started = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
  func waitUntilStarted() async {
    if started { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func markStopped() { stopped = true }
}

private struct WaitingService: Service {
  let probe: Probe
  func run() async throws {
    await probe.markStarted()
    do { try await gracefulShutdown() } catch is CancellationError {}
    await probe.markStopped()
  }
}
private struct FailingService: Service {
  struct Expected: Error {}
  let probe: Probe
  func run() async throws {
    await probe.waitUntilStarted()
    throw Expected()
  }
}

@Test(.timeLimit(.minutes(1))) func partialStartupFailureStopsAndAwaitsTheOtherService() async {
  let probe = Probe()
  let runtime = GatewayRuntime(services: [
    WaitingService(probe: probe), FailingService(probe: probe),
  ])
  do {
    try await runtime.run(handleSignals: false)
    Issue.record("A child failure must propagate")
  } catch {
    #expect(error is FailingService.Expected)
  }
  #expect(await probe.stopped)
}

@Test(.timeLimit(.minutes(1))) func parentCancellationStopsOwnedServices() async throws {
  let probe = Probe()
  let task = Task {
    try await GatewayRuntime(services: [WaitingService(probe: probe)]).run(handleSignals: false)
  }
  await probe.waitUntilStarted()
  task.cancel()
  _ = await task.result
  #expect(await probe.stopped)
}
