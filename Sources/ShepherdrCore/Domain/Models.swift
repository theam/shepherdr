import Foundation

public struct Machine: Identifiable, Hashable, Codable, Sendable {
    public let profileID: String?
    public let name: String
    public let target: String?
    public let session: String
    public let isEnabled: Bool

    public var id: String { profileID.map { "remote:\($0)" } ?? "local" }
    public var isLocal: Bool { profileID == nil }
    public static let local = Machine(profileID: nil, name: "Local", target: nil,
                                      session: "default", isEnabled: true)

    public init(profileID: String?, name: String, target: String?, session: String, isEnabled: Bool) {
        self.profileID = profileID
        self.name = name
        self.target = target
        self.session = session
        self.isEnabled = isEnabled
    }
}

public enum AgentState: String, CaseIterable, Sendable {
    case working, blocked, idle, done, unknown

    public init(reportedValue: String) { self = Self(rawValue: reportedValue) ?? .unknown }
    public var title: String { rawValue.capitalized }
    public var priority: Int {
        switch self {
        case .blocked: 0
        case .working: 1
        case .done: 2
        case .idle: 3
        case .unknown: 4
        }
    }
    public var symbol: String {
        switch self {
        case .blocked: "exclamationmark.circle.fill"
        case .working: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle"
        case .idle: "pause.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

public struct Agent: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Codable, Sendable {
        public let machineID: String
        public let terminalID: String
        public init(machineID: String, terminalID: String) {
            self.machineID = machineID
            self.terminalID = terminalID
        }
    }
    public let id: ID
    public let name: String
    /// Herdr's label for the agent, such as `claude`; see `program` for its name and mark.
    public let kind: String
    public let state: AgentState
    public let reportedState: String
    public let workspaceID: String
    public let workspaceName: String
    public let tabID: String
    public let tabName: String
    public let paneID: String
    public let directory: String?
    public let project: String?
    public let summary: String?
    public let isLaunchPending: Bool
}

/// The Git checkout a workspace works in, as Herdr reports it: the repository's main checkout or
/// one of its linked worktrees.
public struct WorkspaceCheckout: Equatable, Sendable {
    public let repository: String
    public let branch: String?
    public let isLinkedWorktree: Bool
    public let path: String

    public init(repository: String, branch: String?, isLinkedWorktree: Bool, path: String) {
        self.repository = repository
        self.branch = branch
        self.isLinkedWorktree = isLinkedWorktree
        self.path = path
    }

    /// The folder in the main checkout, the project in a worktree.
    public var name: String { isLinkedWorktree ? repository : (path as NSString).lastPathComponent }
}

public struct Workspace: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let directory: String?
    public let tabCount: Int
    public let paneCount: Int
    public let state: AgentState
}

public struct MachineSnapshot: Equatable, Sendable {
    public let version: String
    public let protocolVersion: Int
    public let workspaces: [Workspace]
    public let agents: [Agent]
    public let panes: [TerminalPane]
    /// The letter each pane last announced with `shepherdr`, by terminal ID.
    public let doorbells: [String: String]
    /// The tokens Shepherdr and its tools keep on each pane, those named `shepherdr-…`, by terminal ID.
    public let tokens: [String: [String: String]]

    public init(version: String, protocolVersion: Int, workspaces: [Workspace], agents: [Agent], panes: [TerminalPane] = [],
                doorbells: [String: String] = [:], tokens: [String: [String: String]] = [:]) {
        self.version = version
        self.protocolVersion = protocolVersion
        self.workspaces = workspaces
        self.agents = agents
        self.panes = panes
        self.doorbells = doorbells
        self.tokens = tokens
    }
}

public enum ConnectionState: String, Sendable {
    case loading, online, unreachable, notInstalled, notRunning, incompatible, disabled

    public var title: String {
        switch self {
        case .loading: "Connecting"
        case .online: "Online"
        case .unreachable: "Unreachable"
        case .notInstalled: "Herdr not installed"
        case .notRunning: "Herdr not running"
        case .incompatible: "Incompatible Herdr"
        case .disabled: "Disabled in Herdr"
        }
    }
}

public struct HerdrFailure: Error, Equatable, LocalizedError, Sendable {
    public let state: ConnectionState
    public let message: String
    public let detail: String?

