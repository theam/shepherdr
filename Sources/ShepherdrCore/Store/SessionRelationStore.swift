import Foundation
import Observation

/// Where a hold on one session stands. It only moves forward.
public enum HoldPhase: String, Codable, Sendable {
    /// Waiting for the session to start: a new session before its prompt, a shell before its command.
    case pending
    /// The session was seen working, needing you, waiting itself or running a command.
    case started
    /// It started and is free again, or its command ended.
    case finished
}

/// One session another one waits for, and how far along it is.
public struct Hold: Codable, Hashable, Sendable {
    public let awaited: Agent.ID
    public var phase: HoldPhase

    public init(awaited: Agent.ID, phase: HoldPhase = .pending) {
        self.awaited = awaited
        self.phase = phase
    }
}

/// Sessions put on hold while others work, such as a planner waiting for the subagents it
/// launched. Kept on this Mac with priorities, and mirrored into Herdr as tokens on each waiting
/// pane, from where a new Mac or a lost cache gets them back.
@MainActor @Observable
public final class SessionRelationStore {
    /// Each waiting session's holds, in the order they were added. Finished holds stay until the
    /// waiting session moves on, so a handoff that arrives late still finds who waited for it.
    public private(set) var holds: [Agent.ID: [Hold]]
    /// Waiting sessions whose awaited sessions the sidebar hides under them.
    public private(set) var collapsed: Set<Agent.ID>
    /// Waiting sessions whose holds changed here since Herdr last showed them: their tokens are
    /// rewritten from here, never read back. Kept across launches, so holds this Mac dropped
    /// while a machine was away don't come back from its tokens.
    public private(set) var unsynced: Set<Agent.ID>
    /// Called after holds change, such as to work out statuses again.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    static let storageKey = "sessionWaits.v1"
    static let unsyncedKey = "sessionWaits.unsynced.v1"

