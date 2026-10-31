import CodexOneCore
import Foundation
import NIOHTTP1

/// Trusted offline metadata; never derived from a request or an online version lookup.
public struct ClientFingerprint: Sendable, Decodable {
  public let version: String?
  public let os: String?
  public let arch: String?
  public let terminal: String?

  private enum CodingKeys: String, CodingKey, CaseIterable { case version, os, arch, terminal }
  public init(from decoder: any Decoder) throws {
    try rejectUnknownImageFields(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    version = try fields.decodeIfPresent(String.self, forKey: .version)
    os = try fields.decodeIfPresent(String.self, forKey: .os)
    arch = try fields.decodeIfPresent(String.self, forKey: .arch)
    terminal = try fields.decodeIfPresent(String.self, forKey: .terminal)
    try validate()
  }

  public init(
    version: String? = nil, os: String? = nil, arch: String? = nil, terminal: String? = nil
  ) {
    self.version = version
    self.os = os
    self.arch = arch
    self.terminal = terminal
  }

  public func validate() throws {
    for value in [version, os, arch, terminal].compactMap({ $0 }) {
      guard (1...128).contains(value.utf8.count), value.utf8.allSatisfy({ (32...126).contains($0) })
      else { throw ExecutionError.invalidCommand }
    }
  }

  func resolved(models: [SingleIdentityConfiguration.Model]) -> Self {
    let versions = models.flatMap { $0.profileProvenance?.clientVersions ?? [] }
    let latest = versions.max { $0.compare($1, options: .numeric) == .orderedAscending }
    return .init(
      version: version ?? latest ?? "0.163.0", os: os ?? "Mac OS 26.5.0",
      arch: arch ?? "arm64", terminal: terminal ?? "iTerm.app/3.6.10")
  }

  var userAgent: String {
    "codex_cli_rs/\(version!) (\(os!); \(arch!)) \(terminal!)"
  }

  static func isNative(_ headers: HTTPHeaders) -> Bool {
    let prefixes = [
      "codex_cli_rs", "codex-tui", "codex_exec", "codex_sdk_ts", "codex_vscode",
      "Codex Desktop", "Codex ",
    ]
    let originators: Set<String> = [
      "codex_cli_rs", "codex_vscode", "codex_sdk_ts", "codex_exec",
      "codex_chatgpt_desktop", "Codex Desktop",
    ]
    return headers["user-agent"].contains { ua in prefixes.contains { ua.hasPrefix($0) } }
      || headers["originator"].contains { originators.contains($0) }
  }
}
