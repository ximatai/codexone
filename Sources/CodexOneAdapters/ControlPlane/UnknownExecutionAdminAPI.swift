import CodexOneCore
import Foundation
import Vapor

struct UnknownExecutionAdminAPI: Sendable {
  let store: any UnknownExecutionReleasing
  func register(_ routes: any RoutesBuilder) {
    routes.post("executions", "unknown", "release") { request async throws -> Response in
      guard request.url.query == nil,
        request.headers["content-type"].count == 1,
        request.headers.first(name: "content-type")?.lowercased().split(separator: ";").first?
          .trimmingCharacters(in: .whitespaces) == "application/json",
        request.headers["content-encoding"].isEmpty, let buffer = request.body.data
      else { throw ExecutionError.invalidCommand }
      let document = try JSONValue.decode(Data(buffer.readableBytesView))
      guard let object = document.object,
        Set(object.keys) == ["beforeUnixSeconds", "expectedCount"],
        let before = document["beforeUnixSeconds"]?.integer, before >= 0,
        let expected = document["expectedCount"]?.integer, expected >= 0
      else { throw ExecutionError.invalidCommand }
      let released = try await store.releaseUnknown(
        beforeUnixSeconds: before, expectedCount: expected)
      return Response(
        status: .ok,
        headers: [
          "content-type": "application/json", "cache-control": "no-store", "connection": "close",
        ],
        body: .init(data: try JSONValue.object(["released": .number(Decimal(released))]).data()))
    }
  }
}
