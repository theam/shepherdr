import Foundation
@testable import ShepherdrCore

private final class FixtureBundle {}

enum Fixture {
    static func data(_ name: String = "snapshot") throws -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: FixtureBundle.self)
        #endif
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }
    static func snapshot(machine: Machine = .local) throws -> MachineSnapshot {
        try HerdrJSON.snapshot(data(), machine: machine)
    }
    static let remote = Machine(profileID: "remote-1", name: "Build Studio", target: "builder",
                                session: "agents", isEnabled: true)
}

actor MockHerdrClient: HerdrClient {
    var catalog: Result<[Machine], HerdrFailure> = .success([])
    var responses: [String: Result<MachineSnapshot, HerdrFailure>] = [:]
    var delays: [String: Duration] = [:]
    var calls: [String] = []

    func setCatalog(_ value: Result<[Machine], HerdrFailure>) { catalog = value }
    func set(_ machine: Machine, _ value: Result<MachineSnapshot, HerdrFailure>, delay: Duration = .zero) {
        responses[machine.id] = value
        delays[machine.id] = delay
    }
    var catalogReads = 0
    func machines() async throws -> [Machine] {
        catalogReads += 1
        return try catalog.get()
    }
    func catalogReadCount() -> Int { catalogReads }
    func snapshotCalls() -> [String] { calls }
    /// Answers with the response set when asked, after its delay, as a machine would.
    func snapshot(for machine: Machine) async throws -> MachineSnapshot {
        calls.append(machine.id)
        let response = responses[machine.id] ?? .failure(HerdrFailure(.notRunning, "Not running"))
        if let delay = delays[machine.id], delay > .zero { try await Task.sleep(for: delay) }
        return try response.get()
    }
    func callCount() -> Int { calls.count }

    var changes: [String] = []
    /// Applied to the machine's response when a session is created, as Herdr would.
    var afterCreate: MachineSnapshot?
    func setAfterCreate(_ snapshot: MachineSnapshot) { afterCreate = snapshot }
    func createSession(_ request: NewSessionRequest, on machine: Machine) async throws -> CreatedSession {
        changes.append("create \(machine.id) \(request.name)")
        if let afterCreate { responses[machine.id] = .success(afterCreate) }
        return CreatedSession(workspaceID: "w-new", paneID: "w-new:p1", terminalID: "term-new")
    }
    func closeSession(paneID: String, on machine: Machine) async throws { changes.append("close \(machine.id) \(paneID)") }
    func recordedChanges() -> [String] { changes }

    var shellPIDs: [String: Int] = [:]
    var shellQueries: [String] = []
    func setShellPID(_ pid: Int, for paneID: String) { shellPIDs[paneID] = pid }
    func shellPID(paneID: String, on machine: Machine) async throws -> Int? {
        shellQueries.append(paneID)
        return shellPIDs[paneID]
    }
    func recordedShellQueries() -> [String] { shellQueries }
}

actor RecordingRunner: CommandRunning {
    var outputs: [CommandOutput]
    var arguments: [[String]] = []
    init(_ outputs: [CommandOutput]) { self.outputs = outputs }
    func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> CommandOutput {
        self.arguments.append(arguments)
        return outputs.removeFirst()
    }
    func recordedArguments() -> [[String]] { arguments }
}

func output(_ string: String, stderr: String = "", code: Int32 = 0) -> CommandOutput {
    CommandOutput(stdout: Data(string.utf8), stderr: Data(stderr.utf8), exitCode: code)
}
