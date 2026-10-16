import Foundation
import Observation

/// A followed repository; paused ones stay on the list without being asked about.
public struct WatchedRepository: Codable, Hashable, Sendable, Identifiable {
    public let repository: InboxRepository
    public var isPaused: Bool

    public init(repository: InboxRepository, isPaused: Bool = false) {
        self.repository = repository
        self.isPaused = isPaused
    }

    public var id: String { repository.id }
}

/// The repositories whose issues and pull requests the GitHub inbox follows, and which items
/// you've already seen. Device-local preferences, like priorities.
@MainActor @Observable
public final class GitHubInboxStore {
    /// In the order they were added.
    public private(set) var repositories: [WatchedRepository]
    /// Each seen item's key and when it had last changed when you saw it. An item changed since
    /// counts as unseen again.
    public private(set) var seen: [String: Date]
    @ObservationIgnored private let defaults: UserDefaults
    static let storageKey = "githubInbox.v1"

    private struct Record: Codable {
        var repositories: [WatchedRepository]
        var seen: [String: Date]
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let record = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        var ids = Set<String>()
        repositories = (record?.repositories ?? []).filter { ids.insert($0.id).inserted }
        seen = record?.seen ?? [:]
    }

    /// The repositories to ask GitHub about.
    public var activeRepositories: [InboxRepository] { repositories.filter { !$0.isPaused }.map(\.repository) }

    /// Follows a repository, or resumes it if it was paused.
    public func add(_ repository: InboxRepository) {
        if let index = repositories.firstIndex(where: { $0.id == repository.id }) {
            guard repositories[index].isPaused else { return }
            repositories[index].isPaused = false
        } else {
            repositories.append(WatchedRepository(repository: repository))
        }
        save()
    }

    /// Stops following a repository and forgets which of its items you saw.
    public func remove(_ repository: InboxRepository) {
        guard repositories.contains(where: { $0.id == repository.id }) else { return }
        repositories.removeAll { $0.id == repository.id }
        let prefix = "github.com/\(repository.id)#"
        seen = seen.filter { !$0.key.hasPrefix(prefix) }
        save()
    }

    public func setPaused(_ repository: InboxRepository, _ paused: Bool) {
        guard let index = repositories.firstIndex(where: { $0.id == repository.id }),
              repositories[index].isPaused != paused else { return }
        repositories[index].isPaused = paused
        save()
    }

    public func markSeen(_ item: GitHubInboxItem) {
        guard isUnseen(item) else { return }
        seen[item.key] = item.updatedAt
        save()
    }

    public func markUnseen(_ item: GitHubInboxItem) {
        guard seen.removeValue(forKey: item.key) != nil else { return }
        save()
    }

    /// Never seen, or changed since you saw it.
    public func isUnseen(_ item: GitHubInboxItem) -> Bool {
        guard let date = seen[item.key] else { return true }
        return date < item.updatedAt
    }

    public func unseen(_ items: [GitHubInboxItem]) -> [GitHubInboxItem] { items.filter(isUnseen) }

    private func save() {
        if let data = try? JSONEncoder().encode(Record(repositories: repositories, seen: seen)) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
