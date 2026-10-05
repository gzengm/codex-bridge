import BridgeCodexRPC
import BridgeCodexService
import BridgeDesktopUI
import BridgeDirectCommand
import BridgeDomain
import BridgeIPC
import BridgeMCP
import BridgeProjects
import BridgeServiceCore
import Foundation
import Testing

@testable import BridgeServiceApplication

#if os(Windows)
  import WinSDK
#endif

struct FullAccessFixture {
  let root: URL
  let store: SimpleServiceStore
  let settings: ServiceSettings
  let application: BridgeServiceApplication
  let first: ServiceProjectRecord
  let second: ServiceProjectRecord

  static func make() async throws -> FullAccessFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexBridge-FullAccessTests-" + UUID().uuidString)
    let firstRoot = root.appendingPathComponent("first")
    let secondRoot = root.appendingPathComponent("second")
    try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
    let store = try SimpleServiceStore.inMemory()
    let projects = ServiceProjectService(store: store)
    let policy = ProjectAccessPolicy(read: .allowed, write: .allowed, network: .allowed)
    let first = try await projects.register(
      name: "First fixture", rootURL: firstRoot, accessPolicy: policy)
    let second = try await projects.register(
      name: "Second fixture", rootURL: secondRoot, accessPolicy: policy)
    let tasks = ServiceTaskManager(store: store)
    let settings = ServiceSettings(store: store)
    let info = CodexClientInfo(name: "direct-full-access-tests", title: nil, version: "test")
    let execution = ExecutionManager(configuration: .init(clientInfo: info))
    let coordinator = ServiceExecutionCoordinator(
      tasks: tasks, projects: projects, execution: execution)
    let application = BridgeServiceApplication(
      appVersion: "test", projects: projects, tasks: tasks, settings: settings,
      coordinator: coordinator,
      catalog: ServiceCodexCatalog(configuration: .init(clientInfo: info)),
      runtimeStatus: ServiceRuntimeStatus())
    return FullAccessFixture(
      root: root, store: store, settings: settings, application: application,
      first: first, second: second)
  }

  func enableFullAccess(fileWrites: Bool = false) async throws {
    try await application.serviceSetDirectApprovalMode(
      .fullAccess, projectID: first.id.rawValue, confirmed: true, fileWritesConfirmed: fileWrites,
      deadline: ContinuousClock.now.advanced(by: .seconds(10)))
  }

  func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private func approvalRequired(
  _ application: BridgeServiceApplication, project: ServiceProjectRecord,
  kind: DirectApprovalKind = .command, eligible: Bool = true, requestID: String = "test"
) async throws -> String {
  do {
    _ = try await application.requireDirectApproval(
      project: project, kind: kind, summary: "Fixture action", payload: ["fixture": requestID],
      clientRequestID: requestID, fullAccessEligible: eligible)
    Issue.record("Expected an approval request")
    return ""
  } catch BridgeMCPQueryError.approvalRequired(let id) {
    return id
  }
}

#if os(Windows)
  private func windowsTestExecutable(_ name: String, project: ServiceProjectRecord) throws -> String
  {
    try #require(
      DirectCommandPolicy().preferredSystemBuiltInExecutable(
        project: project,
        request: .init(projectID: project.id, commandID: nil, argv: [name, "--version"])))
  }

  private func finishedSession(_ manager: DirectCommandSessionManager, id: String) async throws
    -> DirectCommandSession
  {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while await manager.snapshot(sessionID: id)?.status == "running", ContinuousClock.now < deadline
    {
      try await Task.sleep(for: .milliseconds(25))
    }
    let session = try #require(await manager.snapshot(sessionID: id))
    try #require(session.status != "running")
    return session
  }

  private func processHandleCount() throws -> DWORD {
    var count: DWORD = 0
    try #require(GetProcessHandleCount(GetCurrentProcess(), &count))
    return count
  }
#endif

