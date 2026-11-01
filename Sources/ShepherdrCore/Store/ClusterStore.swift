import Foundation
import Observation

@MainActor @Observable
public final class ClusterStore {
    public private(set) var machines: [MachineState] = [MachineState(machine: .local)] { didSet { updateAgents() } }
    /// When each machine last answered, by machine ID. Apart from `machines`, which only changes
    /// when what a machine reports does: views that read it aren't redrawn by every refresh.
    public private(set) var lastSuccess: [String: Date] = [:]
    public private(set) var discoveryFailure: HerdrFailure?
    public private(set) var isRefreshing = false
    public private(set) var lastRefresh: Date?
    public var automaticRefresh = true
    public var refreshInterval: TimeInterval = 5
    /// Whether Shepherdr can be seen: off screen, other machines are asked less often.
    @ObservationIgnored public var isOnScreen = true
    @ObservationIgnored private var schedule = RefreshSchedule()
    @ObservationIgnored private let client: any HerdrClient
    /// The Git checkout of each workspace, by machine and workspace ID; learned once per workspace.
    public private(set) var checkouts: [String: WorkspaceCheckout] = [:]
    /// Workspaces asked about, including those outside a repository.
    @ObservationIgnored private var knownWorkspaces = Set<String>()
    @ObservationIgnored private var learning: Task<Void, Never>?
    /// Every snapshot asked for gets the next number; each machine shows the answer to its latest
    /// ask, so an answer that took longer never replaces a newer one.
    @ObservationIgnored private var asks = 0
    @ObservationIgnored private var shownAsk: [String: Int] = [:]

    public init(client: any HerdrClient = CLIHerdrClient()) { self.client = client }

    /// Every machine's sessions, most urgent first. Kept rather than computed: views read it many
    /// times per update, and it only changes when a snapshot brings something new.
    public private(set) var agents: [AgentRow] = []
    /// The same sessions by ID, for looking one up without going through all of them.
    public private(set) var agentsByID: [Agent.ID: AgentRow] = [:]

