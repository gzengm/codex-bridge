import BridgeDomain
import BridgeProcess
import BridgeProjects
import BridgeServiceCore
import Foundation
import Testing

@testable import BridgeDirectCommand

#if os(Windows)
  import WinSDK

  private struct PipeFixture {
    let root: URL
    let node: String

    static func make() async throws -> PipeFixture {
      let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "CodexBridge-PipeRegression-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let projects = ServiceProjectService(store: try SimpleServiceStore.inMemory())
      let project = try await projects.register(
        name: "Pipe regression", rootURL: root,
        accessPolicy: .init(read: .allowed, write: .allowed, network: .allowed))
      let node = try #require(
        DirectCommandPolicy().preferredSystemBuiltInExecutable(
          project: project,
          request: .init(projectID: project.id, commandID: nil, argv: ["node", "--version"])))
      return PipeFixture(root: root, node: node)
    }

    func process(
      _ script: String, readOutput: Bool = false,
      sink: @escaping ManagedStdioProcess.OutputHandler = { _ in }
    ) throws -> ManagedStdioProcess {
      try ManagedStdioProcess(
        argv: [node, "-e", script], workingDirectory: root.path,
        environment: ProcessInfo.processInfo.environment, mergeStandardError: true,
        onStandardOutput: sink, readOutput: readOutput)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
  }

  @Suite(.serialized)
  struct WindowsPipeRegressionTests {
    @Test func emptyLargeAndErrorOutputRemainCompleteAcrossRepeatedExits() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      for (script, expectedCount, expectedCode) in [
        ("process.exit(0)", 0, Int32(0)),
        (
          "process.stdout.write('o'.repeat(65536));process.stderr.write('e'.repeat(32768))", 98304,
          Int32(0)
        ),
        ("process.stderr.write('failure');process.exit(7)", 7, Int32(7)),
      ] {
        for _ in 0..<10 {
          let output = DirectCommandOutputCollector(maximumBytes: 131072)
          let process = try fixture.process(script, readOutput: true, sink: { output.append($0) })
          defer { process.close() }
          try #require(process.waitForExit(timeout: .seconds(5)) == .exited(expectedCode))
          process.drainRemainingOutput(timeout: .seconds(1))
          process.close()
          process.close()
          #expect(output.snapshot().byteCount == expectedCount)
          #expect(!process.isRunning)
        }
      }
    }

    @Test func concurrentDrainAndCloseFinishWithoutDeadlock() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      for _ in 0..<20 {
        let process = try fixture.process(
          "process.stdout.write('x'.repeat(32768))", readOutput: true)
        defer { process.close() }
        try #require(process.waitForExit(timeout: .seconds(5)) == .exited(0))
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
          process.drainRemainingOutput(timeout: .milliseconds(50))
          drained.signal()
        }
        process.close()
        #expect(drained.wait(timeout: .now() + .seconds(2)) == .success)
        #expect(!process.isRunning)
      }
    }

    @Test func queuedDrainCannotReadClosedPipeAfterItsDeadline() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      let process = try fixture.process(
        "const c=require('node:child_process').spawn(process.execPath,"
          + "['-e','setTimeout(()=>{},3000)'],{stdio:['ignore','inherit','inherit']});"
          + "c.unref();process.exit(0)")
      defer {
        _ = process.terminateAndWait()
        process.close()
      }
      try #require(process.waitForExit(timeout: .seconds(5)) == .exited(0))
      let busy = DispatchGroup()
      for _ in 0..<128 {
        busy.enter()
        DispatchQueue.global(qos: .utility).async {
          Thread.sleep(forTimeInterval: 0.2)
          busy.leave()
        }
      }
      process.drainRemainingOutput(timeout: .milliseconds(1))
      process.close()
      #expect(busy.wait(timeout: .now() + .seconds(5)) == .success)
      try await Task.sleep(for: .seconds(1))
      #expect(!process.isRunning)
    }

    @Test func externallyClosedTransportPipeDoesNotAbortDuringDrain() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      let process = try fixture.process("process.exit(0)")
      defer { process.close() }
      try #require(process.waitForExit(timeout: .seconds(5)) == .exited(0))
      try process.standardOutputFileHandle.close()
      process.drainRemainingOutput(timeout: .milliseconds(25))
      process.close()
      try await Task.sleep(for: .milliseconds(50))
      #expect(!process.isRunning)
    }

    @Test func drainDeadlineThenCloseWithInheritedWriterDoesNotAbort() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      let process = try fixture.process(
        "const c=require('node:child_process').spawn(process.execPath,"
          + "['-e','setTimeout(()=>{},3000)'],{stdio:['ignore','inherit','inherit']});"
          + "c.unref();process.exit(0)")
      defer {
        _ = process.terminateAndWait()
        process.close()
      }
      try #require(process.waitForExit(timeout: .seconds(5)) == .exited(0))
      let started = ContinuousClock.now
      process.drainRemainingOutput(timeout: .milliseconds(25))
      #expect(started.duration(to: .now) < .seconds(1))
      process.close()
      try await Task.sleep(for: .milliseconds(150))
      #expect(!process.isRunning)
    }
  }
