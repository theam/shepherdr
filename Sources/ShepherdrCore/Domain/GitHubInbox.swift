import Foundation

/// A GitHub repository someone follows, such as `theam/shepherdr`. Owner and name are kept in
/// lowercase: GitHub treats them case-insensitively, as `SessionResource.key` does.
public struct InboxRepository: Codable, Hashable, Sendable, Identifiable {
    public let owner: String
    public let name: String

    public var id: String { "\(owner)/\(name)" }
    public var displayName: String { "\(owner)/\(name)" }

    /// Nil for names GitHub wouldn't accept, so they never reach a query.
    public init?(owner: String, name: String) {
        guard Self.isValid(owner), Self.isValid(name) else { return nil }
        self.owner = owner.lowercased()
        self.name = name.lowercased()
    }

    /// Reads what people paste: `owner/repo`, `github.com/owner/repo`, a page under
    /// `https://github.com/owner/repo/...`, or a remote such as `git@github.com:owner/repo.git`.
    public init?(parsing text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let path: String
        var allowsMore = true
        if text.lowercased().hasPrefix("git@github.com:") {
            path = String(text.dropFirst("git@github.com:".count))
            allowsMore = false
        } else if text.contains("://") {
            guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
                  ["http", "https", "ssh", "git"].contains(scheme),
                  let host = url.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
            path = url.path()
        } else if text.lowercased().hasPrefix("github.com/") || text.lowercased().hasPrefix("www.github.com/") {
            path = String(text.drop(while: { $0 != "/" }))
        } else {
            path = text
            allowsMore = false
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, allowsMore || parts.count == 2 else { return nil }
        var name = parts[1]
        if name.lowercased().hasSuffix(".git") { name.removeLast(4) }
        self.init(owner: parts[0], name: name)
    }

    private static func isValid(_ part: String) -> Bool {
        GitHubLookup.isPlainName(part) && !part.allSatisfy { $0 == "." }
    }
}

/// A pull request already linked to an issue, found or confirmed by GitHub.
public struct LinkedPullRequest: Hashable, Sendable {
    public let number: Int
    public let isOpen: Bool
    public let isDraft: Bool
    public let url: URL

    public init(number: Int, isOpen: Bool, isDraft: Bool, url: URL) {
        self.number = number
        self.isOpen = isOpen
        self.isDraft = isDraft
        self.url = url
    }
}

/// What landing a pull request involves: how big it is, where it merges and whether it can.
public struct PullRequestDetails: Hashable, Sendable {
    public let additions: Int
    public let deletions: Int
    public let changedFiles: Int
    public let createdAt: Date
    /// The branch it merges into.
    public let baseBranch: String
    /// Its own branch, which other pull requests in its repository can be stacked on unless it
    /// comes from a fork.
    public let headBranch: String
    public let isFromFork: Bool
    /// GitHub answers `UNKNOWN` while it works out whether a pull request merges cleanly; that
    /// counts as no conflicts.
    public let hasConflicts: Bool

    public init(additions: Int, deletions: Int, changedFiles: Int, createdAt: Date, baseBranch: String,
                headBranch: String, isFromFork: Bool = false, hasConflicts: Bool = false) {
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.createdAt = createdAt
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.isFromFork = isFromFork
        self.hasConflicts = hasConflicts
    }
}

/// An issue or pull request on GitHub that asks something of you.
public struct GitHubInboxItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// An open issue assigned to you.
        case assignedIssue
        /// An open pull request asking for your review.
        case reviewRequested
        /// An open pull request of your own.
        case myPullRequest
    }

    public let kind: Kind
    public let repository: InboxRepository
    public let number: Int
    public let title: String
    public let url: URL
    public let author: String
    public let updatedAt: Date
    /// Only pull requests are drafts.
    public let isDraft: Bool
    /// A pull request's review state: `APPROVED`, `CHANGES_REQUESTED` or `REVIEW_REQUIRED`.
    public let reviewDecision: String?
    /// Pull requests GitHub links to this issue: connected by hand, or set to close it when merged.
    /// Always empty for pull requests.
    public let linkedPullRequests: [LinkedPullRequest]
    /// Only pull requests have them, when GitHub gave them.
    public let details: PullRequestDetails?

    public init(kind: Kind, repository: InboxRepository, number: Int, title: String, url: URL, author: String,
                updatedAt: Date, isDraft: Bool = false, reviewDecision: String? = nil,
                linkedPullRequests: [LinkedPullRequest] = [], details: PullRequestDetails? = nil) {
        self.kind = kind
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
        self.author = author
        self.updatedAt = updatedAt
        self.isDraft = isDraft
        self.reviewDecision = reviewDecision
        self.linkedPullRequests = linkedPullRequests
        self.details = details
    }

    public var id: String { key }

    /// The same key as the `SessionResource` for this number, so the two can be matched.
    public var key: String { "github.com/\(repository.owner)/\(repository.name)#\(number)".lowercased() }

    public var isPullRequest: Bool { kind != .assignedIssue }

    /// This item as a session resource, already confirmed by GitHub.
    public var resource: SessionResource {
        if let resource = SessionResource(url: url) {
            return resource.verified(isPullRequest: isPullRequest).found(title: title)
        }
        return SessionResource(url: url, kind: isPullRequest ? .pullRequest : .issue,
                               name: "\(repository.displayName)#\(number)").found(title: title)
    }
}

