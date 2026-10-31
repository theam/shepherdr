import Foundation

public struct CLIHerdrClient: HerdrClient, HerdrTerminalClient {
    private let runner: any CommandRunning
    private let executable: URL?
    private let timeout: TimeInterval

    public init(executable: URL? = nil, timeout: TimeInterval = 12) {
        self.init(runner: ProcessRunner(), executable: executable, timeout: timeout)
    }

    init(runner: any CommandRunning, executable: URL? = nil, timeout: TimeInterval = 12) {
        self.runner = runner
        self.executable = executable
        self.timeout = timeout
    }

    public func machines() async throws -> [Machine] {
        let output = try await execute(["machine", "list", "--json"])
        try validate(output, machine: .local)
        do { return try HerdrJSON.machines(output.stdout) }
        catch { throw decodingFailure(error) }
    }

    public func connect(to target: TerminalTarget, mode: TerminalMode, size: TerminalSize) async throws -> any HerdrTerminalConnection {
        let command = try TerminalCommand.make(target: target, mode: mode, size: size, executable: executable)
        return try await CLITerminalConnection.start(command: command, mode: mode)
    }

    public func linesBack(in target: TerminalTarget) async throws -> Int? {
        let prefix = target.machine.profileID.map { ["--machine", $0] } ?? []
        let output = try await execute(prefix + ["pane", "list"])
        try validate(output, machine: target.machine)
        do { return try HerdrJSON.linesBack(output.stdout, terminalID: target.terminalID) }
        catch { throw decodingFailure(error) }
    }

    public func snapshot(for machine: Machine) async throws -> MachineSnapshot {
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let output = try await execute(prefix + ["api", "snapshot"])
        do { try validate(output, machine: machine) }
        catch let failure as HerdrFailure {
            // Some older CLIs emit an OS error for a missing socket. Prefer the supported
            // JSON status query over inferring server state from that human diagnostic.
            if machine.isLocal, failure.state == .unreachable,
               let statusOutput = try? await execute(["status", "server", "--json"]),
               statusOutput.exitCode == 0,
               let status = try? HerdrJSON.decoder().decode(ServerStatusDTO.self, from: statusOutput.stdout) {
                if !status.running {
                    throw HerdrFailure(.notRunning, "Start Herdr on this machine, then refresh.")
                }
                if status.compatible == false {
                    throw HerdrFailure(.incompatible, "The Herdr CLI and running server use different protocols.",
                                       detail: "Check `herdr status --json` and resolve the mismatch in Herdr.")
                }
            }
            throw failure
        }
        do { return try HerdrJSON.snapshot(output.stdout, machine: machine) }
        catch { throw decodingFailure(error) }
    }

    // MARK: Session and machine changes

    public func createSession(_ request: NewSessionRequest, on machine: Machine) async throws -> CreatedSession {
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = request.directory.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireArgument(name, "session name")
        try requireArgument(directory, "directory")
        if let kind = request.agentKind { try requireArgument(kind, "agent") }
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        var session: CreatedSession
        if let worktree = request.worktree {
            session = try await openWorktree(worktree, of: directory, name: name, on: machine)
            // Its agent, if any, is already there.
            if session.isExisting { return session }
        } else {
            let output = try await execute(prefix + ["workspace", "create", "--cwd", directory, "--label", name, "--no-focus"],
                                           timeout: max(timeout, 30))
            session = try created(from: output, on: machine)
        }
        guard let kind = request.agentKind else { return session }
        // Herdr waits until the agent is ready for prompts, which can take a while on first launch.
        let started = try await execute(prefix + ["agent", "start", name, "--kind", kind, "--pane", session.paneID,
                                                  "--timeout", "60000"], timeout: 75)
        do { try validate(started, machine: machine) }
        catch let failure as HerdrFailure {
            // The workspace exists either way. An agent asking a startup question (such as trusting
            // the folder) is waiting for the user, not broken.
            let waiting = failure.detail == "Herdr error: agent_not_ready"
            session = CreatedSession(workspaceID: session.workspaceID, paneID: session.paneID, terminalID: session.terminalID,
                                     notice: waiting ? "\(kind) is waiting for you to answer a startup question."
                                                     : "The workspace was created, but \(kind) did not start: \(failure.message)")
        }
        return session
    }

    /// The branch's worktree in a workspace: the one Herdr has open, an existing checkout opened, or a
    /// new one Herdr creates in its worktrees folder, grouped with the repository's workspace.
    private func openWorktree(_ worktree: NewSessionRequest.Worktree, of repository: String, name: String,
                              on machine: Machine) async throws -> CreatedSession {
        try requireArgument(worktree.branch, "branch")
        if let base = worktree.base { try requireArgument(base, "base") }
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let open = try await execute(prefix + ["worktree", "open", "--cwd", repository, "--branch", worktree.branch,
                                                "--label", name, "--no-focus"], timeout: max(timeout, 30))
        do {
            return try created(from: open, on: machine)
        } catch let failure as HerdrFailure where failure.detail == "Herdr error: worktree_not_found" {
            let base = worktree.base.map { ["--base", $0] } ?? []
            // Git checks out a whole tree, which can take a while in a large repository.
            let output = try await execute(prefix + ["worktree", "create", "--cwd", repository, "--branch", worktree.branch]
                                           + base + ["--label", name, "--no-focus"], timeout: max(timeout, 120))
            return try created(from: output, on: machine)
        }
    }

