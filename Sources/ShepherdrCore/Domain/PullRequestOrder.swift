import Foundation

/// One step of the suggested order for the inbox's pull requests: which one, what to do with it and why.
public struct PullRequestStep: Identifiable, Hashable, Sendable {
    /// What a pull request needs from you, in the order they're taken on.
    public enum Action: Int, Comparable, Sendable {
        /// Yours, approved and green: merging it is quick, ships it and unblocks what builds on it.
        case merge
        /// Someone else's, waiting on your review: they're blocked until you answer.
        case review
        /// Yours: a reviewer asked for changes.
        case address
        /// Yours: it conflicts with the branch it merges into, which can keep its checks from running.
        case resolve
        /// Yours: its checks failed.
        case fix
        /// Yours, still a draft.
        case finish
        /// Yours, with nothing to do yet: waiting for reviewers, for its checks, or for the pull
        /// request it's stacked on.
        case wait

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public let item: GitHubInboxItem
    public let action: Action
    /// Why, the reason for the action first: `approved`, `2 of 5 checks failed`, `+12 −3 · 2 files`…
    public let reasons: [String]
    /// The listed pull request this one is stacked on: its base branch is the other's own.
    public let stackedOn: GitHubInboxItem?

    public init(item: GitHubInboxItem, action: Action, reasons: [String], stackedOn: GitHubInboxItem? = nil) {
        self.item = item
        self.action = action
        self.reasons = reasons
        self.stackedOn = stackedOn
    }

    public var id: String { item.key }
}

/// Suggests an order for the inbox's pull requests from what GitHub says about them.
public enum PullRequestOrder {
    /// The pull requests among `items`, in the order to take them on: actions in their order and,
    /// within one, ready ones before those held up (failing checks or conflicts mean it will change),
    /// smaller before larger and older before newer. A pull request stacked on another listed one goes
    /// right after it, and isn't merged before it, unless that one is only waiting.
    public static func steps(for items: [GitHubInboxItem], checks: [String: PullRequestChecks],
                             now: Date = Date()) -> [PullRequestStep] {
        let pulls = items.filter(\.isPullRequest)
        // A fork's branch lives in another repository: nothing here can be stacked on it.
        var branches: [String: GitHubInboxItem] = [:]
        for pull in pulls {
            guard let details = pull.details, !details.isFromFork else { continue }
            let key = "\(pull.repository.id):\(details.headBranch)"
            if branches[key] == nil { branches[key] = pull }
        }
        let ranked = pulls.map { pull in
            let base = pull.details.flatMap { branches["\(pull.repository.id):\($0.baseBranch)"] }
            return step(pull, checks: checks[pull.key], stackedOn: base?.key == pull.key ? nil : base, now: now)
        }
        return afterTheirBases(ranked.sorted { $0.rank < $1.rank }.map(\.step))
    }

    private struct Rank: Comparable {
        let action: PullRequestStep.Action
        /// 0 ready, 1 its checks still run, 2 its checks failed or it conflicts, 3 a draft.
        let readiness: Int
        let size: Int
        let createdAt: Date
        let key: String

        static func < (lhs: Rank, rhs: Rank) -> Bool {
            (lhs.action.rawValue, lhs.readiness, lhs.size, lhs.createdAt, lhs.key)
                < (rhs.action.rawValue, rhs.readiness, rhs.size, rhs.createdAt, rhs.key)
        }
    }

    private static func step(_ pull: GitHubInboxItem, checks: PullRequestChecks?, stackedOn base: GitHubInboxItem?,
                             now: Date) -> (step: PullRequestStep, rank: Rank) {
        let details = pull.details
        let state = checks?.state
        let conflicts = details?.hasConflicts == true
        let action: PullRequestStep.Action
        if pull.kind == .reviewRequested {
            action = .review
        } else if pull.isDraft {
            action = .finish
        } else if pull.reviewDecision == "CHANGES_REQUESTED" {
            action = .address
        } else if conflicts {
            action = .resolve
        } else if state == .failed {
            action = .fix
        } else if pull.reviewDecision == "APPROVED", state != .running, base == nil {
            action = .merge
        } else {
            action = .wait
        }

        let stacked = base.map { "stacked on #\($0.number)" }
        let draft = pull.isDraft ? "draft" : nil
        let decision: String? = switch pull.reviewDecision {
        case _ where pull.kind == .reviewRequested || pull.isDraft: nil
        case "APPROVED": "approved"
        case "CHANGES_REQUESTED": "changes requested"
        default: "waiting for review"
        }
        let conflict = details.flatMap { $0.hasConflicts ? "conflicts with \($0.baseBranch)" : nil }
        let checked = checks.map(describe)
        let lead: String? = switch action {
        case .merge, .address: decision
        case .review: nil
        case .resolve: conflict
        case .fix: checked
        case .finish: draft
        case .wait: stacked ?? (state == .running ? checked : decision)
        }
        var reasons = [pull.kind == .reviewRequested ? "by @\(pull.author)" : nil, stacked, draft, decision, conflict, checked]
            .compactMap { $0 }
        if let details { reasons += [size(details), "open \(age(since: details.createdAt, now: now))"] }
        if let lead, let index = reasons.firstIndex(of: lead) { reasons.insert(reasons.remove(at: index), at: 0) }

        let readiness = pull.isDraft ? 3 : state == .failed || conflicts ? 2 : state == .running ? 1 : 0
        let lines = details.map { $0.additions + $0.deletions }
        let bucket = switch lines {
        case nil: 2
        case let lines?: lines <= 10 ? 0 : lines <= 100 ? 1 : lines <= 500 ? 2 : lines <= 1_000 ? 3 : 4
        }
        return (PullRequestStep(item: pull, action: action, reasons: reasons, stackedOn: base),
                Rank(action: action, readiness: readiness, size: bucket, createdAt: details?.createdAt ?? pull.updatedAt, key: pull.key))
    }

    /// Moves each step ranked before the pull request it's stacked on to right after it. Pull requests
    /// that are only waiting hold nothing back, and stacks that loop keep their rank.
    private static func afterTheirBases(_ steps: [PullRequestStep]) -> [PullRequestStep] {
        let actions = Dictionary(steps.map { ($0.id, $0.action) }, uniquingKeysWith: { first, _ in first })
        var ordered: [PullRequestStep] = []
        var placed = Set<String>()
        var held: [String: [PullRequestStep]] = [:]
        func place(_ step: PullRequestStep) {
            guard placed.insert(step.id).inserted else { return }
            ordered.append(step)
            for next in held.removeValue(forKey: step.id) ?? [] { place(next) }
        }
        for step in steps {
            if let base = step.stackedOn, !placed.contains(base.key), actions[base.key] != .wait {
                held[base.key, default: []].append(step)
            } else {
                place(step)
            }
        }
        for step in steps { place(step) }
        return ordered
    }

    /// `checks passed`, `2 of 5 checks failed`, `checks running`, `no checks`.
    private static func describe(_ checks: PullRequestChecks) -> String {
        switch checks.state {
        case .passed: "checks passed"
        case .failed: "\(checks.failed) of \(checks.passed + checks.failed + checks.running) checks failed"
        case .running: "checks running"
        case .none: "no checks"
        }
    }

    /// `+12 −3 · 2 files`.
    private static func size(_ details: PullRequestDetails) -> String {
        "+\(details.additions) −\(details.deletions) · \(details.changedFiles) file\(details.changedFiles == 1 ? "" : "s")"
    }

    /// `5m`, `3h`, `2d`.
    static func age(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<3_600: return "\(max(1, seconds / 60))m"
        case ..<86_400: return "\(seconds / 3_600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}
