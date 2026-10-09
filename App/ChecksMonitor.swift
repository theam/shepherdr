import AppKit
import ShepherdrCore

/// Watches the CI checks of the pull requests of the session on screen, and whether its issues are
/// still open, through the GitHub CLI: one GraphQL query for its pull requests and one for its
/// issues, every 15 seconds while checks run and every 2 minutes once they're done, paused while
/// the Mac sleeps. A notification tells you when checks finish.
@MainActor @Observable
final class ChecksMonitor {
    /// The last known checks of each pull request, by resource key.
    private(set) var checks: [String: PullRequestChecks] = [:]
    /// The last known state of each issue, by resource key.
    private(set) var issues: [String: IssueState] = [:]
    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let gitHub = GitHubLookup()
    @ObservationIgnored private var watched: Agent.ID?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let pauses: [(Notification.Name, Bool)] = [
            (NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false),
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        observers = pauses.map { name, asleep in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isAsleep = asleep
                    // Back awake: look right away rather than at the next tick.
                    if !asleep, let watched = self?.watched { self?.restart(watching: watched) }
                }
            }
        }
    }

    /// Watches the session on screen, and stops watching the previous one.
    func watch(_ id: Agent.ID?) {
        guard id != watched else { return }
        watched = id
        loop?.cancel()
        loop = nil
        if let id { restart(watching: id) }
    }

    /// Looks again now, such as when a session's agent finished a turn and may have pushed.
    func refresh(_ id: Agent.ID) {
        if id == watched { restart(watching: id) } else { Task { _ = await poll(id) } }
    }

    private func restart(watching id: Agent.ID) {
        guard gitHub.isAvailable else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay: Duration = switch await self.poll(id) {
                case .running: .seconds(15)
                case .settled: .seconds(120)
                case .unanswered: .seconds(300)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private enum Poll { case running, settled, unanswered }

    private func poll(_ id: Agent.ID) async -> Poll {
        guard !isAsleep, let model else { return .settled }
        await pollIssues(id, model: model)
        // Open pull requests only: merged and closed ones are done.
        let pulls = model.pullRequests(of: id).filter { $0.github != nil && checks[$0.key]?.isOpen != false }.prefix(10)
        guard !pulls.isEmpty else { return .settled }
        // No answer, such as a spent GitHub budget: look again much later.
        guard let found = await gitHub.checks(of: Array(pulls)) else { return .unanswered }
        for pull in pulls {
            guard let latest = found[pull.key] else { continue }
            let previous = checks[pull.key]
            checks[pull.key] = latest
            if latest.justFinished(after: previous) { model.notifier.checksFinished(pull, latest, in: id) }
        }
        return found.values.contains { $0.isOpen && $0.isRunning } ? .running : .settled
    }

    /// Open issues only, like pull requests: closed ones are done.
    private func pollIssues(_ id: Agent.ID, model: AppModel) async {
        let open = model.issues(of: id).filter { $0.github != nil && issues[$0.key]?.isOpen != false }.prefix(10)
        guard !open.isEmpty, let found = await gitHub.issueStates(of: Array(open)) else { return }
        issues.merge(found) { _, latest in latest }
    }

    /// One mark for several pull requests.
    func state(of pulls: [SessionResource]) -> PullRequestChecks.State? {
        PullRequestChecks.combined(pulls.compactMap { checks[$0.key] })
    }

    /// How a pull request or issue ended: landed (merged, or completed) or dropped (closed without
    /// merging, not planned, a duplicate).
    enum Outcome { case landed, dropped }

    /// Nil while it's open or GitHub hasn't said.
    func outcome(of resource: SessionResource) -> Outcome? {
        if let pull = checks[resource.key], !pull.isOpen { return pull.isMerged ? .landed : .dropped }
        return switch issues[resource.key] {
        case .completed: .landed
        case .notPlanned, .duplicate: .dropped
        case .open, nil: nil
        }
    }

    /// How several pull requests ended: nil while any may still be open, landed if any merged.
    func outcome(of pulls: [SessionResource]) -> Outcome? {
        let outcomes = pulls.map(outcome(of:))
        guard !outcomes.isEmpty, !outcomes.contains(nil) else { return nil }
        return outcomes.contains(.landed) ? .landed : .dropped
    }
}
