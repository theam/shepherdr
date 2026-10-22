import Foundation

// DTOs model only the consumed JSON contract. Unknown fields are deliberately ignored;
// structural collections remain required so incompatible JSON cannot look like an empty cluster.
struct MachineDTO: Decodable, Sendable {
    let id: String
    let label: String
    let target: String
    let session: String
    let enabled: Bool
}

struct SnapshotEnvelopeDTO: Decodable {
    let result: SnapshotResultDTO
}

struct SnapshotResultDTO: Decodable {
    let type: String
    let snapshot: SnapshotDTO
}

struct SnapshotDTO: Decodable, Sendable {
    let version: String
    let `protocol`: Int
    let workspaces: [WorkspaceDTO]
    let tabs: [TabDTO]
    let panes: [PaneDTO]
    let agents: [AgentDTO]
}

struct WorkspaceDTO: Decodable, Sendable {
    let workspaceId: String
    let label: String
    let paneCount: Int
    let tabCount: Int
    let agentStatus: String
    let worktree: WorktreeDTO?
}

struct WorktreeDTO: Decodable, Sendable {
    let repoName: String
    let repoRoot: String
    let checkoutPath: String
}

struct TabDTO: Decodable, Sendable {
    let tabId: String
    let workspaceId: String
    let label: String
}

struct PaneDTO: Decodable, Sendable {
    let paneId: String
    let terminalId: String
    let workspaceId: String
    let tabId: String
    let cwd: String?
    let foregroundCwd: String?
    let tokens: [String: String]?
}

struct AgentDTO: Decodable, Sendable {
    let terminalId: String
    let name: String?
    let agent: String?
    let displayAgent: String?
    let agentStatus: String
    let workspaceId: String
    let tabId: String
    let paneId: String
    let cwd: String?
    let foregroundCwd: String?
    let title: String?
    let terminalTitleStripped: String?
    let tokens: [String: String]?
    let launchPending: Bool?
}

struct WorkspaceCreatedDTO: Decodable {
    struct Result: Decodable {
        struct Workspace: Decodable { let workspaceId: String }
        struct RootPane: Decodable { let paneId: String; let terminalId: String }
        let workspace: Workspace
        let rootPane: RootPane
        /// Set by `worktree open` when a workspace already has the worktree open.
        let alreadyOpen: Bool?
    }
    let result: Result
}

struct APIErrorDTO: Decodable {
    struct Body: Decodable { let code: String; let message: String }
    let error: Body
}

struct WorktreeListDTO: Decodable {
    struct Envelope: Decodable { let result: WorktreeListDTO }
    struct Source: Decodable { let repoName: String? }
    struct Worktree: Decodable {
        let branch: String?
        let isLinkedWorktree: Bool?
        let openWorkspaceId: String?
        let path: String
    }
    let source: Source?
    let worktrees: [Worktree]?
}

struct ProcessInfoDTO: Decodable {
    struct Envelope: Decodable { let result: Result }
    struct Result: Decodable { let processInfo: ProcessInfoDTO }
    struct Process: Decodable { let pid: Int }
    let shellPid: Int?
    /// What the terminal runs in the foreground: the shell itself at its prompt.
    let foregroundProcesses: [Process]?
}

struct PaneListDTO: Decodable {
    struct Envelope: Decodable { let result: PaneListDTO }
    struct Pane: Decodable {
        struct Scroll: Decodable { let offsetFromBottom: Int }
        let terminalId: String
        let scroll: Scroll?
    }
    let panes: [Pane]
}

struct ServerStatusDTO: Decodable {
    let running: Bool
    let compatible: Bool?
}

enum HerdrJSON {
    static let doorbellToken = "shepherdr-mail"

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    /// The checkouts of one repository that workspaces have open, by workspace ID.
    static func checkouts(_ data: Data) throws -> [String: WorkspaceCheckout] {
        let list = try decoder().decode(WorktreeListDTO.Envelope.self, from: data).result
        let repository = list.source?.repoName ?? ""
        var result: [String: WorkspaceCheckout] = [:]
        for worktree in list.worktrees ?? [] {
            guard let workspace = worktree.openWorkspaceId, !workspace.isEmpty else { continue }
            let name = repository.isEmpty ? (worktree.path as NSString).lastPathComponent : repository
            result[workspace] = WorkspaceCheckout(repository: name, branch: worktree.branch,
                                                  isLinkedWorktree: worktree.isLinkedWorktree ?? false, path: worktree.path)
        }
        return result
    }

    /// The process ID of the shell a pane started with; nil when Herdr doesn't say.
    static func shellPID(_ data: Data) throws -> Int? {
        try decoder().decode(ProcessInfoDTO.Envelope.self, from: data).result.processInfo.shellPid
    }

    /// Whether a pane's shell runs a command in the foreground rather than waiting at its prompt;
    /// nil when Herdr doesn't say.
    static func runsCommand(_ data: Data) throws -> Bool? {
        let info = try decoder().decode(ProcessInfoDTO.Envelope.self, from: data).result.processInfo
        guard let shell = info.shellPid, let foreground = info.foregroundProcesses else { return nil }
        return foreground.contains { $0.pid != shell }
    }

    /// How many lines above its latest output Herdr shows a terminal; nil when Herdr doesn't say.
    static func linesBack(_ data: Data, terminalID: String) throws -> Int? {
        let panes = try decoder().decode(PaneListDTO.Envelope.self, from: data).result.panes
        return panes.first { $0.terminalId == terminalID }?.scroll.map { max(0, $0.offsetFromBottom) }
    }

