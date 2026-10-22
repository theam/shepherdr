import Foundation

/// Domain-facing boundary. A socket client can implement this without changing the store or views.
/// Future event support should subscribe before bootstrapping, and resnapshot after reconnects.
public protocol HerdrClient: Sendable {
    func machines() async throws -> [Machine]
    func snapshot(for machine: Machine) async throws -> MachineSnapshot

    // Explicit, user-initiated changes. Herdr stays the authority; the store refreshes afterwards.
    func createSession(_ request: NewSessionRequest, on machine: Machine) async throws -> CreatedSession
    func closeSession(paneID: String, on machine: Machine) async throws
    func addMachine(_ request: NewMachineRequest) async throws
    func removeMachine(profileID: String) async throws
    func setMachine(profileID: String, enabled: Bool) async throws

    /// The last lines a pane printed, as plain text with wrapped lines joined.
    func recentOutput(paneID: String, on machine: Machine, lines: Int) async throws -> String

    func renameWorkspace(_ workspaceID: String, to name: String, on machine: Machine) async throws

    /// The checkouts of the repository a workspace works in, by the workspace that has each open;
    /// empty outside a Git repository.
    func checkouts(around workspaceID: String, on machine: Machine) async throws -> [String: WorkspaceCheckout]

    /// The process ID of the shell a pane started with, under which its agent runs.
    func shellPID(paneID: String, on machine: Machine) async throws -> Int?

    /// Whether a pane's shell runs a command in the foreground, such as a script, rather than
    /// waiting at its prompt; nil when Herdr doesn't say.
    func runsCommand(paneID: String, on machine: Machine) async throws -> Bool?

    /// Sets and clears Shepherdr's own tokens on a pane, at most 16 in one go; Herdr keeps 80
    /// characters of each value.
    func reportTokens(paneID: String, set: [String: String], clear: [String], on machine: Machine) async throws

    /// Submits a prompt to the agent in a pane, as typing it and pressing Return would.
    func prompt(paneID: String, text: String, on machine: Machine) async throws

    /// Starts an agent in an existing pane and waits until it's ready. Returns a notice when it
    /// stopped at a startup question, such as trusting the folder.
    func startAgent(_ name: String, kind: String, paneID: String, on machine: Machine) async throws -> String?
}

extension HerdrClient {
    private var unsupported: HerdrFailure { HerdrFailure(.incompatible, "This Herdr client cannot change sessions or machines.") }
    public func createSession(_ request: NewSessionRequest, on machine: Machine) async throws -> CreatedSession { throw unsupported }
    public func closeSession(paneID: String, on machine: Machine) async throws { throw unsupported }
    public func addMachine(_ request: NewMachineRequest) async throws { throw unsupported }
    public func removeMachine(profileID: String) async throws { throw unsupported }
    public func setMachine(profileID: String, enabled: Bool) async throws { throw unsupported }
    public func recentOutput(paneID: String, on machine: Machine, lines: Int) async throws -> String { throw unsupported }
    public func renameWorkspace(_ workspaceID: String, to name: String, on machine: Machine) async throws { throw unsupported }
    public func checkouts(around workspaceID: String, on machine: Machine) async throws -> [String: WorkspaceCheckout] { throw unsupported }
    public func shellPID(paneID: String, on machine: Machine) async throws -> Int? { throw unsupported }
    public func runsCommand(paneID: String, on machine: Machine) async throws -> Bool? { throw unsupported }
    public func reportTokens(paneID: String, set: [String: String], clear: [String], on machine: Machine) async throws { throw unsupported }
    public func prompt(paneID: String, text: String, on machine: Machine) async throws { throw unsupported }
    public func startAgent(_ name: String, kind: String, paneID: String, on machine: Machine) async throws -> String? { throw unsupported }
}

public struct ExecutableLocator: Sendable {
    public init() {}

    public func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                       home: String = NSHomeDirectory()) throws -> URL {
        if let explicit = environment["SHEPHERDR_HERDR_PATH"], !explicit.isEmpty {
            guard explicit.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: explicit) else {
                throw HerdrFailure(.notInstalled, "The configured Herdr executable is unavailable.", detail: explicit)
            }
            return URL(fileURLWithPath: explicit)
        }
        // Finder-launched applications have a minimal PATH. Do not source shell startup files.
        let directories = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"]
            + (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in directories where directory.hasPrefix("/") {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("herdr")
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw HerdrFailure(.notInstalled, "Install Herdr, then refresh.",
                           detail: "Shepherdr checks Homebrew, ~/.local/bin, ~/.cargo/bin and PATH. A custom location can be set with SHEPHERDR_HERDR_PATH.")
    }
}
