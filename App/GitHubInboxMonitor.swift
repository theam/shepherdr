import Foundation
import ShepherdrCore

/// Asks GitHub, through its CLI, what the followed repositories ask of you: issues assigned to you,
/// pull requests awaiting your review and your own open pull requests, in one query. A failed sync
/// keeps the last answer on screen.
@MainActor @Observable
final class GitHubInboxMonitor {
    /// The last answer GitHub gave, kept through failed syncs.
    private(set) var inbox: GitHubInbox?
    private(set) var isSyncing = false
    /// Why the last sync failed; nil once one succeeds.
    private(set) var error: GitHubSyncError?
    /// The inbox pull requests' checks by item key, from the last sync GitHub answered; kept when
    /// asking for them fails.
    private(set) var checks: [String: PullRequestChecks] = [:]
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let gitHub = GitHubLookup()
    @ObservationIgnored private var syncTask: Task<Void, Never>?

    /// How old an answer can be before showing the home screen asks again.
    static let freshness: TimeInterval = 300

    /// Syncs if it never did, or if the last answer is more than five minutes old. Called when the
    /// home screen appears.
    func syncIfNeeded() async {
        if let inbox, Date().timeIntervalSince(inbox.syncedAt) <= Self.freshness { return }
        await sync()
    }

    /// Syncs now, for the manual button. A sync already under way isn't repeated: this waits for it.
    func sync() async {
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await run() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func run() async {
        isSyncing = true
        defer { isSyncing = false }
        let repositories = model?.githubInbox.activeRepositories ?? []
        switch await gitHub.inbox(repositories: repositories, includeMyPullRequests: true) {
        case .success(let found):
            inbox = found
            error = nil
            let pulls = found.items.filter(\.isPullRequest).map(\.resource)
            if pulls.isEmpty {
                checks = [:]
            } else if let found = await gitHub.checks(of: pulls) {
                checks = found
            }
        case .failure(let failure):
            error = failure
        }
    }
}

extension GitHubSyncError {
    /// A short headline and what to do about it, in the user's words.
    var notice: (title: String, message: String, detail: String?) {
        switch self {
        case .notInstalled:
            ("Install the GitHub CLI",
             "The inbox asks GitHub through its CLI, gh, which isn't installed on this Mac.",
             "Install it with `brew install gh` (or from https://cli.github.com), sign in with `gh auth login` and press SYNC.")
        case .signedOut:
            ("Sign in to the GitHub CLI",
             "gh is installed but not signed in.",
             "Run `gh auth login` in a terminal and press SYNC.")
        case .rateLimited(let resetAt):
            ("GitHub's rate limit ran out",
             resetAt.map { "GitHub answers again from \($0.formatted(date: .omitted, time: .shortened))." }
                ?? "Try again later.",
             nil)
        case .failed(let message):
            ("Couldn't sync with GitHub", "GitHub didn't return the inbox. Press SYNC to try again.", message)
        }
    }
}