    public init(_ state: ConnectionState, _ message: String, detail: String? = nil) {
        self.state = state
        self.message = message
        self.detail = detail
    }
    public var errorDescription: String? { message }
}

/// A machine as the last refresh left it. When it last answered is kept apart, in
/// `ClusterStore.lastSuccess`: it changes on every refresh, and everything reads this.
public struct MachineState: Identifiable, Equatable, Sendable {
    public var machine: Machine
    public var connection: ConnectionState = .loading
    public var snapshot: MachineSnapshot?
    public var failure: HerdrFailure?
    public var id: String { machine.id }
    public var isStale: Bool { snapshot != nil && connection != .online }
    public var agents: [Agent] { snapshot?.agents ?? [] }

    public init(machine: Machine) {
        self.machine = machine
        if !machine.isEnabled { connection = .disabled }
    }
}

/// Presentation-ready aggregation without any SwiftUI or transport dependency.
public struct AgentRow: Identifiable, Equatable, Sendable {
    public let agent: Agent
    public let machineName: String
    public let isStale: Bool
    public var manualPriority: Int = 0
    /// The user-defined group holding this session, if any.
    public var groupID: String?
    public var id: Agent.ID { agent.id }
    public var name: String { agent.name }
    public var workspace: String { agent.workspaceName }
    public var project: String { agent.directory ?? agent.project ?? "—" }
    /// What the agent is doing, as its terminal reports it; falls back to the agent name.
    public var title: String { agent.summary ?? agent.name }
    public var priority: Int { agent.state.priority }
    public var stateTitle: String { agent.state.title }

    public func matches(_ query: String) -> Bool {
        query.isEmpty || [name, agent.kind, agent.program.name, workspace, project, machineName, agent.paneID,
                          agent.summary ?? "", stateTitle].contains {
            $0.localizedStandardContains(query)
        }
    }
}

/// A new workspace, optionally with a supported agent started in its first pane.
public struct NewSessionRequest: Equatable, Sendable {
    /// Agent kinds Herdr's `agent start --kind` accepts and Shepherdr offers by default.
    public static let agentKinds = ["claude", "codex", "gemini", "opencode", "cursor", "amp", "copilot", "droid", "qwen", "kimi", "grok"]

    /// A Git worktree the session works in, made in the repository `directory` belongs to.
    public struct Worktree: Equatable, Sendable {
        /// Checked out when it exists, created otherwise.
        public let branch: String
        /// Where a new branch starts: the repository's current commit when nil.
        public let base: String?

        public init(branch: String, base: String? = nil) {
            self.branch = branch
            self.base = base
        }
    }

    public let directory: String
    public let name: String
    /// A Herdr agent kind such as `claude`, or nil for a plain shell.
    public let agentKind: String?
    /// Nil for a session in `directory` itself.
    public let worktree: Worktree?

    public init(directory: String, name: String, agentKind: String?, worktree: Worktree? = nil) {
        self.directory = directory
        self.name = name
        self.agentKind = agentKind
        self.worktree = worktree
    }
}

public struct CreatedSession: Equatable, Sendable {
    public let workspaceID: String
    public let paneID: String
    public let terminalID: String
    /// Set when the workspace exists but its agent is waiting for the user or failed to start.
    public let notice: String?
    /// A workspace Herdr already had open, such as the one of a worktree asked for again.
    public let isExisting: Bool

    public init(workspaceID: String, paneID: String, terminalID: String, notice: String? = nil, isExisting: Bool = false) {
        self.workspaceID = workspaceID
        self.paneID = paneID
        self.terminalID = terminalID
        self.notice = notice
        self.isExisting = isExisting
    }
}

public struct NewMachineRequest: Equatable, Sendable {
    public let sshTarget: String
    public let label: String?
    public let remoteSession: String?

    public init(sshTarget: String, label: String?, remoteSession: String?) {
        self.sshTarget = sshTarget
        self.label = label
        self.remoteSession = remoteSession
    }
}