    /// The workspace and root pane `workspace create` or `worktree create`/`open` answered with.
    private func created(from output: CommandOutput, on machine: Machine) throws -> CreatedSession {
        try validate(output, machine: machine)
        let created: WorkspaceCreatedDTO.Result
        do { created = try HerdrJSON.decoder().decode(WorkspaceCreatedDTO.self, from: output.stdout).result }
        catch { throw decodingFailure(error) }
        return CreatedSession(workspaceID: created.workspace.workspaceId, paneID: created.rootPane.paneId,
                              terminalID: created.rootPane.terminalId, isExisting: created.alreadyOpen == true)
    }

    public func closeSession(paneID: String, on machine: Machine) async throws {
        try requireArgument(paneID, "pane")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        try validate(try await execute(prefix + ["pane", "close", paneID]), machine: machine)
    }

    public func splitPane(_ paneID: String, _ direction: SplitDirection, directory: String?, on machine: Machine) async throws -> String {
        try requireArgument(paneID, "pane")
        if let directory { try requireArgument(directory, "directory") }
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let cwd = directory.map { ["--cwd", $0] } ?? []
        let output = try await execute(prefix + ["pane", "split", paneID, "--direction", direction.rawValue] + cwd + ["--no-focus"])
        try validate(output, machine: machine)
        do { return try HerdrJSON.decoder().decode(PaneInfoDTO.Envelope.self, from: output.stdout).result.pane.terminalId }
        catch { throw decodingFailure(error) }
    }

    public func recentOutput(paneID: String, on machine: Machine, lines: Int) async throws -> String {
        try requireArgument(paneID, "pane")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let output = try await execute(prefix + ["pane", "read", paneID, "--source", "recent-unwrapped",
                                                 "--lines", String(lines), "--format", "text"])
        try validate(output, machine: machine)
        return String(decoding: output.stdout, as: UTF8.self)
    }

    public func renameWorkspace(_ workspaceID: String, to name: String, on machine: Machine) async throws {
        try requireArgument(workspaceID, "workspace")
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireArgument(name, "session name")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        try validate(try await execute(prefix + ["workspace", "rename", workspaceID, name]), machine: machine)
    }

    public func checkouts(around workspaceID: String, on machine: Machine) async throws -> [String: WorkspaceCheckout] {
        try requireArgument(workspaceID, "workspace")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let output = try await execute(prefix + ["worktree", "list", "--workspace", workspaceID])
        // Outside a Git repository Herdr answers with an error: no checkouts.
        guard (try? validate(output, machine: machine)) != nil else { return [:] }
        do { return try HerdrJSON.checkouts(output.stdout) }
        catch { throw decodingFailure(error) }
    }

    public func shellPID(paneID: String, on machine: Machine) async throws -> Int? {
        try requireArgument(paneID, "pane")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let output = try await execute(prefix + ["pane", "process-info", "--pane", paneID])
        try validate(output, machine: machine)
        do { return try HerdrJSON.shellPID(output.stdout) }
        catch { throw decodingFailure(error) }
    }

    public func runsCommand(paneID: String, on machine: Machine) async throws -> Bool? {
        try requireArgument(paneID, "pane")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let output = try await execute(prefix + ["pane", "process-info", "--pane", paneID])
        try validate(output, machine: machine)
        do { return try HerdrJSON.runsCommand(output.stdout) }
        catch { throw decodingFailure(error) }
    }

    public func startAgent(_ name: String, kind: String, paneID: String, on machine: Machine) async throws -> String? {
        try requireArgument(name, "agent name")
        try requireArgument(kind, "agent")
        try requireArgument(paneID, "pane")
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let started = try await execute(prefix + ["agent", "start", name, "--kind", kind, "--pane", paneID, "--timeout", "60000"], timeout: 75)
        do { try validate(started, machine: machine) }
        catch let failure as HerdrFailure where failure.detail == "Herdr error: agent_not_ready" {
            return "\(kind) is waiting for you to answer a startup question."
        }
        return nil
    }

    public func reportTokens(paneID: String, set: [String: String], clear: [String], on machine: Machine) async throws {
        try requireArgument(paneID, "pane")
        guard !set.isEmpty || !clear.isEmpty else { return }
        guard set.count + clear.count <= 16 else { throw HerdrFailure(.incompatible, "Herdr updates at most 16 tokens at once.") }
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        let tokens = set.sorted { $0.key < $1.key }.flatMap { ["--token", "\($0.key)=\($0.value)"] }
            + clear.sorted().flatMap { ["--clear-token", $0] }
        try validate(try await execute(prefix + ["pane", "report-metadata", paneID, "--source", "shepherdr"] + tokens), machine: machine)
    }

