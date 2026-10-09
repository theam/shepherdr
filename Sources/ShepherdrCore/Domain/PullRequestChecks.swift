import Foundation

/// Where a pull request's checks stand: CI runs and commit statuses on its latest commit.
public struct PullRequestChecks: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// No checks report on the pull request.
        case none
        case running, passed, failed
    }

    public let passed: Int
    public let failed: Int
    public let running: Int
    /// Merged and closed pull requests are no longer watched.
    public let isOpen: Bool
    public let isMerged: Bool
    /// The latest commit: a new push restarts the checks.
    public let head: String

    public init(passed: Int, failed: Int, running: Int, isOpen: Bool, isMerged: Bool = false, head: String) {
        self.passed = passed
        self.failed = failed
        self.running = running
        self.isOpen = isOpen
        self.isMerged = isMerged
        self.head = head
    }

    /// The worst news so far: a failure shows as soon as one check fails, even while others run.
    public var state: State {
        if failed > 0 { return .failed }
        if running > 0 { return .running }
        return passed > 0 ? .passed : .none
    }

    public var isRunning: Bool { running > 0 }

    /// Whether these checks just finished: they were running on the same commit before, and the pull
    /// request is still open. A new push starts over rather than finishing.
    public func justFinished(after previous: PullRequestChecks?) -> Bool {
        guard let previous, previous.isRunning, !isRunning, previous.head == head, isOpen else { return false }
        return state == .passed || state == .failed
    }

    /// One mark for several open pull requests: failed if any failed, running if any runs, passed if all passed.
    public static func combined(_ checks: [PullRequestChecks]) -> State? {
        let states = checks.filter(\.isOpen).map(\.state)
        if states.contains(.failed) { return .failed }
        if states.contains(.running) { return .running }
        return states.contains(.passed) ? .passed : nil
    }

    /// `3 passed · 1 failed · 2 running`.
    public var summary: String {
        [(passed, "passed"), (failed, "failed"), (running, "running")].filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)" }.joined(separator: " · ")
    }
}

extension GitHubLookup {
    /// The checks of several GitHub pull requests in one GraphQL query, by resource key: one point
    /// of GitHub's hourly budget however many pull requests there are. Nil when GitHub can't answer.
    public func checks(of pulls: [SessionResource]) async -> [String: PullRequestChecks]? {
        let numbered = pulls.compactMap { pull in pull.github.map { (key: pull.key, github: $0) } }
            .filter { Self.isPlainName($0.github.owner) && Self.isPlainName($0.github.repository) }
        guard let executable, !numbered.isEmpty,
              let output = try? await runner.run(executable: executable,
                                                 arguments: ["api", "graphql", "-f", "query=\(Self.checksQuery(numbered.map(\.github)))"],
                                                 timeout: 30) else { return nil }
        // A pull request GitHub can't find fails the command but not the others' answers.
        return Self.parseChecks(output.stdout, keys: numbered.map(\.key))
    }

    static func checksQuery(_ pulls: [(owner: String, repository: String, number: Int)]) -> String {
        let contexts = "contexts(first: 100) { nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } }"
        let fields = pulls.enumerated().map { index, pull in
            "p\(index): repository(owner: \"\(pull.owner)\", name: \"\(pull.repository)\") { pullRequest(number: \(pull.number)) "
                + "{ state headRefOid commits(last: 1) { nodes { commit { statusCheckRollup { \(contexts) } } } } } }"
        }
        return "query { \(fields.joined(separator: " ")) }"
    }

    /// Pull requests GitHub couldn't find are left out.
    static func parseChecks(_ data: Data, keys: [String]) -> [String: PullRequestChecks]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["data"] as? [String: Any] else { return nil }
        var result: [String: PullRequestChecks] = [:]
        for (index, key) in keys.enumerated() {
            guard let repository = answers["p\(index)"] as? [String: Any],
                  let pull = repository["pullRequest"] as? [String: Any] else { continue }
            let commit = ((pull["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.last?["commit"] as? [String: Any]
            let nodes = (((commit?["statusCheckRollup"] as? [String: Any])?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            var passed = 0, failed = 0, running = 0
            for node in nodes {
                if node["__typename"] as? String == "CheckRun" {
                    guard node["status"] as? String == "COMPLETED" else { running += 1; continue }
                    switch node["conclusion"] as? String {
                    case "SUCCESS", "NEUTRAL", "SKIPPED": passed += 1
                    default: failed += 1
                    }
                } else {
                    switch node["state"] as? String {
                    case "SUCCESS": passed += 1
                    case "PENDING", "EXPECTED": running += 1
                    default: failed += 1
                    }
                }
            }
            result[key] = PullRequestChecks(passed: passed, failed: failed, running: running,
                                            isOpen: pull["state"] as? String == "OPEN", isMerged: pull["state"] as? String == "MERGED",
                                            head: pull["headRefOid"] as? String ?? "")
        }
        return result
    }

    static func isPlainName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }
}
