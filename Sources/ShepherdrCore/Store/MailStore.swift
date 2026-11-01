import Foundation
import Observation

/// Letters from agents that wait for something, and which letters Shepherdr already read, so a
/// letter is acted on once though it waits in its outbox until some Shepherdr claims it. Saved across
/// launches: what items say and where their files are kept, never the files themselves.
@MainActor @Observable
public final class MailStore {
    public private(set) var items: [MailItem]
    /// Letters already read, by machine and letter ID, with when; forgotten after a month.
    @ObservationIgnored private var seen: [String: Date]
    /// The doorbell each pane last rang that Shepherdr answered, by machine and terminal.
    @ObservationIgnored private var answered: [String: [String: String]] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    static let itemsKey = "mail.v1"
    static let seenKey = "mail.seen.v1"
    static let memory: TimeInterval = 30 * 86_400

    public init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        items = defaults.data(forKey: Self.itemsKey).flatMap { try? JSONDecoder().decode([MailItem].self, from: $0) } ?? []
        let saved = defaults.dictionary(forKey: Self.seenKey) as? [String: Date] ?? [:]
        seen = saved.filter { now.timeIntervalSince($0.value) < Self.memory }
    }

    // MARK: Letters read

    public func hasRead(_ letterID: String, from machineID: String) -> Bool {
        seen["\(machineID)/\(letterID)"] != nil
    }

    public func markRead(_ letterIDs: [String], from machineID: String, at date: Date = Date()) {
        guard !letterIDs.isEmpty else { return }
        for id in letterIDs { seen["\(machineID)/\(id)"] = date }
        defaults.set(seen, forKey: Self.seenKey)
    }

    /// Letters read from a machine recently enough to still wait in its outbox, the newest first:
    /// letters stay there until a Shepherdr claims them, or for a week. A trip skips them.
    public func recentlyRead(from machineID: String, limit: Int = 500, now: Date = Date()) -> [String] {
        let prefix = "\(machineID)/"
        return seen.filter { $0.key.hasPrefix(prefix) && now.timeIntervalSince($0.value) < 8 * 86_400 }
            .map { String($0.key.dropFirst(prefix.count)) }
            .sorted(by: >)
            .prefix(limit)
            .map { $0 }
    }

    // MARK: Doorbells

    /// Whether any pane on a machine rang since Shepherdr last collected there.
    public func hasNewDoorbells(_ doorbells: [String: String], on machineID: String) -> Bool {
        let known = answered[machineID] ?? [:]
        return doorbells.contains { known[$0.key] != $0.value }
    }

    /// The doorbells a collection answered: the ones it saw before it started.
    public func answer(_ doorbells: [String: String], on machineID: String) {
        answered[machineID, default: [:]].merge(doorbells) { _, new in new }
    }

    // MARK: Items

    public func add(_ item: MailItem) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        save()
    }

    public func update(_ id: String, _ change: (inout MailItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        items[index] = item
        save()
    }

    public func remove(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        save()
    }

    public func item(_ id: String) -> MailItem? { items.first { $0.id == id } }

    /// A session's mail: what is for it, and what it sent that needs the user.
    public func items(for session: Agent.ID) -> [MailItem] {
        items.filter { $0.recipient == session || ($0.sender == session && $0.recipient == nil) }
    }

    /// Mail that waits for the user, oldest first.
    public var needingUser: [MailItem] { items.filter(\.needsUser) }

    /// Whether a session has mail that waits for the user.
    public func needsUser(_ session: Agent.ID) -> Bool {
        items(for: session).contains(where: \.needsUser)
    }

    private func save() {
        // Short summaries and paths only; messages and files stay in the inbox.
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.itemsKey) }
    }
}
