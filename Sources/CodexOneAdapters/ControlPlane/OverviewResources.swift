import Foundation
import ServiceLifecycle
import Synchronization

/// One process-wide sampler. Reads never perform sampling or file I/O.
public final class OverviewResources: Service, Sendable {
  public struct Sample: Encodable, Sendable {
    let unixSeconds: Int64
    let processResidentBytes: UInt64?
    let hostAvailableBytes: UInt64?
    let hostTotalBytes: UInt64?
    let hostCPUPercent: Double?
  }

  private let history = Mutex<[Sample]>([])
  var samples: [Sample] { history.withLock { $0 } }

  public init() {}

  public func run() async throws {
    #if os(Linux)
      try await sampleUntilShutdown()
    #else
      do { try await gracefulShutdown() } catch is CancellationError {}
    #endif
  }

  private func sampleUntilShutdown() async throws {
    do {
      try await cancelWhenGracefulShutdown { [self] in
        var previous: CPU?
        while !Task.isCancelled {
          let cpu = Self.cpu()
          let memory = Self.kibValues("/proc/meminfo", keys: ["MemAvailable:", "MemTotal:"])
          let resident = Self.kibValues("/proc/self/status", keys: ["VmRSS:"])
          let sample = Sample(
            unixSeconds: Int64(Date().timeIntervalSince1970),
            processResidentBytes: resident["VmRSS:"],
            hostAvailableBytes: memory["MemAvailable:"],
            hostTotalBytes: memory["MemTotal:"],
            hostCPUPercent: cpu.flatMap { $0.percent(since: previous) })
          history.withLock {
            $0.removeAll {
              $0.unixSeconds < sample.unixSeconds - 3600 || $0.unixSeconds > sample.unixSeconds
            }
            if $0.count >= 121 { $0.removeFirst() }
            $0.append(sample)
          }
          previous = cpu
          try await Task.sleep(for: .seconds(30))
        }
      }
    } catch is CancellationError {}
  }

  private struct CPU {
    let total: UInt64
    let idle: UInt64

    func percent(since previous: CPU?) -> Double? {
      guard let previous, total > previous.total, idle >= previous.idle else { return nil }
      let delta = total - previous.total
      let idleDelta = idle - previous.idle
      guard idleDelta <= delta else { return nil }
      return Double(delta - idleDelta) / Double(delta) * 100
    }
  }

  private static func cpu() -> CPU? {
    guard let stat = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
      let line = stat.split(separator: "\n").first
    else { return nil }
    let fields = line.split(whereSeparator: \.isWhitespace)
    guard fields.first == "cpu" else { return nil }
    let ticks = fields.dropFirst().prefix(8).compactMap { UInt64($0) }
    guard ticks.count == 8 else { return nil }
    return CPU(total: ticks.reduce(0, +), idle: ticks[3] + ticks[4])
  }

  private static func kibValues(_ path: String, keys: Set<String>) -> [String: UInt64] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var result: [String: UInt64] = [:]
    for line in contents.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count == 3, fields[2] == "kB", keys.contains(String(fields[0])),
        let value = UInt64(fields[1]), value <= UInt64.max / 1024
      else { continue }
      result[String(fields[0])] = value * 1024
    }
    return result
  }
}