    private func updateAgents() {
        let rows = machines.flatMap { state in
            state.agents.map { AgentRow(agent: $0, machineName: state.machine.name, isStale: state.isStale) }
        }.sorted {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            if $0.machineName != $1.machineName { return $0.machineName < $1.machineName }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.terminalID < $1.id.terminalID
        }
        guard rows != agents else { return }
        agents = rows
        agentsByID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public var onlineCount: Int { machines.filter { $0.connection == .online }.count }

    public func checkout(machineID: String, workspaceID: String) -> WorkspaceCheckout? {
        checkouts["\(machineID)/\(workspaceID)"]
    }

    /// Asks Herdr, one repository at a time, which checkout each new workspace works in. Whether a
    /// folder is a worktree doesn't change, so each workspace is asked about once.
    private func learnCheckouts() {
        guard learning == nil else { return }
        let pending = agents.map { (machine: $0.id.machineID, workspace: $0.agent.workspaceID) }
            .filter { !$0.workspace.isEmpty && !knownWorkspaces.contains("\($0.machine)/\($0.workspace)") }
        guard !pending.isEmpty else { return }
        learning = Task { [weak self, client] in
            defer { self?.learning = nil }
            for item in pending {
                guard let self, !Task.isCancelled else { return }
                let key = "\(item.machine)/\(item.workspace)"
                // An earlier answer about the same repository may have covered it.
                guard !self.knownWorkspaces.contains(key), let machine = try? self.machine(item.machine) else { continue }
                self.knownWorkspaces.insert(key)
                // A machine that didn't answer is asked again on a later refresh.
                guard let found = try? await client.checkouts(around: item.workspace, on: machine) else {
                    self.knownWorkspaces.remove(key)
                    continue
                }
                for (workspace, checkout) in found {
                    self.knownWorkspaces.insert("\(item.machine)/\(workspace)")
                    self.checkouts["\(item.machine)/\(workspace)"] = checkout
                }
            }
        }
    }

    /// What a pane printed last, such as an agent's final message; nil when Herdr cannot tell.
    public func recentOutput(paneID: String, onMachine id: String, lines: Int = 60) async -> String? {
        guard let machine = try? machine(id) else { return nil }
        return try? await client.recentOutput(paneID: paneID, on: machine, lines: lines)
    }

    /// Whether a pane's shell runs a command, such as a script, rather than waiting at its prompt;
    /// nil when Herdr can't tell.
    public func runsCommand(paneID: String, onMachine id: String) async -> Bool? {
        guard let machine = try? machine(id) else { return nil }
        return try? await client.runsCommand(paneID: paneID, on: machine)
    }

    /// Sets and clears Shepherdr's own tokens on a pane. Returns whether Herdr took them; the
    /// next refresh shows them.
    public func reportTokens(paneID: String, set: [String: String], clear: [String], onMachine id: String) async -> Bool {
        guard let machine = try? machine(id) else { return false }
        return (try? await client.reportTokens(paneID: paneID, set: set, clear: clear, on: machine)) != nil
    }

    /// Submits a prompt to the agent in a pane. Herdr refuses while the agent asks a question.
    public func prompt(paneID: String, text: String, onMachine id: String) async throws {
        try await client.prompt(paneID: paneID, text: text, on: try machine(id))
    }

    /// Starts an agent in a pane that has none, such as Compass's after its agent exited.
    public func startAgent(_ name: String, kind: String, paneID: String, onMachine id: String) async throws -> String? {
        let notice = try await client.startAgent(name, kind: kind, paneID: paneID, on: try machine(id))
        await refreshAfterChange(on: id)
        return notice
    }

    public func renameWorkspace(_ workspaceID: String, to name: String, onMachine id: String) async throws {
        try await client.renameWorkspace(workspaceID, to: name, on: try machine(id))
        await refreshAfterChange(on: id)
    }

    /// Asks every machine and reads the catalog, such as when you refresh or come back to the window.
    /// Local querying and catalog discovery start together. Every machine publishes as it finishes.
    /// A slow remote never delays display of a healthy machine. Overlapping refreshes are coalesced.
    public func refresh() async {
        await refresh(only: nil, catalog: true)
    }

    /// A regular refresh: the machines `RefreshSchedule` says are due, and the catalog when it is.
    func tick(now: Date = Date()) async {
        let plan = schedule.due(machines.map(\.machine), interval: refreshInterval, onScreen: isOnScreen, now: now)
        guard !plan.machines.isEmpty || plan.catalog else { return }
        await refresh(only: plan.machines, catalog: plan.catalog, now: now)
    }

    /// - Parameter due: the machines to ask, by ID; nil for all. Machines the catalog brings that
    ///   weren't enabled before are asked too.
    private func refresh(only due: Set<String>?, catalog readsCatalog: Bool, now: Date = Date()) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let wasEnabled = Set(machines.filter(\.machine.isEnabled).map(\.id))
        enum Update: Sendable {
            case catalog(Result<[Machine], HerdrFailure>)
            case snapshot(String, ask: Int, Result<MachineSnapshot, HerdrFailure>)
            case cancelled
        }
        let client = client
        await withTaskGroup(of: Update.self) { group in
            // Also refresh known remotes immediately if catalog discovery is temporarily failing.
            var scheduled = Set<String>()
            for index in machines.indices where machines[index].machine.isEnabled && due?.contains(machines[index].id) != false {
                let machine = machines[index].machine
                scheduled.insert(machine.id)
                let ask = nextAsk()
                group.addTask {
                    do { return .snapshot(machine.id, ask: ask, .success(try await client.snapshot(for: machine))) }
                    catch is CancellationError { return .cancelled }
                    catch { return .snapshot(machine.id, ask: ask, .failure(Self.failure(error))) }
                }
            }
            schedule.didAsk(scheduled, catalog: readsCatalog, at: now)
            if readsCatalog {
                group.addTask {
                    do { return .catalog(.success(try await client.machines())) }
                    catch is CancellationError { return .cancelled }
                    catch { return .catalog(.failure(Self.failure(error))) }
                }
            }
            for await update in group {
                guard !Task.isCancelled else { group.cancelAll(); continue }
                switch update {
                case .catalog(.success(let discovered)):
                    discoveryFailure = nil
                    schedule.catalogFailed = false
                    let catalog = [Machine.local] + discovered.filter { !$0.isLocal }
                    // Defend the protocol boundary even for alternate clients.
                    var seen = Set<String>()
                    let updated = catalog.filter { seen.insert($0.id).inserted }.map { machine in
                        var state = machines.first { $0.id == machine.id } ?? MachineState(machine: machine)
                        state.machine = machine
                        if !machine.isEnabled {
                            state.connection = .disabled
                        } else if state.connection == .disabled {
                            state.connection = .loading
                        }
                        return state
                    }
                    // The catalog rarely changes; an equal one leaves every view alone.
                    if updated != machines { machines = updated }
                    for index in machines.indices where machines[index].machine.isEnabled {
                        let machine = machines[index].machine
                        // A machine that isn't due waits for its turn, unless it just joined.
                        guard due?.contains(machine.id) != false || !wasEnabled.contains(machine.id),
                              scheduled.insert(machine.id).inserted else { continue }
                        schedule.didAsk([machine.id], catalog: false, at: now)
                        let ask = nextAsk()
                        group.addTask {
                            do { return .snapshot(machine.id, ask: ask, .success(try await client.snapshot(for: machine))) }
                            catch is CancellationError { return .cancelled }
                            catch { return .snapshot(machine.id, ask: ask, .failure(Self.failure(error))) }
                        }
                    }
                case .catalog(.failure(let failure)):
                    discoveryFailure = failure
                    schedule.catalogFailed = true
                case .snapshot(let id, let ask, let result):
                    show(result, of: id, ask: ask)
                case .cancelled: break
                }
            }
        }
        if !Task.isCancelled {
            lastRefresh = Date()
            learnCheckouts()
        }
    }

