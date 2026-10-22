import CodexOneCore
import NIOCore
import ServiceLifecycle
import Vapor

public struct AdminService: Service {
  private let group: any EventLoopGroup
  private let port: Int
  private let keys: KeyAdminAPI?
  private let accounts: AccountAdminAPI?
  private let webBundle: AdminWebBundle?
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
    webBundle: AdminWebBundle? = nil, accounts: AccountAdminAPI? = nil,
    onBound: @escaping @Sendable (Int) -> Void = { _ in }
  ) {
    self.accounts = accounts
    self.webBundle = webBundle
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
    if let webBundle {
      app.get { _ -> Response in try Self.assetResponse(webBundle.asset(path: "/")) }
      app.get("index.html") { _ -> Response in
        try Self.assetResponse(webBundle.asset(path: "/index.html"))
      }
      app.get("assets", ":name") { request -> Response in
        try Self.assetResponse(
          webBundle.asset(path: "/assets/" + (request.parameters.get("name") ?? "")))
      }
    }
    keys?.register(app, accounts: accounts)
    do {
      try await app.asyncBoot()
      try await AdminHTTPIngress(
        group: group, port: port, app: app,
        onBound: { boundPort in
          keys?.bind(port: boundPort)
          onBound(boundPort)
        }
      ).run()
    } catch {
      try await app.asyncShutdown()
      throw error
    }
    try await app.asyncShutdown()
  }

  private static func assetResponse(_ asset: AdminWebBundle.Asset?) throws -> Response {
    guard let asset else { throw Abort(.notFound) }
    return Response(
      status: .ok,
      headers: [
        "content-type": asset.contentType, "cache-control": "no-store",
        "x-content-type-options": "nosniff",
        "referrer-policy": "no-referrer", "x-frame-options": "DENY",
        "content-security-policy":
          "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
      ], body: .init(data: asset.data))
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
