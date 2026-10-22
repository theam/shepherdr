import Foundation

/// The overview's choice of statuses and machines: sessions in any chosen status, on any chosen
/// machine. Choosing nothing in either includes everything. A machine that isn't answering only
/// shows its last known state, so choosing statuses leaves its sessions out.
public struct SessionFilter: Equatable, Sendable {
    public var states: Set<SessionStatus> = []
    public var machines: Set<String> = []

    public init(states: Set<SessionStatus> = [], machines: Set<String> = []) {
        self.states = states
        self.machines = machines
    }

    public var isEmpty: Bool { states.isEmpty && machines.isEmpty }

    public func includes(_ row: AgentRow, status: SessionStatus) -> Bool {
        includes(status) && includesMachine(of: row)
    }

    /// Sessions in a status on the chosen machines: what choosing that status alone would add.
    public func count(_ state: SessionStatus, in rows: [AgentRow], status: (AgentRow) -> SessionStatus) -> Int {
        rows.filter { status($0) == state && includesMachine(of: $0) }.count
    }

    /// Sessions on a machine in the chosen statuses.
    public func count(machine id: String, in rows: [AgentRow], status: (AgentRow) -> SessionStatus) -> Int {
        rows.filter { $0.id.machineID == id && includes(status($0)) }.count
    }

    public mutating func toggle(_ state: SessionStatus) {
        if states.remove(state) == nil { states.insert(state) }
    }

    public mutating func toggle(machine id: String) {
        if machines.remove(id) == nil { machines.insert(id) }
    }

    /// Forgets machines that are gone, so they can't hide every session.
    public mutating func keep(machines present: Set<String>) {
        machines.formIntersection(present)
    }

    private func includes(_ status: SessionStatus) -> Bool { states.isEmpty || states.contains(status) }

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
