import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeServiceCore
import Foundation
import Testing

@testable import BridgeServiceApplication

@Suite(.serialized)
struct UnattendedFileWriteTests {
  private var deadline: ContinuousClock.Instant { .now.advanced(by: .seconds(10)) }

  private func create(
    _ fixture: FullAccessFixture, path: String = "fixture.txt", projectID: String? = nil,
    requestID: String = "create"
  ) async throws -> MCPDirectWriteReceipt {
    try await fixture.application.serviceDirectWriteFile(
      .init(
        projectID: projectID ?? fixture.first.id.rawValue, relativePath: path, mode: "create",
        content: "before\n", clientRequestID: requestID),
      deadline: deadline)
  }

  @Test func legacyScopeAndIPCDoNotEnableUnattendedWrites() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess()
    let scopeJSON = try #require(await fixture.settings.string(for: .directFullAccessScope))
    var scope = try #require(
      JSONSerialization.jsonObject(with: Data(scopeJSON.utf8)) as? [String: Any])
    scope.removeValue(forKey: "fileWritesAllowed")
    try await fixture.settings.set(
      String(decoding: try JSONSerialization.data(withJSONObject: scope), as: UTF8.self),
      for: .directFullAccessScope)
    let stored = try await ServiceSettings(store: fixture.store).directApprovalConfiguration()
    #expect(stored.hasFullAccess(for: fixture.first))
    #expect(!stored.hasFullAccessFileWrites(for: fixture.first))
    let legacyRequest = try JSONDecoder().decode(
      IPCDirectApprovalModeRequest.self,
      from: Data(#"{"mode":"full-access","projectID":"first","confirmed":true}"#.utf8))
    #expect(legacyRequest.fileWritesConfirmed == nil)
    let legacyResponse = try JSONDecoder().decode(
      IPCDirectApprovalModeResponse.self,
      from: Data(#"{"mode":"full-access","projectID":"first"}"#.utf8))
    #expect(legacyResponse.fileWritesAllowed == nil)
    do {
      _ = try await create(fixture)
      Issue.record("Legacy full access unexpectedly wrote a file")
    } catch BridgeMCPQueryError.approvalRequired {}
    #expect(
      !FileManager.default.fileExists(atPath: fixture.first.root.canonicalPath + "/fixture.txt"))
  }

  @Test func fileOptInRequiresFullScopeConfirmationAndPersists() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    for mode in [ServiceDirectApprovalMode.require, .auto] {
      await #expect(throws: BridgeMCPQueryError.contractRejected) {
        try await fixture.application.serviceSetDirectApprovalMode(
          mode, projectID: fixture.first.id.rawValue, confirmed: true, fileWritesConfirmed: true,
          deadline: deadline)
      }
    }
    await #expect(throws: BridgeMCPQueryError.contractRejected) {
      try await fixture.application.serviceSetDirectApprovalMode(
        .fullAccess, projectID: fixture.first.id.rawValue, fileWritesConfirmed: true,
        deadline: deadline)
    }
    #expect(try await fixture.settings.directApprovalMode() == .require)
    try await fixture.enableFullAccess(fileWrites: true)
    let configuration = try await ServiceSettings(store: fixture.store)
      .directApprovalConfiguration()
    #expect(configuration.hasFullAccessFileWrites(for: fixture.first))
    #expect(!configuration.hasFullAccessFileWrites(for: fixture.second))
    try await fixture.enableFullAccess()
    #expect(
      !(try await fixture.settings.directApprovalConfiguration()).hasFullAccessFileWrites(
        for: fixture.first))
  }

  @Test func createReplaceEditAndPatchWriteWithoutApprovals() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    let created = try await create(fixture)
    let createdHash = try #require(created.newSHA256)
    let replaced = try await fixture.application.serviceDirectWriteFile(
      .init(
        projectID: fixture.first.id.rawValue, relativePath: "fixture.txt", mode: "replace",
        content: "replace\n", expectedSHA256: createdHash,
        clientRequestID: "replace"),
      deadline: deadline)
    let replacedHash = try #require(replaced.newSHA256)
    _ = try await fixture.application.serviceDirectEditFile(
      .init(
        projectID: fixture.first.id.rawValue, relativePath: "fixture.txt",
        expectedSHA256: replacedHash, oldText: "replace", newText: "edited",
        clientRequestID: "edit"),
      deadline: deadline)
    let patch = """
      *** Begin Patch
      *** Update File: fixture.txt
      @@
      -edited
      +patched
      *** Add File: added.txt
      +added
      *** End Patch
      """
    let receipt = try await fixture.application.serviceDirectApplyPatch(
      .init(projectID: fixture.first.id.rawValue, patch: patch, clientRequestID: "patch"),
      deadline: deadline)
    #expect(receipt.operations.count == 2)
    #expect(
      try String(contentsOfFile: fixture.first.root.canonicalPath + "/fixture.txt", encoding: .utf8)
        == "patched\n")
    #expect(
      try String(contentsOfFile: fixture.first.root.canonicalPath + "/added.txt", encoding: .utf8)
        == "added\n")
    #expect(await fixture.application.approvals.pendingApprovals().isEmpty)
  }

  @Test func otherProjectsAndRequireAutoKeepTheirBehavior() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    do {
      _ = try await create(fixture, projectID: fixture.second.id.rawValue, requestID: "other")
      Issue.record("Other project unexpectedly wrote a file")
    } catch BridgeMCPQueryError.approvalRequired {}
    #expect(
      !FileManager.default.fileExists(atPath: fixture.second.root.canonicalPath + "/fixture.txt"))
    await fixture.application.approvals.cancelAll()
    try await fixture.settings.setDirectApprovalMode(.require)
    let request = MCPDirectWriteRequest(
      projectID: fixture.first.id.rawValue, relativePath: "require.txt", mode: "create",
      content: "require\n", clientRequestID: "require")
    var approvalID = ""
    do {
      _ = try await fixture.application.serviceDirectWriteFile(request, deadline: deadline)
      Issue.record("Require mode did not ask")
    } catch BridgeMCPQueryError.approvalRequired(let id) { approvalID = id }
    try #require(await fixture.application.approvals.approve(approvalID: approvalID))
    _ = try await fixture.application.serviceDirectWriteFile(request, deadline: deadline)
    try await fixture.settings.setDirectApprovalMode(.auto)
    _ = try await create(
      fixture, path: "auto.txt", projectID: fixture.second.id.rawValue, requestID: "auto")
    #expect(await fixture.application.approvals.pendingApprovals().isEmpty)
  }

  @Test func explicitDenialSurvivesEnablingUnattendedWrites() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess()
    var approvalID = ""
    do {
      _ = try await create(fixture)
      Issue.record("Legacy write did not ask")
    } catch BridgeMCPQueryError.approvalRequired(let id) { approvalID = id }
    try #require(await fixture.application.approvals.deny(approvalID: approvalID))
    try await fixture.enableFullAccess(fileWrites: true)
    await #expect(throws: BridgeMCPQueryError.approvalDenied) { _ = try await create(fixture) }
    #expect(
      !FileManager.default.fileExists(atPath: fixture.first.root.canonicalPath + "/fixture.txt"))
  }

  @Test func revisionsForbiddenPathsAndPermissionsRemainEnforced() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    let created = try await create(fixture)
    do {
      _ = try await fixture.application.serviceDirectWriteFile(
        .init(
          projectID: fixture.first.id.rawValue, relativePath: "fixture.txt", mode: "replace",
          content: "wrong\n", expectedSHA256: String(repeating: "0", count: 64)),
        deadline: deadline)
      Issue.record("Stale revision replaced a file")
    } catch BridgeMCPQueryError.fileRevisionConflict {}
    #expect(
      try String(contentsOfFile: fixture.first.root.canonicalPath + "/fixture.txt", encoding: .utf8)
        == "before\n")
    #expect(created.newSHA256?.count == 64)
    for path in [
      "../outside.txt", ".env", fixture.root.appendingPathComponent("absolute.txt").path,
    ] {
      await #expect(throws: BridgeMCPQueryError.pathForbidden) {
        _ = try await create(fixture, path: path)
      }
    }
    let projects = ServiceProjectService(store: fixture.store)
    try await projects.updateAccessPolicy(
      .init(read: .allowed, write: .denied, network: .allowed), projectID: fixture.first.id)
    await #expect(throws: BridgeMCPQueryError.writeNotAllowed) {
      _ = try await create(fixture, path: "denied.txt")
    }
    try await projects.updateAccessPolicy(
      .init(read: .allowed, write: .requiresLocalApproval, network: .allowed),
      projectID: fixture.first.id)
    do {
      _ = try await create(fixture, path: "ask.txt")
      Issue.record("Project approval-required permission was bypassed")
    } catch BridgeMCPQueryError.approvalRequired {}
    #expect(!FileManager.default.fileExists(atPath: fixture.first.root.canonicalPath + "/ask.txt"))
  }

  @Test func deleteMoveAndUndoStillRequireApproval() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    let created = try await create(fixture)
    for action in ["delete_file", "move_file"] {
      do {
        _ = try await fixture.application.serviceDirectManagePath(
          .init(
            projectID: fixture.first.id.rawValue, action: action, relativePath: "fixture.txt",
            expectedSHA256: created.newSHA256,
            destinationRelativePath: action == "move_file" ? "moved.txt" : nil,
            sourceExpectedSHA256: created.newSHA256, clientRequestID: action),
          deadline: deadline)
        Issue.record("Destructive path operation did not ask")
      } catch BridgeMCPQueryError.approvalRequired {}
    }
    do {
      _ = try await fixture.application.serviceDirectUndoMutation(
        .init(operationID: try #require(created.operationID), clientRequestID: "undo"),
        deadline: deadline)
      Issue.record("Undo of file creation did not ask")
    } catch BridgeMCPQueryError.approvalRequired {}
    #expect(
      try String(contentsOfFile: fixture.first.root.canonicalPath + "/fixture.txt", encoding: .utf8)
        == "before\n")
    #expect(
      !FileManager.default.fileExists(atPath: fixture.first.root.canonicalPath + "/moved.txt"))
  }

  @Test func previewApplyRechecksFileOptInAndCurrentPolicy() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    let preview = try await fixture.application.serviceDirectPreviewMutation(
      .init(
        projectID: fixture.first.id.rawValue, kind: "write", relativePath: "preview.txt",
        mode: "create", content: "preview\n", clientRequestID: "preview"),
      deadline: deadline)
    try await fixture.enableFullAccess()
    do {
      _ = try await fixture.application.serviceDirectApplyMutation(
        .init(operationID: preview.operationID), deadline: deadline)
      Issue.record("Revoked unattended authorization was reused")
    } catch BridgeMCPQueryError.approvalRequired {}
    #expect(
      !FileManager.default.fileExists(atPath: fixture.first.root.canonicalPath + "/preview.txt"))
    await fixture.application.approvals.cancelAll()
    try await fixture.enableFullAccess(fileWrites: true)
    _ = try await fixture.application.serviceDirectApplyMutation(
      .init(operationID: preview.operationID), deadline: deadline)
    #expect(
      try String(contentsOfFile: fixture.first.root.canonicalPath + "/preview.txt", encoding: .utf8)
        == "preview\n")
  }

  @Test func repositoryMetadataStillRequiresApproval() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    let metadata = URL(fileURLWithPath: fixture.first.root.canonicalPath).appendingPathComponent(
      ".git")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
    do {
      _ = try await create(fixture, path: ".git/config", requestID: "metadata")
      Issue.record("Repository metadata was written without approval")
    } catch BridgeMCPQueryError.approvalRequired {}
    #expect(!FileManager.default.fileExists(atPath: metadata.appendingPathComponent("config").path))
  }

  @Test func directoryLinkCannotEscapeProjectRoot() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess(fileWrites: true)
    let outside = fixture.root.appendingPathComponent("outside")
    let link = URL(fileURLWithPath: fixture.first.root.canonicalPath).appendingPathComponent("jump")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    #if os(Windows)
      let command = Process()
      command.executableURL = URL(
        fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SystemRoot"])
          + "/System32/cmd.exe")
      let firstPath = fixture.first.root.canonicalPath.replacingOccurrences(of: "/", with: "\\")
      let separator = try #require(firstPath.lastIndex(of: "\\"))
      let parent = String(firstPath[..<separator])
      let outputURL = fixture.root.appendingPathComponent("junction-fixture-output.txt")
      try Data().write(to: outputURL)
      let output = try FileHandle(forWritingTo: outputURL)
      command.arguments = ["/d", "/c", "mklink", "/J", firstPath + "\\jump", parent + "\\outside"]
      command.standardOutput = output
      command.standardError = output
      try command.run()
      command.waitUntilExit()
      try output.close()
      if command.terminationStatus != 0 {
        let diagnostic = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        Issue.record("Junction fixture failed: \(diagnostic)")
      }
      try #require(command.terminationStatus == 0)
    #else
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #endif
    await #expect(throws: BridgeMCPQueryError.self) {
      _ = try await create(fixture, path: "jump/escape.txt")
    }
    #expect(
      !FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
  }
}