/// Why GitHub couldn't be asked.
public enum GitHubSyncError: Error, Sendable, Equatable {
    /// GitHub's CLI isn't installed.
    case notInstalled
    /// The CLI isn't signed in: `gh auth login`.
    case signedOut
    /// GitHub's hourly budget is spent; it refills at `resetAt`, when known.
    case rateLimited(resetAt: Date?)
    case failed(String)
}

/// What GitHub asks of you across the followed repositories.
public struct GitHubInbox: Equatable, Sendable {
    /// Your GitHub login.
    public let viewer: String
    /// Newest first.
    public let items: [GitHubInboxItem]
    public let syncedAt: Date

    public init(viewer: String, items: [GitHubInboxItem], syncedAt: Date) {
        self.viewer = viewer
        self.items = items
        self.syncedAt = syncedAt
    }
}

extension GitHubLookup {
    /// GitHub rejects search texts longer than this.
    static let searchLimit = 256

    /// Issues assigned to you, pull requests awaiting your review and, optionally, your own open
    /// pull requests in the given repositories, in one GraphQL query.
    public func inbox(repositories: [InboxRepository], includeMyPullRequests: Bool = true) async -> Result<GitHubInbox, GitHubSyncError> {
        guard let executable else { return .failure(.notInstalled) }
        let followed = repositories.filter { Self.isPlainName($0.owner) && Self.isPlainName($0.name) }
        guard !followed.isEmpty else { return .success(GitHubInbox(viewer: "", items: [], syncedAt: Date())) }
        let searches = Self.inboxSearches(followed, includeMyPullRequests: includeMyPullRequests)
        var arguments = ["api", "graphql", "-f", "query=\(Self.inboxQuery(searches))"]
        for (index, search) in searches.enumerated() { arguments += ["-f", "q\(index)=\(search.text)"] }
        guard let output = try? await runner.run(executable: executable, arguments: arguments, timeout: 30) else {
            return .failure(.failed("couldn't run gh"))
        }
        if output.exitCode == 0, let inbox = Self.parseInbox(output.stdout) { return .success(inbox) }
        if let error = Self.syncError(output) { return .failure(error) }
        // A search GitHub couldn't answer fails the command but not the others' answers.
        if let inbox = Self.parseInbox(output.stdout) { return .success(inbox) }
        return .failure(.failed(Self.message(output, fallback: "unexpected answer from GitHub")))
    }

    /// Confirms a repository exists and you can see it, under the name GitHub gives it now, which
    /// follows renames and transfers.
    public func validate(repository text: String) async -> Result<InboxRepository, GitHubSyncError> {
        guard let typed = InboxRepository(parsing: text) else { return .failure(.failed("not an owner/repo or a github.com link")) }
        guard let executable else { return .failure(.notInstalled) }
        guard let output = try? await runner.run(executable: executable,
                                                 arguments: ["api", "repos/\(typed.owner)/\(typed.name)", "--jq", ".full_name"],
                                                 timeout: 15) else { return .failure(.failed("couldn't run gh")) }
        guard output.exitCode == 0 else {
            if let error = Self.syncError(output) { return .failure(error) }
            let text = String(decoding: output.stderr + output.stdout, as: UTF8.self)
            if text.contains("HTTP 404") || text.contains("Not Found") { return .failure(.failed("repository not found, or you can't see it")) }
            return .failure(.failed(Self.message(output, fallback: "GitHub didn't answer")))
        }
        let name = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(InboxRepository(parsing: name) ?? typed)
    }

