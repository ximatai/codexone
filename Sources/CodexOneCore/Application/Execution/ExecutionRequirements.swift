import Foundation

/// Semantic requirements, never derived from a caller's permission claims.
/// The protocol adapter classifies the actual operation; the application and transaction authorize it.
public struct ExecutionRequirements: Sendable, Equatable, Codable {
  public enum Route: String, Sendable, Codable { case conversation, images }
  public let route: Route
  public let visionInput: Bool
  public let imageModel: String?
  /// Trusted, verified image capability scope; absent for historical admissions.
  public let imageAccountIDs: Set<String>?
  /// Pure conversation is the safe interpretation of historical admissions.
  public init() {
    route = .conversation
    visionInput = false
    imageModel = nil
    imageAccountIDs = nil
  }
  public init(
    route: Route, visionInput: Bool = false, imageModel: String? = nil,
    imageAccountIDs: Set<String>? = nil
  ) throws {
    self.route = route
    self.visionInput = visionInput
    self.imageModel = imageModel
    self.imageAccountIDs = imageAccountIDs
    try validate()
  }
  public func validate() throws {
    guard imageModel.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.utf8.contains(0) }) ?? true,
      route != .images || (imageModel != nil && !visionInput),
      imageAccountIDs.map({ ids in
        route == .images && (1...64).contains(ids.count)
          && ids.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) }
      }) ?? true
    else { throw ExecutionError.invalidCommand }
  }
  public func allowsImageAccount(_ id: String) -> Bool { imageAccountIDs?.contains(id) ?? true }
}
