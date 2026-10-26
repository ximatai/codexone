import Foundation

/// The last successful native WS response on one lane; omitted declarations may inherit Lite mode.
struct ClientToolSnapshot: Sendable {
  let responseID: String
  let model: String
  let usesResponsesLite: Bool
}
