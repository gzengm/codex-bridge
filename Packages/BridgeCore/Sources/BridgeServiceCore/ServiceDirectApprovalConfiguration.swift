import Foundation

public struct ServiceDirectFullAccessScope: Codable, Equatable, Sendable {
  public let projectID: String
  public let root: ServiceRootIdentity

  public init(projectID: String, root: ServiceRootIdentity) {
    self.projectID = projectID
    self.root = root
  }

  public func matches(_ project: ServiceProjectRecord) -> Bool {
    projectID == project.id.rawValue && root == project.root
      && project.accessPolicy.read == .allowed && project.accessPolicy.write == .allowed
      && project.directCommandMode != .denied
  }
}

public struct ServiceDirectApprovalConfiguration: Equatable, Sendable {
  public let mode: ServiceDirectApprovalMode
  public let fullAccessScope: ServiceDirectFullAccessScope?

  public init(
    mode: ServiceDirectApprovalMode,
    fullAccessScope: ServiceDirectFullAccessScope? = nil
  ) {
    self.mode = mode
    self.fullAccessScope = fullAccessScope
  }

  public func hasFullAccess(for project: ServiceProjectRecord) -> Bool {
    mode == .fullAccess && fullAccessScope?.matches(project) == true
  }

  public func commandDeniesNetwork(
    for project: ServiceProjectRecord,
    requiresNetwork: Bool,
    forceIsolation: Bool = false
  ) -> Bool {
    if forceIsolation || project.accessPolicy.network == .denied { return true }
    // 只有显式绑定的项目且网络已允许时，完全访问才使用当前用户的普通进程。
    if hasFullAccess(for: project), project.accessPolicy.network == .allowed { return false }
    return !requiresNetwork
  }
}