    private func nextAsk() -> Int {
        asks += 1
        return asks
    }

    private func show(_ result: Result<MachineSnapshot, HerdrFailure>, of id: String, ask: Int) {
        guard let index = machines.firstIndex(where: { $0.id == id }), machines[index].machine.isEnabled,
              ask > shownAsk[id, default: 0] else { return }
        shownAsk[id] = ask
        var state = machines[index]
        switch result {
        case .success(let snapshot):
            state.snapshot = snapshot
            state.connection = .online
            state.failure = nil
            lastSuccess[id] = Date()
        case .failure(let failure):
            state.connection = failure.state
            state.failure = failure
        }
        // Most refreshes find nothing new: then nothing that reads machines redraws.
        if state != machines[index] { machines[index] = state }
    }

    // MARK: Changes requested by the user

    public func createSession(_ request: NewSessionRequest, onMachine id: String) async throws -> CreatedSession {
        let created = try await client.createSession(request, on: try machine(id))
        await refreshAfterChange(on: id)
        return created
    }

    public func closeSession(paneID: String, onMachine id: String) async throws {
        try await client.closeSession(paneID: paneID, on: try machine(id))
        await paneClosed(paneID, onMachine: id)
    }

    /// A pane Herdr no longer has, closed from here or ended on its own, such as a shell you typed
    /// `exit` in: it leaves at once, without waiting for the machine to answer again.
    public func paneClosed(_ paneID: String, onMachine id: String) async {
        if let index = machines.firstIndex(where: { $0.id == id }), let snapshot = machines[index].snapshot {
            shownAsk[id] = nextAsk()
            machines[index].snapshot = snapshot.closing(paneID: paneID)
        }
        await refreshAfterChange(on: id)
    }

    /// Splits a pane and returns the new one's terminal ID, once the snapshot shows it.
    public func splitPane(_ paneID: String, _ direction: SplitDirection, directory: String?, onMachine id: String) async throws -> String {
        let terminalID = try await client.splitPane(paneID, direction, directory: directory, on: try machine(id))
        await refreshAfterChange(on: id)
        return terminalID
    }

    public func addMachine(_ request: NewMachineRequest) async throws {
        try await client.addMachine(request)
        await refreshAfterChange()
    }

    public func removeMachine(_ id: String) async throws {
        guard let profileID = try machine(id).profileID else { throw HerdrFailure(.incompatible, "The local session cannot be removed.") }
        try await client.removeMachine(profileID: profileID)
        await refreshAfterChange()
    }

    public func setMachine(_ id: String, enabled: Bool) async throws {
        guard let profileID = try machine(id).profileID else { throw HerdrFailure(.incompatible, "The local session cannot be disabled.") }
        try await client.setMachine(profileID: profileID, enabled: enabled)
        await refreshAfterChange()
    }

    private func machine(_ id: String) throws -> Machine {
        guard let state = machines.first(where: { $0.id == id }) else {
            throw HerdrFailure(.unreachable, "That machine is no longer in Herdr's catalog.")
        }
        return state.machine
    }

    /// Reads a machine again after a change there, at once: a refresh in flight may be waiting on a
    /// slow remote, and an answer it brings, asked for before the change, won't replace this one.
    private func refreshAfterChange(on id: String) async {
        guard let machine = try? machine(id), machine.isEnabled else { return }
        let ask = nextAsk()
        let result: Result<MachineSnapshot, HerdrFailure>
        do { result = .success(try await client.snapshot(for: machine)) }
        catch is CancellationError { return }
        catch { result = .failure(Self.failure(error)) }
        show(result, of: id, ask: ask)
        // What follows a refresh, such as keeping holds, follows a change too.
        lastRefresh = Date()
        learnCheckouts()
    }

    /// Reads one machine again now, such as before acting on what its snapshot says.
    public func refresh(machine id: String) async {
        await refreshAfterChange(on: id)
    }

    /// A refresh already in flight may have started before the change; wait for it, then read again.
    private func refreshAfterChange() async {
        while isRefreshing {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        await refresh()
    }

    /// Cancellation belongs to the window's SwiftUI task. No detached polling task survives it.
    /// Each tick asks only the machines due: all of them while Shepherdr is on screen.
    public func monitor() async {
        await refresh()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(refreshInterval)) }
            catch { return }
            if automaticRefresh { await tick() }
        }
    }

    nonisolated private static func failure(_ error: Error) -> HerdrFailure {
        error as? HerdrFailure ?? HerdrFailure(.unreachable, "Could not read Herdr data.", detail: error.localizedDescription)
    }
}