    static func machines(_ data: Data) throws -> [Machine] {
        let rows = try decoder().decode([MachineDTO].self, from: data)
        try requireUnique(rows.map(\.id), resource: "machine")
        return rows.map {
            Machine(profileID: $0.id, name: $0.label.nonempty ?? $0.target,
                    target: $0.target, session: $0.session, isEnabled: $0.enabled)
        }
    }

    static func snapshot(_ data: Data, machine: Machine) throws -> MachineSnapshot {
        let result = try decoder().decode(SnapshotEnvelopeDTO.self, from: data).result
        guard result.type == "session_snapshot" else {
            throw HerdrFailure(.incompatible, "Herdr returned an unexpected response type.")
        }
        let dto = result.snapshot
        try requireUnique(dto.workspaces.map(\.workspaceId), resource: "workspace")
        try requireUnique(dto.tabs.map(\.tabId), resource: "tab")
        try requireUnique(dto.panes.map(\.paneId), resource: "pane")
        try requireUnique(dto.panes.map(\.terminalId), resource: "terminal")
        try requireUnique(dto.agents.map(\.terminalId), resource: "agent")
        let workspaces = Dictionary(uniqueKeysWithValues: dto.workspaces.map { ($0.workspaceId, $0) })
        let tabs = Dictionary(uniqueKeysWithValues: dto.tabs.map { ($0.tabId, $0) })
        let panes = Dictionary(uniqueKeysWithValues: dto.panes.map { ($0.paneId, $0) })
        let agents = dto.agents.map { item in
            let workspace = workspaces[item.workspaceId]
            let pane = panes[item.paneId]
            // Herdr's label names the agent; what a pane reports for display only names the session.
            let kind = item.agent?.nonempty ?? item.displayAgent?.nonempty ?? ""
            let display = item.displayAgent?.nonempty ?? AgentProgram(label: kind).name
            let directory = item.foregroundCwd?.nonempty ?? pane?.foregroundCwd?.nonempty
                ?? item.cwd?.nonempty ?? pane?.cwd?.nonempty ?? workspace?.worktree?.checkoutPath
            return Agent(
                id: .init(machineID: machine.id, terminalID: item.terminalId),
                name: item.name?.nonempty ?? display, kind: kind,
                state: AgentState(reportedValue: item.agentStatus), reportedState: item.agentStatus,
                workspaceID: item.workspaceId, workspaceName: workspace?.label.nonempty ?? item.workspaceId,
                tabID: item.tabId, tabName: tabs[item.tabId]?.label.nonempty ?? item.tabId,
                paneID: item.paneId, directory: directory,
                // The path's own last part: a URL would stat it on this Mac, where another machine's
                // /home/… goes through the automounter on every refresh.
                project: workspace?.worktree?.repoName ?? directory.map { ($0 as NSString).lastPathComponent },
                summary: item.tokens?["summary"]?.nonempty ?? item.title?.nonempty ?? item.terminalTitleStripped?.nonempty,
                isLaunchPending: item.launchPending ?? false
            )
        }
        // `shepherdr` rings a pane's doorbell with the ID of the letter it just left.
        var doorbells: [String: String] = [:]
        for pane in dto.panes {
            if let bell = pane.tokens?[Self.doorbellToken], Letter.isValidID(bell) { doorbells[pane.terminalId] = bell }
        }
        for agent in dto.agents where doorbells[agent.terminalId] == nil {
            if let bell = agent.tokens?[Self.doorbellToken], Letter.isValidID(bell) { doorbells[agent.terminalId] = bell }
        }
        var tokens: [String: [String: String]] = [:]
        for (terminal, list) in dto.agents.map({ ($0.terminalId, $0.tokens) }) + dto.panes.map({ ($0.terminalId, $0.tokens) }) {
            let own = (list ?? [:]).filter { $0.key.hasPrefix("shepherdr-") }
            if !own.isEmpty { tokens[terminal, default: [:]].merge(own) { _, pane in pane } }
        }
        return MachineSnapshot(version: dto.version, protocolVersion: dto.protocol,
            workspaces: dto.workspaces.map { item in
                Workspace(id: item.workspaceId, name: item.label.nonempty ?? item.workspaceId,
                          directory: item.worktree?.checkoutPath ?? dto.panes.first { $0.workspaceId == item.workspaceId }?.cwd,
                          tabCount: item.tabCount, paneCount: item.paneCount,
                          state: AgentState(reportedValue: item.agentStatus))
            }, agents: agents, panes: dto.panes.map { pane in
                TerminalPane(terminalID: pane.terminalId, paneID: pane.paneId,
                             workspaceID: pane.workspaceId,
                             workspaceName: workspaces[pane.workspaceId]?.label.nonempty ?? pane.workspaceId,
                             title: agents.first { $0.id.terminalID == pane.terminalId }?.name
                                ?? "\(tabs[pane.tabId]?.label.nonempty ?? pane.tabId) · \(pane.paneId)",
                             directory: pane.foregroundCwd?.nonempty ?? pane.cwd?.nonempty)
            }, doorbells: doorbells, tokens: tokens)
    }

    private static func requireUnique(_ ids: [String], resource: String) throws {
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw HerdrFailure(.incompatible, "Herdr returned duplicate or empty \(resource) IDs.")
        }
    }
}

extension String {
    var nonempty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
