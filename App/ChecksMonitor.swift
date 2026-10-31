import AppKit
import ShepherdrCore

/// Whether Shepherdr can be seen: a window of it shows, the displays are awake, the screen isn't
/// locked, and this user's session is the active one. Work that only matters while you look slows
/// down or waits while it can't be: other machines' refreshes, CI checks, machine load and the
/// commands agents left running.
@MainActor
final class ScreenPresence {
    private(set) var isOnScreen = true
    private var windowShows = true, displaysAwake = true, unlocked = true, sessionActive = true
    private var handlers: [(Bool) -> Void] = []
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAwake = false }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAwake = true }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked")) { $0.unlocked = false }
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked")) { $0.unlocked = true }
        // Hidden, minimized or covered windows all leave the app occluded.
        observe(NotificationCenter.default, NSApplication.didChangeOcclusionStateNotification) {
            $0.windowShows = NSApplication.shared.occlusionState.contains(.visible)
        }
    }

    /// Tells `handler` whenever Shepherdr comes on screen or leaves it.
    func onChange(_ handler: @escaping (Bool) -> Void) { handlers.append(handler) }

    /// Returns once Shepherdr is on screen, right away if it is, or when the task is cancelled.
    func untilOnScreen() async {
        guard !isOnScreen else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if isOnScreen || Task.isCancelled { continuation.resume() } else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: id)?.resume() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (ScreenPresence) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.update()
            }
        }
        observers.append((center, token))
    }

    private func update() {
        let now = windowShows && displaysAwake && unlocked && sessionActive
        guard now != isOnScreen else { return }
        isOnScreen = now
        if now {
            let resumed = waiters
            waiters = [:]
            resumed.values.forEach { $0.resume() }
        }
        handlers.forEach { $0(now) }
    }
}

/// Watches the CI checks of the pull requests of the session on screen, and whether its issues are
/// still open, through the GitHub CLI: one GraphQL query for its pull requests and one for its
/// issues, every 15 seconds while checks run and every 2 minutes once they're done, paused while
/// Shepherdr isn't on screen. A notification tells you when checks finish. What it learns goes into
/// the GitHub cache, so every session's pull requests show their last known state from launch, and
/// merged or closed ones are never asked about again.
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
        let pauses: [(Notification.Name, Bool)] = [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)]
        observers = pauses.map { name, asleep in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isAsleep = asleep
                    if !asleep { self?.lookAgain() }
                }
            }
        }
    }

    /// Starts from what an earlier launch learned.
    func restore(from cache: GitHubCache) {
        checks = cache.checks.mapValues(\.value)
        issues = cache.issues.mapValues(\.value)
    }

    /// Checks learned elsewhere, such as by the GitHub inbox: kept, and shown, without a notification.
    func absorb(_ found: [String: PullRequestChecks]) {
        for (key, latest) in found where checks[key] != latest { checks[key] = latest }
        model?.githubCache.remember(checks: found)
    }

    /// Back awake or back on screen: looks right away rather than at the next tick.
    func lookAgain() {
        if let watched { restart(watching: watched) }
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
    /// With `includingDone`, merged and closed ones are asked about too, in case they were reopened.
    func refresh(_ id: Agent.ID, includingDone: Bool = false) {
        if id == watched { restart(watching: id, includingDone: includingDone) } else { Task { _ = await poll(id, includingDone: includingDone) } }
    }

    private func restart(watching id: Agent.ID, includingDone: Bool = false) {
        guard gitHub.isAvailable else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            var includingDone = includingDone
            while !Task.isCancelled {
                guard let self else { return }
                defer { includingDone = false }
                let delay: Duration = switch await self.poll(id, includingDone: includingDone) {
                case .running: .seconds(15)
                case .settled: .seconds(120)
                case .unanswered: .seconds(300)
                }
                try? await Task.sleep(for: delay)
            }
        }
    }

    private enum Poll { case running, settled, unanswered }

    private func poll(_ id: Agent.ID, includingDone: Bool = false) async -> Poll {
        guard !isAsleep, let model, model.presence.isOnScreen else { return .settled }
        await pollIssues(id, model: model, includingDone: includingDone)
        // Open pull requests only: merged and closed ones are done.
        let pulls = model.pullRequests(of: id).filter { $0.github != nil && (includingDone || checks[$0.key]?.isOpen != false) }.prefix(10)
        guard !pulls.isEmpty else { return .settled }
        // No answer, such as a spent GitHub budget: look again much later.
        guard let found = await gitHub.checks(of: Array(pulls)) else { return .unanswered }
        model.githubCache.remember(checks: found)
        for pull in pulls {
            guard let latest = found[pull.key] else { continue }
            let previous = checks[pull.key]
            // Rows with pull requests read these: only a change should redraw them.
            if previous != latest { checks[pull.key] = latest }
            if latest.justFinished(after: previous) { model.notifier.checksFinished(pull, latest, in: id) }
        }
        return found.values.contains { $0.isOpen && $0.isRunning } ? .running : .settled
    }

    /// Open issues only, like pull requests: closed ones are done.
    private func pollIssues(_ id: Agent.ID, model: AppModel, includingDone: Bool) async {
        let open = model.issues(of: id).filter { $0.github != nil && (includingDone || issues[$0.key]?.isOpen != false) }.prefix(10)
        guard !open.isEmpty, let found = await gitHub.issueStates(of: Array(open)) else { return }
        issues.merge(found) { _, latest in latest }
        model.githubCache.remember(issues: found)
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