    /// One search per kind and group of repositories: GitHub caps a search text's length, so many
    /// followed repositories are split over several searches of the same query.
    static func inboxSearches(_ repositories: [InboxRepository], includeMyPullRequests: Bool) -> [(alias: String, text: String)] {
        var kinds = [("issues", "is:open is:issue archived:false assignee:@me"),
                     ("reviews", "is:open is:pr archived:false review-requested:@me")]
        if includeMyPullRequests { kinds.append(("mine", "is:open is:pr archived:false author:@me")) }
        let room = searchLimit - (kinds.map(\.1.count).max() ?? 0) - 1
        var groups: [[String]] = [[]]
        for filter in repositories.map({ "repo:\($0.owner)/\($0.name)" }) {
            if !groups[groups.count - 1].isEmpty, (groups[groups.count - 1] + [filter]).joined(separator: " ").count > room {
                groups.append([])
            }
            groups[groups.count - 1].append(filter)
        }
        return kinds.flatMap { alias, base in
            groups.enumerated().map { index, group in
                (alias: groups.count == 1 ? alias : "\(alias)\(index)", text: "\(base) \(group.joined(separator: " "))")
            }
        }
    }

    /// Search texts travel as variables, never inside the query itself.
    static func inboxQuery(_ searches: [(alias: String, text: String)]) -> String {
        let common = "number title url updatedAt author { login } repository { nameWithOwner }"
        let linked = "... on PullRequest { number state isDraft url }"
        // Pull requests connected by hand, or that mention the issue; only those GitHub says will
        // close it count as linked.
        let timeline = "timelineItems(itemTypes: [CONNECTED_EVENT, CROSS_REFERENCED_EVENT], first: 10) { nodes { __typename "
            + "... on ConnectedEvent { subject { __typename \(linked) } } "
            + "... on CrossReferencedEvent { willCloseTarget source { __typename \(linked) } } } }"
        let pull = "isDraft reviewDecision additions deletions changedFiles createdAt baseRefName headRefName isCrossRepository mergeable"
        let nodes = "nodes { ... on Issue { \(common) \(timeline) } ... on PullRequest { \(common) \(pull) } }"
        let variables = searches.indices.map { "$q\($0): String!" }.joined(separator: ", ")
        let fields = searches.enumerated().map { index, search in
            "\(search.alias): search(type: ISSUE, query: $q\(index), first: 50) { \(nodes) }"
        }
        return "query(\(variables)) { viewer { login } rateLimit { remaining resetAt } \(fields.joined(separator: " ")) }"
    }

