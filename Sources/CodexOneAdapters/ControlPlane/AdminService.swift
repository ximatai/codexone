import CodexOneCore
import NIOCore
import ServiceLifecycle
import Vapor

public struct AdminService: Service {
  private let group: any EventLoopGroup
  private let port: Int
  private let keys: KeyAdminAPI?
  private let reportProvider: @Sendable () -> ReadinessReport
  private let onBound: @Sendable (Int) -> Void

  public init(
    group: any EventLoopGroup, port: Int, report: ReadinessReport,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.init(group: group, port: port, reportProvider: { report }, onBound: onBound)
  }

  public init(
    group: any EventLoopGroup, port: Int,
    reportProvider: @escaping @Sendable () -> ReadinessReport, keys: KeyAdminAPI? = nil,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.keys = keys
    self.group = group
    self.port = port
    self.reportProvider = reportProvider
    self.onBound = onBound
  }

  public func run() async throws {
    // Start the server directly: ServiceGroup is the only signal owner.
    let app = try await Application.make(.production, .shared(group))
    app.middleware = .init()
    app.middleware.use(BootstrapErrorMiddleware())
    app.routes.defaultMaxBodySize = "8kb"
    for path in ["live", "ready"] {
      app.get("health", PathComponent(stringLiteral: path)) { _ -> Response in
        let reply = HealthRouter(report: reportProvider()).reply(
          method: "GET", uri: "/health/\(path)")
        return Self.response(reply)
      }
    }
    app.get("api", "system") { _ -> Response in
      let body = try JSONEncoder().encode(SystemStatusResponse(report: reportProvider()))
      return Self.response(HTTPReply(status: 200, body: body))
    }
    keys?.register(app)
    do {
      try await app.asyncBoot()
      try await AdminHTTPIngress(group: group, port: port, app: app, onBound: onBound).run()
    } catch {
      try await app.asyncShutdown()
      throw error
    }
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
