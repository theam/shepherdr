import Foundation

/// The overview's choice of states and machines: sessions in any chosen state, on any chosen
/// machine. Choosing nothing in either includes everything. A machine that isn't answering only
/// shows its last known state, so choosing states leaves its sessions out.
public struct SessionFilter: Equatable, Sendable {
    public var states: Set<AgentState> = []
    public var machines: Set<String> = []

    public init(states: Set<AgentState> = [], machines: Set<String> = []) {
        self.states = states
        self.machines = machines
    }

    public var isEmpty: Bool { states.isEmpty && machines.isEmpty }

    public func includes(_ row: AgentRow) -> Bool { includesState(of: row) && includesMachine(of: row) }

    /// Sessions in a state on the chosen machines: what choosing that state alone would add.
    public func count(_ state: AgentState, in rows: [AgentRow]) -> Int {
        rows.filter { !$0.isStale && $0.agent.state == state && includesMachine(of: $0) }.count
    }

    /// Sessions on a machine in the chosen states.
    public func count(machine id: String, in rows: [AgentRow]) -> Int {
        rows.filter { $0.id.machineID == id && includesState(of: $0) }.count
    }

    public mutating func toggle(_ state: AgentState) {
        if states.remove(state) == nil { states.insert(state) }
    }

    public mutating func toggle(machine id: String) {
        if machines.remove(id) == nil { machines.insert(id) }
    }

    /// Forgets machines that are gone, so they can't hide every session.
    public mutating func keep(machines present: Set<String>) {
        machines.formIntersection(present)
    }

    private func includesState(of row: AgentRow) -> Bool {
        states.isEmpty || (!row.isStale && states.contains(row.agent.state))
    }

    private func includesMachine(of row: AgentRow) -> Bool {
        machines.isEmpty || machines.contains(row.id.machineID)
    }
}

/// A folder agents work in, and how many of them do; and how many shells, still without an
/// agent, are open there.
public struct FolderUse: Equatable, Sendable {
    public let path: String
    public let agents: Int
    public let shells: Int

    public init(path: String, agents: Int, shells: Int = 0) {
        self.path = path
        self.agents = agents
        self.shells = shells
    }

    /// The folders of these sessions' agents, the most used first, then those only shells are open
    /// in, leaving out agents `excluded` says to, such as worktrees.
    public static func ranked(_ rows: [AgentRow], shells: [String?] = [], excluding excluded: (AgentRow) -> Bool = { _ in false },
                              limit: Int = 8) -> [FolderUse] {
        func folder(_ directory: String?) -> String? {
            guard var path = directory?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return nil }
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return path
        }
        var counts: [String: (agents: Int, shells: Int)] = [:]
        for row in rows where !excluded(row) {
            if let path = folder(row.agent.directory) { counts[path, default: (0, 0)].agents += 1 }
        }
        for path in shells.compactMap(folder) { counts[path, default: (0, 0)].shells += 1 }
        return counts.map { FolderUse(path: $0.key, agents: $0.value.agents, shells: $0.value.shells) }
            .sorted {
                if $0.agents != $1.agents { return $0.agents > $1.agents }
                if $0.shells != $1.shells { return $0.shells > $1.shells }
                let names = ($0.path as NSString).lastPathComponent.localizedStandardCompare(($1.path as NSString).lastPathComponent)
                return names == .orderedSame ? $0.path < $1.path : names == .orderedAscending
            }
            .prefix(limit).map { $0 }
    }
}
