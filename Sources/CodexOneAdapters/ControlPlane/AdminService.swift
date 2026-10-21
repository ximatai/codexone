import CodexOneCore
import NIOCore
import ServiceLifecycle
import Vapor

public struct AdminService: Service {
  private let group: any EventLoopGroup
  private let port: Int
  private let report: ReadinessReport
  private let onBound: @Sendable (Int) -> Void

  public init(
    group: any EventLoopGroup, port: Int, report: ReadinessReport,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.group = group
    self.port = port
    self.report = report
    self.onBound = onBound
  }

  public func run() async throws {
    // Start the server directly: ServiceGroup is the only signal owner.
    let app = try await Application.make(.production, .shared(group))
    app.http.server.configuration.hostname = "127.0.0.1"
    app.http.server.configuration.port = port
    app.http.server.configuration.shutdownTimeout = .seconds(2)
    app.middleware = .init()
    app.middleware.use(BootstrapErrorMiddleware())
    app.routes.defaultMaxBodySize = "4kb"
    let router = HealthRouter(report: report)
    for path in ["live", "ready"] {
      app.get("health", PathComponent(stringLiteral: path)) { _ -> Response in
        let reply = router.reply(method: "GET", uri: "/health/\(path)")
        return Self.response(reply)
      }
    }
    app.get("api", "system") { _ -> Response in
      let body = try JSONEncoder().encode(SystemStatusResponse(report: report))
      return Self.response(HTTPReply(status: 200, body: body))
    }
    do {
      try await app.asyncBoot()
      try await app.server.start(address: nil)
      onBound(app.http.server.shared.localAddress!.port!)
      let closed = AsyncStream<Void> { continuation in
        app.server.onShutdown.whenComplete { _ in continuation.finish() }
      }
      await cancelWhenGracefulShutdown {
        for await _ in closed {}
      }
    } catch {
      await app.server.shutdown()
      try await app.asyncShutdown()
      throw error
    }
    await app.server.shutdown()
    try await app.asyncShutdown()
  }

  private static func response(_ reply: HTTPReply) -> Response {
    var headers = HTTPHeaders()
    headers.add(name: "content-type", value: "application/json; charset=utf-8")
    headers.add(name: "cache-control", value: "no-store")
    return Response(
      status: .init(statusCode: reply.status), headers: headers,
      body: .init(data: reply.body))
  }
}

// Bootstrap errors contain no request path, header, body, or framework reason.
private struct BootstrapErrorMiddleware: AsyncMiddleware {
  func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
    do {
      return try await next.respond(to: request)
    } catch {
      let status = (error as? any AbortError)?.status ?? .internalServerError
      return Response(
        status: status,
        headers: ["content-type": "application/json", "cache-control": "no-store"],
        body: .init(string: #"{"error":{"code":"request_failed","message":"Request failed."}}"#))
    }
  }
}
