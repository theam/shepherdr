import Foundation

/// Where a GitHub issue stands: open, or closed for one of GitHub's three reasons.
public enum IssueState: Equatable, Sendable {
    case open, completed, notPlanned, duplicate

    public var isOpen: Bool { self == .open }
}

extension GitHubLookup {
    /// The states of several GitHub issues in one GraphQL query, by resource key. Nil when GitHub can't answer.
    public func issueStates(of issues: [SessionResource]) async -> [String: IssueState]? {
        let numbered = issues.compactMap { issue in issue.github.map { (key: issue.key, github: $0) } }
            .filter { Self.isPlainName($0.github.owner) && Self.isPlainName($0.github.repository) }
        guard let executable, !numbered.isEmpty,
              let output = try? await runner.run(executable: executable,
                                                 arguments: ["api", "graphql", "-f", "query=\(Self.issueStatesQuery(numbered.map(\.github)))"],
                                                 timeout: 30) else { return nil }
        // An issue GitHub can't find, or a number that is a pull request, fails the command but not the others' answers.
        return Self.parseIssueStates(output.stdout, keys: numbered.map(\.key))
    }

    static func issueStatesQuery(_ issues: [(owner: String, repository: String, number: Int)]) -> String {
        let fields = issues.enumerated().map { index, issue in
            "i\(index): repository(owner: \"\(issue.owner)\", name: \"\(issue.repository)\") { issue(number: \(issue.number)) { state stateReason } }"
        }
        return "query { \(fields.joined(separator: " ")) }"
    }

    /// Issues GitHub couldn't find are left out.
    static func parseIssueStates(_ data: Data, keys: [String]) -> [String: IssueState]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["data"] as? [String: Any] else { return nil }
        var result: [String: IssueState] = [:]
        for (index, key) in keys.enumerated() {
            guard let repository = answers["i\(index)"] as? [String: Any],
                  let issue = repository["issue"] as? [String: Any] else { continue }
            let reason = issue["stateReason"] as? String
            let state: IssueState = if issue["state"] as? String == "OPEN" { .open }
                else if reason == "NOT_PLANNED" { .notPlanned }
                else if reason == "DUPLICATE" { .duplicate }
                else { .completed }
            result[key] = state
        }
        return result
    }
}
