import Foundation

public struct ServiceDirectFullAccessScope: Codable, Equatable, Sendable {
  public let projectID: String
  public let root: ServiceRootIdentity
  public let fileWritesAllowed: Bool

  public init(projectID: String, root: ServiceRootIdentity, fileWritesAllowed: Bool = false) {
    self.projectID = projectID
    self.root = root
    self.fileWritesAllowed = fileWritesAllowed
  }

  private enum CodingKeys: String, CodingKey {
    case projectID, root, fileWritesAllowed
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    projectID = try values.decode(String.self, forKey: .projectID)
    root = try values.decode(ServiceRootIdentity.self, forKey: .root)
    // 旧版完全访问只授权命令，不在升级时自动扩大文件权限。
    fileWritesAllowed = try values.decodeIfPresent(Bool.self, forKey: .fileWritesAllowed) ?? false
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

  public func hasFullAccessFileWrites(for project: ServiceProjectRecord) -> Bool {
    hasFullAccess(for: project) && fullAccessScope?.fileWritesAllowed == true
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