    /// Nil unless GitHub answered with data. Searches it couldn't answer, and nodes it left out,
    /// are skipped.
    static func parseInbox(_ data: Data, syncedAt: Date = Date()) -> GitHubInbox? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["data"] as? [String: Any] else { return nil }
        let viewer = (answers["viewer"] as? [String: Any])?["login"] as? String ?? ""
        let dates = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? { (value as? String).flatMap { dates.date(from: $0) ?? fractional.date(from: $0) } }
        let priority: [GitHubInboxItem.Kind] = [.assignedIssue, .myPullRequest, .reviewRequested]
        var items: [String: GitHubInboxItem] = [:]
        for (alias, answer) in answers {
            guard let kind = inboxKind(alias),
                  let nodes = (answer as? [String: Any])?["nodes"] as? [[String: Any]] else { continue }
            for node in nodes {
                guard let number = node["number"] as? Int, let title = node["title"] as? String,
                      let url = (node["url"] as? String).flatMap(URL.init(string:)),
                      let updatedAt = date(node["updatedAt"]),
                      let repository = ((node["repository"] as? [String: Any])?["nameWithOwner"] as? String)
                        .flatMap(InboxRepository.init(parsing:)) else { continue }
                let isIssue = kind == .assignedIssue
                let item = GitHubInboxItem(kind: kind, repository: repository, number: number, title: title, url: url,
                                           author: (node["author"] as? [String: Any])?["login"] as? String ?? "ghost",
                                           updatedAt: updatedAt, isDraft: node["isDraft"] as? Bool ?? false,
                                           reviewDecision: node["reviewDecision"] as? String,
                                           linkedPullRequests: isIssue ? linkedPullRequests(node["timelineItems"]) : [],
                                           details: isIssue ? nil : pullRequestDetails(node, createdAt: date(node["createdAt"])))
                if let known = items[item.key],
                   (priority.firstIndex(of: known.kind) ?? 0) >= (priority.firstIndex(of: kind) ?? 0) { continue }
                items[item.key] = item
            }
        }
        let sorted = items.values.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.key < $1.key }
        return GitHubInbox(viewer: viewer, items: sorted, syncedAt: syncedAt)
    }

    /// The pull requests an issue's timeline links to it, once each: connected ones, and those that
    /// mention it and will close it when merged. A missing timeline links none. The same pull request
    /// can show in both kinds of event; its URL tells them apart from a same-numbered one elsewhere.
    private static func linkedPullRequests(_ timeline: Any?) -> [LinkedPullRequest] {
        guard let events = (timeline as? [String: Any])?["nodes"] as? [[String: Any]] else { return [] }
        var linked: [LinkedPullRequest] = []
        for event in events {
            let pull: [String: Any]?
            switch event["__typename"] as? String {
            case "ConnectedEvent": pull = event["subject"] as? [String: Any]
            case "CrossReferencedEvent": pull = event["willCloseTarget"] as? Bool == true ? event["source"] as? [String: Any] : nil
            default: pull = nil
            }
            guard let pull, pull["__typename"] as? String == "PullRequest", let number = pull["number"] as? Int,
                  let url = (pull["url"] as? String).flatMap(URL.init(string:)),
                  !linked.contains(where: { $0.url == url }) else { continue }
            linked.append(LinkedPullRequest(number: number, isOpen: pull["state"] as? String == "OPEN",
                                            isDraft: pull["isDraft"] as? Bool ?? false, url: url))
        }
        return linked
    }

    /// Nil when GitHub left out the pull request's size, branches or opening date.
    private static func pullRequestDetails(_ node: [String: Any], createdAt: Date?) -> PullRequestDetails? {
        guard let createdAt, let additions = node["additions"] as? Int, let deletions = node["deletions"] as? Int,
              let changedFiles = node["changedFiles"] as? Int, let base = node["baseRefName"] as? String,
              let head = node["headRefName"] as? String else { return nil }
        return PullRequestDetails(additions: additions, deletions: deletions, changedFiles: changedFiles, createdAt: createdAt,
                                  baseBranch: base, headBranch: head, isFromFork: node["isCrossRepository"] as? Bool ?? false,
                                  hasConflicts: node["mergeable"] as? String == "CONFLICTING")
    }

    /// `issues`, `reviews3`, `mine`: which search an answer belongs to.
    private static func inboxKind(_ alias: String) -> GitHubInboxItem.Kind? {
        let prefix = alias.prefix(while: { !$0.isNumber })
        guard alias.dropFirst(prefix.count).allSatisfy(\.isNumber) else { return nil }
        switch prefix {
        case "issues": return .assignedIssue
        case "reviews": return .reviewRequested
        case "mine": return .myPullRequest
        default: return nil
        }
    }

    /// Signed out or out of budget, from what the CLI printed; nil for anything else.
    static func syncError(_ output: CommandOutput) -> GitHubSyncError? {
        let text = String(decoding: output.stderr + output.stdout, as: UTF8.self)
        if text.contains("auth login") || text.contains("HTTP 401") { return .signedOut }
        // A bare 403 is also how GitHub refuses SSO-protected or forbidden repositories, so it only
        // counts as the budget running out when GitHub says so.
        let lowered = text.lowercased()
        if lowered.contains("rate limit") || lowered.contains("rate_limited") {
            return .rateLimited(resetAt: resetTime(output.stdout))
        }
        return nil
    }

    private static func resetTime(_ data: Data) -> Date? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = ((root["data"] as? [String: Any])?["rateLimit"] as? [String: Any])?["resetAt"] as? String else { return nil }
        return ISO8601DateFormatter().date(from: stamp)
    }

    private static func message(_ output: CommandOutput, fallback: String) -> String {
        let stderr = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = stderr.isEmpty ? String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : stderr
        return text.isEmpty ? fallback : String(text.prefix(200))
    }
}
