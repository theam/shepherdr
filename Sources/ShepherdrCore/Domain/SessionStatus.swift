import Foundation

/// What a session is doing, as every view shows it. One function works it out, from what Herdr
/// says about the session and whether it is on hold; nothing else decides it.
public enum SessionStatus: String, CaseIterable, Sendable {
    /// Its machine isn't answering: what it last said can't be trusted.
    case stale
    /// Its agent asks a question or a permission.
    case needsYou
    case working
    /// On hold: something it waits for hasn't finished.
    case waiting
    /// Its agent finished a turn that no Herdr client has looked at.
    case done
    case idle
    case unknown
    /// A shell running a command.
    case running
    /// A shell whose command ended.
    case finished
    /// A shell at its prompt.
    case shell

    /// Working, needing you, waiting or running a command: not free.
    public var isBusy: Bool { [.needsYou, .working, .waiting, .running].contains(self) }

    /// How views name it, in lowercase: `needs you`, `on hold`.
    public var label: String {
        switch self {
        case .needsYou: "needs you"
        case .waiting: "on hold"
        default: rawValue
        }
    }

    /// The status of a session: its machine first, then what needs you, then work, then holds, then
    /// Herdr's own word. The same inputs always give the same status.
    public static func of(_ own: OwnStatus, isHeld: Bool) -> SessionStatus {
        if own.isStale { return .stale }
        switch own.kind {
        case .agent(.blocked): return .needsYou
        case .agent(.working): return .working
        case .agent(let state):
            if isHeld { return .waiting }
            return switch state {
            case .done: .done
            case .idle: .idle
            default: .unknown
            }
        case .shell(.running): return .running
        case .shell(.finished): return .finished
        case .shell(.atPrompt): return isHeld ? .waiting : .shell
        }
    }
}

/// What a shell is doing, as Shepherdr sees it while a session waits for it.
public enum ShellActivity: Equatable, Sendable {
    case atPrompt, running, finished
}

/// A session's own part of its status: what Herdr says about it, and whether its machine answers.
public struct OwnStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case agent(AgentState)
        case shell(ShellActivity)
    }

    public let kind: Kind
    public let isStale: Bool

    public init(_ kind: Kind, isStale: Bool = false) {
        self.kind = kind
        self.isStale = isStale
    }

    public init(_ row: AgentRow) { self.init(.agent(row.agent.state), isStale: row.isStale) }
}

extension HoldPhase {
    /// Where a hold stands once the session it waits for has a status. A busy session has
    /// started; one that started and is free again has finished, and starts again if it gets
    /// busy again. A session that finished a turn before anyone looked (done), or a shell whose
    /// command ended, has finished even if it was never seen busy, while a new one that is idle
    /// before its first prompt hasn't started. Not knowing, as when its machine doesn't answer,
    /// changes nothing.
    public func advanced(by status: SessionStatus) -> HoldPhase {
        switch status {
        case .needsYou, .working, .waiting, .running: .started
        case .done, .finished: .finished
        case .idle, .shell: self == .started ? .finished : self
        case .stale, .unknown: self
        }
    }
}

/// Keeps every session's status, and moves holds along as the sessions they wait for change.
/// Each refresh only works out again the sessions whose inputs changed and the sessions waiting
/// for them, up their chains: a session on hold isn't worked out again until what it waits for moves.
public struct StatusEngine: Sendable {
    public private(set) var statuses: [Agent.ID: SessionStatus] = [:]
    private var own: [Agent.ID: OwnStatus] = [:]
    private var holds: [Agent.ID: [Hold]] = [:]

    public init() {}

    /// Takes in each session's own inputs and the holds as recorded, and returns the holds as they
    /// should now be recorded, with phases moved along.
    @discardableResult
    public mutating func settle(own newOwn: [Agent.ID: OwnStatus], holds newHolds: [Agent.ID: [Hold]]) -> [Agent.ID: [Hold]] {
        var changed = Set<Agent.ID>()
        for (id, value) in newOwn where own[id] != value { changed.insert(id) }
        for id in own.keys where newOwn[id] == nil {
            statuses[id] = nil
            changed.insert(id)
        }
        // A hold added, removed or read back from Herdr catches up with what its session is doing.
        for waiter in Set(newHolds.keys).union(holds.keys) where newHolds[waiter] != holds[waiter] { changed.insert(waiter) }
        own = newOwn
        holds = newHolds

        var waitersOf: [Agent.ID: [Agent.ID]] = [:]
        for (waiter, list) in holds { for hold in list { waitersOf[hold.awaited, default: []].append(waiter) } }
        // What changed, and everything waiting for it, however far up.
        var affected = Set<Agent.ID>()
        var pending = Array(changed)
        while let id = pending.popLast() {
            guard affected.insert(id).inserted else { continue }
            pending += waitersOf[id] ?? []
        }
        var resolved = Set<Agent.ID>()
        var visiting = Set<Agent.ID>()
        for id in affected.sorted(by: Self.order) { resolve(id, affected: affected, resolved: &resolved, visiting: &visiting) }
        return holds
    }

    /// Works out a session after the sessions it waits for, so each hold moves with their final
    /// status. A session outside what changed keeps its status; a loop of holds uses the last one.
    private mutating func resolve(_ id: Agent.ID, affected: Set<Agent.ID>, resolved: inout Set<Agent.ID>,
                                  visiting: inout Set<Agent.ID>) {
        guard affected.contains(id), !resolved.contains(id), visiting.insert(id).inserted else { return }
        if var list = holds[id] {
            for index in list.indices {
                let awaited = list[index].awaited
                resolve(awaited, affected: affected, resolved: &resolved, visiting: &visiting)
                if let status = statuses[awaited] { list[index].phase = list[index].phase.advanced(by: status) }
            }
            holds[id] = list
        }
        visiting.remove(id)
        resolved.insert(id)
        guard let input = own[id] else { return }
        statuses[id] = SessionStatus.of(input, isHeld: holds[id]?.contains { $0.phase != .finished } == true)
    }

    private static func order(_ lhs: Agent.ID, _ rhs: Agent.ID) -> Bool {
        (lhs.machineID, lhs.terminalID) < (rhs.machineID, rhs.terminalID)
    }
}
