import Synchronization

/// One bounded snapshot per lane, released with the connection supervisor.
final class WebSocketToolState: Sendable {
  private let value = Mutex<ClientToolSnapshot?>(nil)
  var snapshot: ClientToolSnapshot? { value.withLock { $0 } }

  func observe(_ event: JSONValue, request: ResponseRequest) {
    guard event["type"]?.string == "response.completed",
      event["response"]?["status"]?.string == "completed",
      let id = event["response"]?["id"]?.string
    else { return }
    value.withLock {
      $0 = .init(
        responseID: id, model: request.model, usesResponsesLite: request.usesResponsesLite)
    }
  }
}