#endif

private func completedHistorySession(_ id: String, age: TimeInterval) -> DirectCommandSession {
  let ended = Date().addingTimeInterval(-age)
  return DirectCommandSession(
    sessionID: id, projectID: ProjectID(rawValue: "history-fixture"), argv: ["node", "--version"],
    workingDirectory: nil, startedAt: ended.addingTimeInterval(-1), status: "ended", exitCode: 0,
    output: .init(head: "fixture output", tail: "fixture output", byteCount: 14, truncated: false),
    processID: nil, endedAt: ended)
}

@Suite(.serialized)
struct DirectHistoryRegressionTests {
  @Test func cacheExpiryDoesNotDeletePersistentHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexBridge-HistoryRegression-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let history = root.appendingPathComponent("history.json")
    let original = [
      completedHistorySession("historical-first", age: 200),
      completedHistorySession("historical-second", age: 100),
    ]
    DirectCommandSessionHistory.save(original, to: history, maximumCount: 128)
    let manager = DirectCommandSessionManager(completedSessionTTL: .zero, historyFileURL: history)
    #expect(await manager.snapshot(sessionID: "historical-first") == nil)
    let saved = DirectCommandSessionHistory.load(from: history, maximumCount: 128)
    #expect(Set(saved.map(\.sessionID)) == Set(original.map(\.sessionID)))
    #expect(await manager.recentSessions(projectID: nil, limit: 20).count == 2)
    let restarted = DirectCommandSessionManager(historyFileURL: history)
    #expect(await restarted.recentSessions(projectID: nil, limit: 20).count == 2)
  }

  #if os(Windows)
    @Test func cancellationIsPersistedAfterOutputDrainAndRestart() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      let history = fixture.root.appendingPathComponent("history.json")
      let manager = DirectCommandSessionManager(historyFileURL: history)
      let id = "cancelled-fixture"
      let projectID = ProjectID(rawValue: "history-fixture")
      _ = try await manager.launch(
        sessionID: id, projectID: projectID,
        argv: [fixture.node, "-e", "console.log('ready');setInterval(()=>{},1000)"],
        workingDirectory: fixture.root.path, requiresNetwork: false, usePTY: false,
        timeout: .seconds(10))
      let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
      while await manager.snapshot(sessionID: id)?.output.byteCount == 0,
        ContinuousClock.now < readyDeadline
      {
        try await Task.sleep(for: .milliseconds(10))
      }
      try #require(await manager.snapshot(sessionID: id)?.output.head.contains("ready") == true)
      let started = ContinuousClock.now
      await manager.cancelAll()
      #expect(started.duration(to: .now) < .seconds(3))
      #expect(!(await manager.isBusy(projectID: projectID)))
      let restarted = DirectCommandSessionManager(historyFileURL: history)
      let restored = try #require(await restarted.snapshot(sessionID: id))
      #expect(restored.status == "cancelled" && restored.endedAt != nil)
      #expect(restored.output.head.contains("ready"))
      #expect(restored.processID == nil)
    }

    @Test func expiredHistoryMergesWithNewCommandsAndSurvivesRestart() async throws {
      let fixture = try await PipeFixture.make()
      defer { fixture.cleanup() }
      let history = fixture.root.appendingPathComponent("history.json")
      let original = [
        completedHistorySession("historical-first", age: 200),
        completedHistorySession("historical-second", age: 100),
      ]
      DirectCommandSessionHistory.save(original, to: history, maximumCount: 128)
      let manager = DirectCommandSessionManager(
        completedSessionTTL: .milliseconds(30), maximumCompletedSessions: 3, historyFileURL: history
      )
      try await Task.sleep(for: .milliseconds(60))
      #expect(await manager.snapshot(sessionID: "historical-first") == nil)
      for id in ["new-first", "new-second"] {
        _ = try await manager.launch(
          sessionID: id, projectID: ProjectID(rawValue: "history-fixture"),
          argv: [fixture.node, "--version"], workingDirectory: fixture.root.path,
          requiresNetwork: false, usePTY: false, timeout: .seconds(5))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await manager.isBusy(projectID: ProjectID(rawValue: "history-fixture")),
          ContinuousClock.now < deadline
        {
          try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!(await manager.isBusy(projectID: ProjectID(rawValue: "history-fixture"))))
        let saved = DirectCommandSessionHistory.load(from: history, maximumCount: 128)
        #expect(saved.contains { $0.sessionID == "historical-second" })
      }
      let saved = DirectCommandSessionHistory.load(from: history, maximumCount: 128)
      #expect(Set(saved.map(\.sessionID)) == ["historical-second", "new-first", "new-second"])
      #expect(saved.allSatisfy { $0.processID == nil && $0.status != "running" })
      let restarted = DirectCommandSessionManager(historyFileURL: history)
      #expect(await restarted.recentSessions(projectID: nil, limit: 20).count == 3)
      await manager.cancelAll()
      #expect(DirectCommandSessionHistory.load(from: history, maximumCount: 128).count == 3)
    }
  #endif
}
