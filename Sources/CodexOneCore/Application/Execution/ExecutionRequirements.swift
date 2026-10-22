import Foundation

/// Semantic requirements, never derived from a caller's permission claims.
/// The protocol adapter classifies the actual operation; the application and transaction authorize it.
public struct ExecutionRequirements: Sendable, Equatable, Codable {
  public enum Route: String, Sendable, Codable { case conversation, images }
  public let route: Route
  public let visionInput: Bool
  public let imageModel: String?
  /// Pure conversation is the safe interpretation of historical admissions.
  public init() {
    route = .conversation
    visionInput = false
    imageModel = nil
  }
  public init(route: Route, visionInput: Bool = false, imageModel: String? = nil) throws {
    self.route = route
    self.visionInput = visionInput
    self.imageModel = imageModel
    try validate()
  }
  public func validate() throws {
    guard imageModel.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
      route != .images || (imageModel != nil && !visionInput)
    else { throw ExecutionError.invalidCommand }
  }
}