    private struct Record: Codable {
        let session: Agent.ID
        let waitingFor: [Agent.ID]
        /// Absent from records saved before sessions nested in the sidebar.
        var collapsed: Bool?
        /// Each hold's phase, in `waitingFor`'s order. Absent from records saved before phases,
        /// whose holds count as started: those sessions were already being waited for, so one
        /// that is free now has finished.
        var phases: [HoldPhase]?
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let records = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([Record].self, from: $0) } ?? []
        var holds: [Agent.ID: [Hold]] = [:]
        var collapsed = Set<Agent.ID>()
        for record in records where Self.isValid(record.session) && holds[record.session] == nil {
            var seen = Set<Agent.ID>()
            let kept = record.waitingFor.enumerated().compactMap { index, awaited -> Hold? in
                guard Self.isValid(awaited), awaited != record.session, seen.insert(awaited).inserted else { return nil }
                return Hold(awaited: awaited, phase: record.phases.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? .started)
            }
            guard !kept.isEmpty else { continue }
            holds[record.session] = kept
            if record.collapsed == true { collapsed.insert(record.session) }
        }
        self.holds = holds
        self.collapsed = collapsed
        let unsynced = defaults.data(forKey: Self.unsyncedKey)
            .flatMap { try? JSONDecoder().decode([Agent.ID].self, from: $0) } ?? []
        self.unsynced = Set(unsynced.filter(Self.isValid))
    }

    /// Each waiting session and the sessions it waits for, whatever their phase.
    public var waits: [Agent.ID: [Agent.ID]] { holds.mapValues { $0.map(\.awaited) } }

    public func waitingFor(_ id: Agent.ID) -> [Agent.ID] { holds[id]?.map(\.awaited) ?? [] }

    /// Whether a session is on hold: something it waits for hasn't finished.
    public func isHeld(_ id: Agent.ID) -> Bool { holds[id]?.contains { $0.phase != .finished } == true }

    /// Sessions waiting for this one.
    public func waiters(of id: Agent.ID) -> [Agent.ID] {
        holds.filter { $0.value.contains { $0.awaited == id } }.map(\.key).sorted(by: Self.stableOrder)
    }

    public func isWaiting(_ id: Agent.ID, for other: Agent.ID) -> Bool {
        holds[id]?.contains { $0.awaited == other } == true
    }

    public func phase(of id: Agent.ID, for other: Agent.ID) -> HoldPhase? {
        holds[id]?.first { $0.awaited == other }?.phase
    }

    /// Where the sidebar nests sessions: each awaited session in `order` hangs under the first
    /// session in `order` that waits for it. A wait that would close a loop leaves its session in place.
    public func parents(in order: [Agent.ID]) -> [Agent.ID: Agent.ID] {
        let shown = Set(order)
        var parents: [Agent.ID: Agent.ID] = [:]
        for waiter in order {
            for awaited in waitingFor(waiter) where shown.contains(awaited) && parents[awaited] == nil {
                var ancestor: Agent.ID? = waiter
                while let current = ancestor, current != awaited { ancestor = parents[current] }
                if ancestor == nil { parents[awaited] = waiter }
            }
        }
        return parents
    }

    public func isCollapsed(_ id: Agent.ID) -> Bool { collapsed.contains(id) }

    public func setCollapsed(_ id: Agent.ID, _ isCollapsed: Bool) {
        guard holds[id] != nil, collapsed.contains(id) != isCollapsed else { return }
        if isCollapsed { collapsed.insert(id) } else { collapsed.remove(id) }
        save()
    }

    /// Starts waiting for another session, as pending, or stops. Waiting again for one already
    /// waited for keeps its phase.
    public func setWaiting(_ id: Agent.ID, for other: Agent.ID, _ waiting: Bool) {
        guard id != other, Self.isValid(id), Self.isValid(other) else { return }
        var list = holds[id] ?? []
        if waiting {
            guard !list.contains(where: { $0.awaited == other }) else { return }
            list.append(Hold(awaited: other))
        } else {
            guard list.contains(where: { $0.awaited == other }) else { return }
            list.removeAll { $0.awaited == other }
        }
        set(list, for: id)
    }

    public func stopWaiting(_ id: Agent.ID) {
        guard holds[id] != nil else { return }
        set([], for: id)
    }

    /// Replaces a waiting session's holds, such as with phases moved along. Holds read back from
    /// Herdr come in `fromHerdr`, already in sync.
    public func setHolds(_ list: [Hold], for id: Agent.ID, fromHerdr: Bool = false) {
        guard Self.isValid(id) else { return }
        var seen = Set<Agent.ID>()
        let kept = list.filter { Self.isValid($0.awaited) && $0.awaited != id && seen.insert($0.awaited).inserted }
        guard kept != (holds[id] ?? []) else { return }
        set(kept, for: id, synced: fromHerdr)
    }

    /// Herdr shows a waiting session's holds as they are here.
    public func markSynced(_ id: Agent.ID) {
        guard unsynced.remove(id) != nil else { return }
        saveUnsynced()
    }

    /// Drops a session that was closed: it no longer waits, and nothing waits for it.
    public func forget(_ id: Agent.ID) {
        var changed = holds.removeValue(forKey: id) != nil
        collapsed.remove(id)
        // Its pane, and its tokens with it, are gone.
        if unsynced.remove(id) != nil { saveUnsynced() }
        for (waiter, list) in holds where list.contains(where: { $0.awaited == id }) {
            let remaining = list.filter { $0.awaited != id }
            holds[waiter] = remaining.isEmpty ? nil : remaining
            if remaining.isEmpty { collapsed.remove(waiter) }
            markUnsynced(waiter)
            changed = true
        }
        guard changed else { return }
        save()
        onChange?()
    }

    private func set(_ list: [Hold], for id: Agent.ID, synced: Bool = false) {
        holds[id] = list.isEmpty ? nil : list
        if list.isEmpty { collapsed.remove(id) }
        if synced { markSynced(id) } else { markUnsynced(id) }
        save()
        onChange?()
    }

    private func markUnsynced(_ id: Agent.ID) {
        guard unsynced.insert(id).inserted else { return }
        saveUnsynced()
    }

    private func saveUnsynced() {
        if let data = try? JSONEncoder().encode(unsynced.sorted(by: Self.stableOrder)) { defaults.set(data, forKey: Self.unsyncedKey) }
    }

    private static func isValid(_ id: Agent.ID) -> Bool { !id.machineID.isEmpty && !id.terminalID.isEmpty }

    private static func stableOrder(_ lhs: Agent.ID, _ rhs: Agent.ID) -> Bool {
        (lhs.machineID, lhs.terminalID) < (rhs.machineID, rhs.terminalID)
    }

    private func save() {
        // Session identifiers and phases only, like saved priorities.
        let records = holds.keys.sorted(by: Self.stableOrder).map { id -> Record in
            let list = holds[id] ?? []
            return Record(session: id, waitingFor: list.map(\.awaited), collapsed: collapsed.contains(id) ? true : nil,
                          phases: list.map(\.phase))
        }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) }
    }
}