@Suite(.serialized)
struct DirectFullAccessTests {
  @Test func labelsAndLegacyIPC() throws {
    #expect(
      ServiceDirectApprovalMode.allCases.map(\.rawValue) == ["require", "auto", "full-access"])
    #expect(BridgeDesktopPresentation.approvalModeTitle("require") == "每次询问")
    #expect(BridgeDesktopPresentation.approvalModeTitle("auto") == "自动")
    #expect(BridgeDesktopPresentation.approvalModeTitle("full-access") == "完全访问")
    #expect(ServiceTaskStartApprovalMode.allCases.map(\.rawValue) == ["require", "auto"])
    let legacy = try JSONDecoder().decode(
      IPCDirectApprovalModeRequest.self, from: Data(#"{"mode":"auto"}"#.utf8))
    #expect(legacy.mode == "auto" && legacy.projectID == nil && legacy.confirmed == nil)
    let full = IPCDirectApprovalModeRequest(
      mode: "full-access", projectID: "fixture", confirmed: true)
    #expect(
      try JSONDecoder().decode(IPCDirectApprovalModeRequest.self, from: JSONEncoder().encode(full))
        == full)
  }

  @Test func defaultsAndLegacyAutoAreUnchanged() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    #expect(try await fixture.settings.directApprovalMode() == .require)
    #expect(try await fixture.settings.taskStartApprovalMode() == .require)
    try await fixture.settings.set("auto", for: .directApprovalMode)
    let configuration = try await fixture.settings.directApprovalConfiguration()
    #expect(configuration.mode == .auto && configuration.fullAccessScope == nil)
    #expect(configuration.commandDeniesNetwork(for: fixture.first, requiresNetwork: false))
    #expect(!configuration.commandDeniesNetwork(for: fixture.first, requiresNetwork: true))
    #expect(try await fixture.settings.taskStartApprovalMode() == .require)
  }

  @Test func optInRequiresConfirmationAndProjectAndPersists() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    await #expect(throws: BridgeMCPQueryError.contractRejected) {
      try await fixture.application.serviceSetDirectApprovalMode(
        .fullAccess, deadline: ContinuousClock.now.advanced(by: .seconds(5)))
    }
    await #expect(throws: ServiceStoreError.self) {
      try await fixture.settings.setDirectApprovalMode(
        .fullAccess, fullAccessProject: fixture.first)
    }
    #expect(try await fixture.settings.directApprovalMode() == .require)
    try await fixture.enableFullAccess()
    let persisted = try await ServiceSettings(store: fixture.store).directApprovalConfiguration()
    #expect(persisted.hasFullAccess(for: fixture.first))
    #expect(!persisted.hasFullAccess(for: fixture.second))
    #expect(!persisted.commandDeniesNetwork(for: fixture.first, requiresNetwork: false))
    #expect(persisted.commandDeniesNetwork(for: fixture.second, requiresNetwork: false))
    #expect(
      persisted.commandDeniesNetwork(
        for: fixture.first, requiresNetwork: false, forceIsolation: true))
    try await fixture.settings.setDirectApprovalMode(.require)
    let revoked = try await fixture.settings.directApprovalConfiguration()
    #expect(revoked.mode == .require && revoked.fullAccessScope == nil)
    #expect(try await fixture.settings.string(for: .directFullAccessScope) == nil)
  }

  @Test func corruptFullAccessAndChangedIdentityFailClosed() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.settings.set("full-access", for: .directApprovalMode)
    await #expect(throws: ServiceStoreError.corruptRecord) {
      _ = try await fixture.settings.directApprovalConfiguration()
    }
    try await fixture.settings.setDirectApprovalMode(.require)
    try await fixture.enableFullAccess()
    let changed = try ServiceRootIdentity(
      canonicalPath: fixture.first.root.canonicalPath, device: fixture.first.root.device,
      inode: fixture.first.root.inode + 1)
    let changedProject = try ServiceProjectRecord(
      id: fixture.first.id, name: fixture.first.name, root: changed,
      accessPolicy: fixture.first.accessPolicy, createdAt: fixture.first.createdAt,
      updatedAt: fixture.first.updatedAt)
    #expect(
      !(try await fixture.settings.directApprovalConfiguration()).hasFullAccess(for: changedProject)
    )
  }

  @Test func deniedAndApprovalRequiredProjectPoliciesRemainEffective() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.enableFullAccess()
    for permission in [ProjectPermission.denied, .requiresLocalApproval] {
      let restricted = try fixture.first.updatingAccessPolicy(
        .init(read: .allowed, write: permission, network: .allowed), at: fixture.first.updatedAt)
      #expect(
        !(try await fixture.settings.directApprovalConfiguration()).hasFullAccess(for: restricted))
      await #expect(throws: ServiceStoreError.self) {
        try await fixture.settings.setDirectApprovalMode(
          .fullAccess, fullAccessProject: restricted, confirmed: true)
      }
    }
    let deniedNetwork = try fixture.first.updatingAccessPolicy(
      .init(read: .allowed, write: .allowed, network: .denied), at: fixture.first.updatedAt)
    let configuration = try await fixture.settings.directApprovalConfiguration()
    #expect(configuration.commandDeniesNetwork(for: deniedNetwork, requiresNetwork: false))
    #expect(configuration.commandDeniesNetwork(for: deniedNetwork, requiresNetwork: true))
  }

  @Test func requireAllowsOnceDeniesAndCancels() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    let id = try await approvalRequired(fixture.application, project: fixture.first)
    #expect(await fixture.application.approvals.approve(approvalID: id))
    let approved = try await fixture.application.requireDirectApproval(
      project: fixture.first, kind: .command, summary: "Fixture action",
      payload: ["fixture": "test"],
      clientRequestID: "test", fullAccessEligible: true)
    #expect(!approved)
    let retry = try await approvalRequired(fixture.application, project: fixture.first)
    #expect(await fixture.application.approvals.deny(approvalID: retry))
    try await fixture.enableFullAccess()
    await #expect(throws: BridgeMCPQueryError.approvalDenied) {
      _ = try await fixture.application.requireDirectApproval(
        project: fixture.first, kind: .command, summary: "Fixture action",
        payload: ["fixture": "test"],
        clientRequestID: "test", fullAccessEligible: true)
    }
    await fixture.application.approvals.cancelAll()
    #expect(await fixture.application.approvals.pendingApprovals().isEmpty)
    #expect(!(await fixture.application.approvals.approve(approvalID: retry)))
  }

  @Test func autoKeepsItsBehaviorAndFullAccessIsLimitedToCommands() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    try await fixture.settings.setDirectApprovalMode(.auto)
    _ = try await fixture.application.requireDirectApproval(
      project: fixture.second, kind: .fileWrite, summary: "Fixture", payload: ["fixture": "auto"],
      clientRequestID: "auto")
    #expect(await fixture.application.approvals.pendingApprovals().isEmpty)
    try await fixture.enableFullAccess()
    #expect(
      try await fixture.application.requireDirectApproval(
        project: fixture.first, kind: .command, summary: "Fixture", payload: ["fixture": "full"],
        clientRequestID: "full", fullAccessEligible: true))
    _ = try await approvalRequired(fixture.application, project: fixture.second, requestID: "other")
    _ = try await approvalRequired(
      fixture.application, project: fixture.first, kind: .fileWrite, requestID: "write")
    _ = try await approvalRequired(
      fixture.application, project: fixture.first, kind: .pathAction, requestID: "path")
    _ = try await approvalRequired(
      fixture.application, project: fixture.first, eligible: false, requestID: "risky")
    #expect(await fixture.application.approvals.pendingApprovals().count == 4)
  }

  #if os(Windows)
    @Test func windowsIsolatedNodeAndGitOnSmallFixture() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      let node = try windowsTestExecutable("node", project: fixture.first)
      let git = try windowsTestExecutable("git", project: fixture.first)
      for executable in [node, git] {
        let output = DirectCommandOutputCollector(maximumBytes: 4096)
        let start = ContinuousClock.now
        let process = try DirectProcessLifetime(
          argv: [executable, "--version"], workingDirectory: fixture.first.root.canonicalPath,
          environment: nil, usePTY: false, output: output, denyNetwork: true)
        let result = await DirectCommandRunner(defaultTimeout: .seconds(5)).monitor(
          process: process, sessionID: "isolated-version", output: output)
        #expect(result.termination == .exited(0))
        #expect(result.output.byteCount > 0)
        #expect(!result.timedOut)
        #expect(start.duration(to: .now) < .seconds(10))
      }
    }

    @Test func windowsFullAccessNodeAndGitThroughServiceAndProjectBoundary() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      try await fixture.enableFullAccess()
      for argv in [["node", "--version"], ["git", "--version"]] {
        for _ in 0..<3 {
          let receipt = try await fixture.application.serviceDirectExecCommand(
            .init(
              projectID: fixture.first.id.rawValue, argv: argv, yieldTimeMS: 1000, timeoutMS: 5000),
            deadline: ContinuousClock.now.advanced(by: .seconds(10)))
          let manager = await fixture.application.directCommands
          let session = try await finishedSession(manager, id: receipt.sessionID)
          #expect(session.exitCode == 0)
          #expect(session.output.byteCount > 0)
          #expect(session.executionEnvironment.childNetworkPolicy == "inherited")
          #expect(!(await fixture.application.directCommands.isBusy(projectID: fixture.first.id)))
        }
      }
      await #expect(throws: BridgeMCPQueryError.self) {
        _ = try await fixture.application.serviceDirectExecCommand(
          .init(projectID: fixture.second.id.rawValue, argv: ["node", "--version"]),
          deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      }
      await #expect(throws: BridgeMCPQueryError.self) {
        _ = try await fixture.application.serviceDirectExecCommand(
          .init(
            projectID: fixture.first.id.rawValue, argv: ["node", "--version"],
            workingDirectory: ".."),
          deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      }
      await #expect(throws: BridgeMCPQueryError.projectNotFound) {
        _ = try await fixture.application.serviceDirectExecCommand(
          .init(projectID: "unapproved-fixture", argv: ["node", "--version"]),
          deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      }
    }

    @Test func windowsFullAccessRepeatedGitNodeCommandsRemainResponsive() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      try await fixture.enableFullAccess()
      let manager = await fixture.application.directCommands
      let baseline = try processHandleCount()
      for _ in 0..<25 {
        for executable in ["git", "node"] {
          let receipt = try await fixture.application.serviceDirectExecCommand(
            .init(
              projectID: fixture.first.id.rawValue, argv: [executable, "--version"],
              yieldTimeMS: 1000, timeoutMS: 5000),
            deadline: ContinuousClock.now.advanced(by: .seconds(10)))
          let session = try await finishedSession(manager, id: receipt.sessionID)
          #expect(session.exitCode == 0 && session.output.byteCount > 0 && !session.timedOut)
          #expect(session.executionEnvironment.childNetworkPolicy == "inherited")
          #expect(!(await manager.isBusy(projectID: fixture.first.id)))
        }
      }
      #expect(try processHandleCount() <= baseline + 12)
    }

    @Test func windowsRequireAutoAndFullAccessNetworkDenialThroughService() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      let manager = await fixture.application.directCommands
      let request = MCPDirectExecRequest(
        projectID: fixture.first.id.rawValue, argv: ["node", "--version"],
        yieldTimeMS: 1000, timeoutMS: 5000)
      var approvalID = ""
      do {
        _ = try await fixture.application.serviceDirectExecCommand(
          request, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        Issue.record("每次询问未创建审批")
      } catch BridgeMCPQueryError.approvalRequired(let id) { approvalID = id }
      try #require(await fixture.application.approvals.approve(approvalID: approvalID))
      let approved = try await fixture.application.serviceDirectExecCommand(
        request, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      let approvedSession = try await finishedSession(manager, id: approved.sessionID)
      #expect(approvedSession.exitCode == 0)
      #expect(approvedSession.executionEnvironment.childNetworkPolicy == "denied")
      try await fixture.settings.setDirectApprovalMode(.auto)
      let automatic = try await fixture.application.serviceDirectExecCommand(
        request, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      let automaticSession = try await finishedSession(manager, id: automatic.sessionID)
      #expect(automaticSession.exitCode == 0)
      #expect(automaticSession.executionEnvironment.childNetworkPolicy == "denied")
      try await fixture.enableFullAccess()
      let projects = ServiceProjectService(store: fixture.store)
      try await projects.updateAccessPolicy(
        .init(read: .allowed, write: .allowed, network: .denied), projectID: fixture.first.id)
      let isolated = try await fixture.application.serviceDirectExecCommand(
        request, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      let isolatedSession = try await finishedSession(manager, id: isolated.sessionID)
      #expect(isolatedSession.exitCode == 0)
      #expect(isolatedSession.executionEnvironment.childNetworkPolicy == "denied")
      try await projects.updateAccessPolicy(
        .init(read: .allowed, write: .denied, network: .allowed), projectID: fixture.first.id)
      await #expect(throws: BridgeMCPQueryError.writeNotAllowed) {
        _ = try await fixture.application.serviceDirectExecCommand(
          request, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      }
      #expect(!(await manager.isBusy(projectID: fixture.first.id)))
    }

    @Test func windowsGitRevParseInsideIndependentRepository() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      let git = try windowsTestExecutable("git", project: fixture.first)
      let output = DirectCommandOutputCollector(maximumBytes: 4096)
      let setup = try DirectProcessLifetime(
        argv: [git, "init", "--template="], workingDirectory: fixture.first.root.canonicalPath,
        environment: nil, usePTY: false, output: output, denyNetwork: false)
      let setupResult = await DirectCommandRunner(defaultTimeout: .seconds(5)).monitor(
        process: setup, sessionID: "fixture-git-init", output: output)
      try #require(setupResult.termination == .exited(0))
      try await fixture.enableFullAccess()
      let request = MCPDirectExecRequest(
        projectID: fixture.first.id.rawValue, argv: ["git", "rev-parse", "--show-toplevel"],
        yieldTimeMS: 1000, timeoutMS: 5000)
      let receipt = try await fixture.application.serviceDirectExecCommand(
        request, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
      let manager = await fixture.application.directCommands
      let session = try await finishedSession(manager, id: receipt.sessionID)
      #expect(session.exitCode == 0)
      #expect(
        session.output.head.localizedCaseInsensitiveContains(
          fixture.first.root.canonicalPath.replacingOccurrences(of: "\\", with: "/")))
      #expect(!(await manager.isBusy(projectID: fixture.first.id)))
    }

    @Test func windowsCancellationStopsChildrenAndHandlesStayBounded() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      let node = try windowsTestExecutable("node", project: fixture.first)
      let manager = await fixture.application.directCommands
      let baseline = try processHandleCount()
      for _ in 0..<10 {
        let id = UUID().uuidString
        _ = try await manager.launch(
          sessionID: id, projectID: fixture.first.id, argv: [node, "--version"],
          workingDirectory: fixture.first.root.canonicalPath, requiresNetwork: false,
          usePTY: false, timeout: .seconds(5))
        let session = try await finishedSession(manager, id: id)
        #expect(session.exitCode == 0 && session.output.byteCount > 0)
      }
      #expect(try processHandleCount() <= baseline + 8)
      let id = UUID().uuidString
      _ = try await manager.launch(
        sessionID: id, projectID: fixture.first.id,
        argv: [
          node, "-e",
          "const c=require('node:child_process').spawn(process.execPath,['-e','setInterval(()=>{},1000)'],{stdio:'ignore'}); console.log(c.pid); setInterval(()=>{},1000)",
        ],
        workingDirectory: fixture.first.root.canonicalPath, requiresNetwork: false,
        usePTY: false, timeout: .seconds(10))
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      var childID: DWORD?
      while childID == nil, ContinuousClock.now < deadline {
        let snapshot = await manager.snapshot(sessionID: id)
        childID = snapshot.flatMap {
          DWORD($0.output.head.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if childID == nil { try await Task.sleep(for: .milliseconds(25)) }
      }
      let pid = try #require(childID)
      let child = try #require(OpenProcess(DWORD(SYNCHRONIZE), false, pid))
      defer { _ = CloseHandle(child) }
      await manager.cancelAll()
      #expect(WaitForSingleObject(child, 2000) == DWORD(WAIT_OBJECT_0))
      #expect(!(await manager.isBusy(projectID: fixture.first.id)))
    }

    @Test func windowsErrorsTimeoutStopAndRepeatedRunsReleaseResources() async throws {
      let fixture = try await FullAccessFixture.make()
      defer { fixture.cleanup() }
      let node = try windowsTestExecutable("node", project: fixture.first)
      let manager = await fixture.application.directCommands
      for (script, timeout, expectedCode) in [
        ("process.exit(7)", Duration.seconds(5), Int32(7)),
        ("setInterval(() => {}, 1000)", Duration.milliseconds(150), Int32(-1)),
      ] {
        let id = UUID().uuidString
        _ = try await manager.launch(
          sessionID: id, projectID: fixture.first.id, argv: [node, "-e", script],
          workingDirectory: fixture.first.root.canonicalPath, requiresNetwork: false,
          usePTY: false, timeout: timeout, denyNetwork: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await manager.snapshot(sessionID: id)?.status == "running",
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(25))
        }
        let session = await manager.snapshot(sessionID: id)
        #expect(session?.status != "running")
        if expectedCode >= 0 {
          #expect(session?.exitCode == expectedCode)
        } else {
          #expect(session?.timedOut == true)
        }
        #expect(!(await manager.isBusy(projectID: fixture.first.id)))
      }
      let id = UUID().uuidString
      _ = try await manager.launch(
        sessionID: id, projectID: fixture.first.id,
        argv: [node, "-e", "setInterval(() => {}, 1000)"],
        workingDirectory: fixture.first.root.canonicalPath, requiresNetwork: false,
        usePTY: false, timeout: .seconds(10))
      try await manager.interrupt(sessionID: id)
      let stopped = try await finishedSession(manager, id: id)
      #expect(stopped.status != "running")
      #expect(!(await manager.isBusy(projectID: fixture.first.id)))
      await manager.cancelAll()
      #expect(!(await manager.isBusy(projectID: fixture.first.id)))
    }
  #endif

  @Test func commandPolicyPreservesDenialsAndElevatedApproval() async throws {
    let fixture = try await FullAccessFixture.make()
    defer { fixture.cleanup() }
    let command = try ServiceWorkspaceCommand(
      id: "fixture-command", name: "Fixture", executable: "fixture.exe", arguments: [],
      risk: .elevated)
    let project = try fixture.first.updatingWorkspaceConfiguration(
      directCommandMode: .full, workspaceCommands: [command], commandBlacklist: [],
      at: fixture.first.updatedAt)
    let request = DirectCommandRequest(projectID: project.id, commandID: command.id, argv: [])
    let resolution = DirectCommandPolicy().resolve(project: project, request: request)
    #expect(resolution.allowed && resolution.requiresApproval && !resolution.fullAccessEligible)
    let unknown = DirectCommandPolicy().resolve(
      project: project,
      request: .init(projectID: project.id, commandID: nil, argv: ["unregistered.exe"]))
    #expect(unknown.allowed && !unknown.fullAccessEligible)
    let denied = try project.updatingWorkspaceConfiguration(
      directCommandMode: .full, workspaceCommands: [command],
      commandBlacklist: [.init(id: "deny-fixture", executable: "fixture.exe")],
      at: project.updatedAt)
    #expect(DirectCommandPolicy().resolve(project: denied, request: request).reason == .blacklisted)
  }
}