    public func prompt(paneID: String, text: String, on machine: Machine) async throws {
        try requireArgument(paneID, "pane")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HerdrFailure(.incompatible, "The prompt is empty.") }
        let prefix = machine.profileID.map { ["--machine", $0] } ?? []
        // The text is one argument, never shell text; Herdr pastes it and presses Return.
        try validate(try await execute(prefix + ["agent", "prompt", paneID, text], timeout: 30), machine: machine)
    }

    public func addMachine(_ request: NewMachineRequest) async throws {
        let target = request.sshTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        try requireArgument(target, "SSH target")
        guard !target.contains(where: \.isWhitespace) else { throw HerdrFailure(.incompatible, "The SSH target cannot contain spaces.") }
        var arguments = ["machine", "add", target]
        if let label = request.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty {
            arguments += ["--label", label]
        }
        if let session = request.remoteSession?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty {
            try requireArgument(session, "remote session")
            arguments += ["--remote-session", session]
        }
        // Herdr prepares the remote server over SSH; allow time for that, but never prompt.
        let output = try await execute(arguments, timeout: 180)
        try validateChange(output, action: "add \(target)")
    }

    public func removeMachine(profileID: String) async throws {
        try requireArgument(profileID, "machine")
        try validateChange(try await execute(["machine", "remove", profileID]), action: "remove the machine")
    }

    public func setMachine(profileID: String, enabled: Bool) async throws {
        try requireArgument(profileID, "machine")
        try validateChange(try await execute(["machine", enabled ? "enable" : "disable", profileID]),
                           action: enabled ? "enable the machine" : "disable the machine")
    }

    /// Values become separate arguments, never shell text; still refuse anything Herdr could read as an option.
    private func requireArgument(_ value: String, _ name: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"),
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw HerdrFailure(.incompatible, "Enter a valid \(name).")
        }
    }

    private func validateChange(_ output: CommandOutput, action: String) throws {
        do { try validate(output, machine: .local) }
        catch let failure as HerdrFailure where failure.detail?.hasPrefix("Herdr error:") != true {
            throw HerdrFailure(failure.state, "Herdr could not \(action).", detail: failure.detail)
        }
    }

    private func execute(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> CommandOutput {
        let timeout = timeout ?? self.timeout
        let url = try executable ?? ExecutableLocator().locate()
        do { return try await runner.run(executable: url, arguments: arguments, timeout: timeout) }
        catch is CancellationError { throw CancellationError() }
        catch CommandError.timedOut {
            throw HerdrFailure(.unreachable, "Herdr did not respond within \(Int(timeout)) seconds.",
                               detail: "Check the machine and SSH connection. Shepherdr will retry automatically.")
        } catch CommandError.outputTooLarge {
            throw HerdrFailure(.incompatible, "Herdr’s response exceeded the 8 MB limit.")
        } catch {
            throw HerdrFailure(.unreachable, "Could not run Herdr.", detail: error.localizedDescription)
        }
    }

    private func validate(_ output: CommandOutput, machine: Machine) throws {
        // API errors may be written to stderr with a nonzero exit code, including protocol errors.
        for data in [output.stdout, output.stderr] {
            if let error = try? HerdrJSON.decoder().decode(APIErrorDTO.self, from: data) {
                throw apiFailure(error.error)
            }
            for line in data.split(separator: 0x0A) {
                if let error = try? HerdrJSON.decoder().decode(APIErrorDTO.self, from: Data(line)) {
                    throw apiFailure(error.error)
                }
            }
        }
        guard output.exitCode == 0 else {
            let detail = String(decoding: output.stderr.prefix(4_096), as: UTF8.self).nonempty
                ?? "Herdr exited with status \(output.exitCode)."
            // Usage errors have no JSON envelope. Exit 2 is Herdr's unsupported CLI contract.
            if output.exitCode == 2 {
                throw HerdrFailure(.incompatible,
                    machine.isLocal ? "This Herdr installation does not support the required JSON commands."
                    : "Update local Herdr to a build that supports --machine forwarding.", detail: detail)
            }
            throw HerdrFailure(.unreachable,
                machine.isLocal ? "Could not connect to the local Herdr server."
                : "Could not query this saved machine. Check SSH and remote Herdr setup.", detail: detail)
        }
    }

    private func apiFailure(_ error: APIErrorDTO.Body) -> HerdrFailure {
        let state: ConnectionState
        switch error.code {
        case "server_not_running": state = .notRunning
        case "not_installed", "herdr_not_installed": state = .notInstalled
        case "protocol_mismatch", "method_not_found", "unknown_method", "unsupported_method", "invalid_request":
            state = .incompatible
        default: state = .unreachable
        }
        return HerdrFailure(state, error.message, detail: "Herdr error: \(error.code)")
    }

    private func decodingFailure(_ error: Error) -> HerdrFailure {
        if let failure = error as? HerdrFailure { return failure }
        return HerdrFailure(.incompatible, "Herdr returned JSON that Shepherdr could not read.",
                           detail: "Expected the supported machine list or session.snapshot contract. \(error)")
    }
}
