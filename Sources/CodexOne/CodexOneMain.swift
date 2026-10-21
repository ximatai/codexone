import CodexOneAdapters
import CodexOneCore
import CodexOneRuntime
import Foundation
import NIOPosix

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

@main
struct CodexOneMain {
  static func main() async {
    do {
      try await run()
    } catch let error as RuntimeConfiguration.ConfigurationError {
      let message: String
      switch error {
      case .invalidPort(let key): message = "Invalid port configuration: \(key)."
      case .conflictingPorts: message = "Data and admin ports must differ."
      }
      FileHandle.standardError.write(Data((message + "\n").utf8))
      exit(78)
    } catch is CommandError {
      FileHandle.standardError.write(Data("Unsupported arguments. Use --help.\n".utf8))
      exit(64)
    } catch {
      FileHandle.standardError.write(Data("Service startup or shutdown failed.\n".utf8))
      exit(1)
    }
  }

  private static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
      print(
        "Usage: codexone [--check-config | --help]\nEnvironment: CODEXONE_DATA_PORT, CODEXONE_ADMIN_PORT (0 = ephemeral). Listeners are loopback-only."
      )
      return
    }
    guard arguments.isEmpty || arguments == ["--check-config"] else {
      throw CommandError.unsupportedArguments
    }
    let configuration = try RuntimeConfiguration(environment: ProcessInfo.processInfo.environment)
    if arguments == ["--check-config"] {
      let data = try JSONSerialization.data(
        withJSONObject: [
          "host": "127.0.0.1", "dataPort": configuration.dataPort,
          "adminPort": configuration.adminPort,
        ], options: [.sortedKeys])
      FileHandle.standardOutput.write(data + Data([10]))
      return
    }
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let report = ReadinessReport.unconfigured
    let runtime = GatewayRuntime(services: [
      DataPlaneService(group: group, port: configuration.dataPort, report: report) {
        announce("data", port: $0)
      },
      AdminService(group: group, port: configuration.adminPort, report: report) {
        announce("admin", port: $0)
      },
    ])
    do {
      try await runtime.run()
    } catch {
      try await group.shutdownGracefully()
      throw error
    }
    try await group.shutdownGracefully()
  }

  private static func announce(_ listener: String, port: Int) {
    FileHandle.standardOutput.write(Data("LISTENING \(listener) 127.0.0.1:\(port)\n".utf8))
  }

  private enum CommandError: Error { case unsupportedArguments }
}
