import Foundation

/// A link worth keeping at hand while a session works: a pull request, an issue, a Claude artifact,
/// or any page an agent pinned with `shepherdr pin`.
public struct SessionResource: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case pullRequest, issue, artifact, link

        public var title: String {
            switch self {
            case .pullRequest: "Pull requests"
            case .issue: "Issues"
            case .artifact: "Claude artifacts"
            case .link: "Links"
            }
        }
    }

    /// The canonical link: a pull request's own page rather than its files tab, without anchors.
    public fileprivate(set) var url: URL
    public fileprivate(set) var kind: Kind
    /// A short name such as `theam/shepherdr#12`, `ENG-42` or `artifact 3f450b55`.
    public let name: String
    /// The most times a single read of the session's output mentioned it.
    public var mentions = 1
    /// Times it was opened from Shepherdr.
    public var opens = 0
    /// Whether GitHub confirmed if it is a pull request or an issue.
    public fileprivate(set) var isVerified = false
    /// Its page's own title, once checked: `Fix the login redirect`.
    public fileprivate(set) var title: String?
    /// Checked and settled: the page exists, or it doesn't.
    public fileprivate(set) var isChecked = false
    /// The page doesn't exist, such as a made-up link in an example. Missing resources aren't shown.
    public fileprivate(set) var isMissing = false
    public var id: URL { url }

    public init(url: URL, kind: Kind, name: String) {
        self.url = url
        self.kind = kind
        self.name = name
    }

    private enum CodingKeys: String, CodingKey { case url, kind, name, mentions, opens, isVerified, title, isChecked, isMissing }

    // Resources saved before counting and verification decode with their defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(URL.self, forKey: .url)
        kind = try container.decode(Kind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        mentions = try container.decodeIfPresent(Int.self, forKey: .mentions) ?? 1
        opens = try container.decodeIfPresent(Int.self, forKey: .opens) ?? 0
        isVerified = try container.decodeIfPresent(Bool.self, forKey: .isVerified) ?? false
        title = try container.decodeIfPresent(String.self, forKey: .title)
        isChecked = try container.decodeIfPresent(Bool.self, forKey: .isChecked) ?? false
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
    }

    /// What it points at. GitHub numbers pull requests and issues together, and redirects one kind of
    /// link to the other, so `/pull/12` and `/issues/12` in the same repository are one thing.
    public var key: String {
        guard let github = github else { return url.absoluteString }
        return "github.com/\(github.owner)/\(github.repository)#\(github.number)".lowercased()
    }

    /// The repository and number of a GitHub pull request or issue.
    public var github: (owner: String, repository: String, number: Int)? {
        let path = url.path().split(separator: "/").map(String.init)
        guard url.host()?.lowercased() == "github.com", kind == .pullRequest || kind == .issue, path.count >= 4,
              let number = Int(path[3]) else { return nil }
        return (path[0], path[1], number)
    }

    /// How relevant it is to the session: opening it counts more than seeing it mentioned.
    public var score: Int { mentions + 3 * opens }

    /// The page exists; its title, if it has a useful one.
    public func found(title: String?) -> SessionResource {
        var resource = self
        resource.title = title ?? self.title
        resource.isChecked = true
        resource.isMissing = false
        return resource
    }

    /// To be checked again: its title and whether it exists.
    public func unchecked() -> SessionResource {
        var resource = self
        resource.isChecked = false
        resource.isMissing = false
        return resource
    }

    /// The page doesn't exist.
    public func missing() -> SessionResource {
        var resource = self
        resource.isChecked = true
        resource.isMissing = true
        return resource
    }

    /// The same GitHub number as GitHub says it is: a pull request or an issue.
    public func verified(isPullRequest: Bool) -> SessionResource {
        guard let github, let link = URL(string: "https://github.com/\(github.owner)/\(github.repository)/\(isPullRequest ? "pull" : "issues")/\(github.number)") else { return self }
        var resource = self
        resource.url = link
        resource.kind = isPullRequest ? .pullRequest : .issue
        resource.isVerified = true
        return resource
    }

    /// A page an agent pinned: a pull request, issue or artifact when it is one, else a plain link
    /// named by its title or address. Only http and https.
    public init?(pinned url: URL, title: String?) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host(), !host.isEmpty else { return nil }
        if let known = SessionResource(url: url) {
            self = known
        } else {
            let path = url.path() == "/" ? "" : url.path()
            self.init(url: url, kind: .link, name: String((host + path).prefix(80)))
        }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            self.title = String(title.prefix(200))
        }
    }

    /// Recognizes the links worth keeping: GitHub, GitLab and Bitbucket pull requests and issues,
    /// Linear and Jira issues, and Claude artifacts. Any other link is nil.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased() else { return nil }
        let path = url.path().split(separator: "/").map(String.init)
        func canonical(_ components: ArraySlice<String>) -> URL? {
            URL(string: "\(scheme)://\(host)/\(components.joined(separator: "/"))")
        }
        func isNumber(_ text: String) -> Bool { !text.isEmpty && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber) }
        func isIssueKey(_ text: String) -> Bool { text.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+$"#, options: .regularExpression) != nil }

        if host == "claude.ai" {
            let prefix: [String]? = path.starts(with: ["code", "artifact"]) ? ["code", "artifact"]
                : path.starts(with: ["public", "artifacts"]) ? ["public", "artifacts"]
                : path.starts(with: ["artifact"]) ? ["artifact"] : nil
            guard let prefix, path.count > prefix.count, let link = canonical(path[...prefix.count]) else { return nil }
            self.init(url: link, kind: .artifact, name: "artifact \(path[prefix.count].prefix(8))")
        } else if host == "github.com" || host == "bitbucket.org", path.count >= 4, isNumber(path[3]),
                  let kind: Kind = ["pull", "pull-requests"].contains(path[2]) ? .pullRequest : path[2] == "issues" ? .issue : nil,
                  let link = canonical(path[...3]) {
            self.init(url: link, kind: kind, name: "\(path[0])/\(path[1])#\(path[3])")
        } else if host == "linear.app", path.count >= 3, path[1] == "issue", isIssueKey(path[2]), let link = canonical(path[...2]) {
            self.init(url: link, kind: .issue, name: path[2].uppercased())
        } else if host.hasSuffix(".atlassian.net"), path.count >= 2, path[0] == "browse", isIssueKey(path[1]),
                  let link = canonical(path[...1]) {
            self.init(url: link, kind: .issue, name: path[1].uppercased())
        } else if let dash = path.firstIndex(of: "-"), dash > 0, path.count > dash + 2, isNumber(path[dash + 2]),
                  let kind: Kind = path[dash + 1] == "merge_requests" ? .pullRequest : path[dash + 1] == "issues" ? .issue : nil,
                  let link = canonical(path[...(dash + 2)]) {
            // GitLab, on gitlab.com or a company's own host.
            let project = path[..<dash].joined(separator: "/")
            self.init(url: link, kind: kind, name: "\(project)\(kind == .pullRequest ? "!" : "#")\(path[dash + 2])")
        } else {
            return nil
        }
    }
}

public enum SessionResources {
    /// The resources linked in plain text, in order of appearance, each once, with how many times
    /// the text mentions it.
    public static func find(in text: String) -> [SessionResource] {
        let range = NSRange(text.startIndex..., in: text)
        let urls = TerminalLinks.pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).flatMap { URL(string: TerminalLinks.trimmed(String(text[$0]))) }
        }
        return combined(urls.compactMap(SessionResource.init(url:)))
    }

    /// The resources linked on a terminal screen, including links that wrap across rows.
    public static func find(onScreen rows: [[Character]]) -> [SessionResource] {
        combined(TerminalLinks.urls(in: rows).compactMap(SessionResource.init(url:)))
    }

    /// Adds newly found resources in front of the known ones, newest first; known ones keep their
    /// place, their kind once GitHub confirmed it, and the most mentions any one read found.
    public static func merge(_ found: [SessionResource], into known: [SessionResource], limit: Int = 200) -> [SessionResource] {
        var result = combined(known)
        var places = Dictionary(result.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
        var fresh: [SessionResource] = []
        for item in combined(found) {
            if let place = places[item.key] {
                result[place].mentions = max(result[place].mentions, item.mentions)
            } else {
                places[item.key] = -1
                fresh.append(item)
            }
        }
        return Array((fresh.reversed() + result).prefix(limit))
    }

    /// One entry per thing, in order: mentions add up, opens add up, and a GitHub-confirmed entry
    /// wins over a guess.
    static func combined(_ resources: [SessionResource]) -> [SessionResource] {
        var result: [SessionResource] = []
        var places: [String: Int] = [:]
        for resource in resources {
            guard let place = places[resource.key] else {
                places[resource.key] = result.count
                result.append(resource)
                continue
            }
            let other = result[place].isVerified || !resource.isVerified ? resource : result[place]
            var kept = result[place].isVerified || !resource.isVerified ? result[place] : resource
            kept.mentions = result[place].mentions + resource.mentions
            kept.opens = result[place].opens + resource.opens
            if !kept.isChecked, other.isChecked {
                kept.title = other.title
                kept.isChecked = true
                kept.isMissing = other.isMissing
            }
            result[place] = kept
        }
        return result
    }

    /// A kind's resources that may exist, most relevant first; newer ones first among equals.
    public static func ranked(_ resources: [SessionResource], kind: SessionResource.Kind) -> [SessionResource] {
        resources.enumerated().filter { $0.element.kind == kind && !$0.element.isMissing }
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// Asks GitHub, through its CLI, whether a number is a pull request or an issue: the link alone
/// can't tell, since GitHub redirects one kind to the other. Private repositories work when the
/// CLI is signed in.
public struct GitHubLookup: Sendable {
    let runner: any CommandRunning
    let executable: URL?

    public init() {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "\(NSHomeDirectory())/.local/bin/gh"]
        self.init(runner: ProcessRunner(),
                  executable: candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:)))
    }

    init(runner: any CommandRunning, executable: URL?) {
        self.runner = runner
        self.executable = executable
    }

    public enum Answer: Equatable, Sendable {
        case found(isPullRequest: Bool, title: String)
        /// GitHub has no such number there, or you can't see it.
        case missing
        /// No CLI, not signed in, or GitHub didn't answer.
        case unknown
    }

    public var isAvailable: Bool { executable != nil }

    public func look(owner: String, repository: String, number: Int) async -> Answer {
        guard let executable, !owner.hasPrefix("-"), !repository.hasPrefix("-"),
              owner.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              repository.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let output = try? await runner.run(executable: executable,
                                                 arguments: ["api", "repos/\(owner)/\(repository)/issues/\(number)",
                                                             "--jq", "[(.pull_request != null), .title] | @tsv"],
                                                 timeout: 20) else { return .unknown }
        guard output.exitCode == 0 else {
            let error = String(decoding: output.stderr + output.stdout, as: UTF8.self)
            return error.contains("HTTP 404") || error.contains("HTTP 410") ? .missing : .unknown
        }
        let fields = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
            .split(separator: "\t", maxSplits: 1).map(String.init)
        guard fields.count == 2, ["true", "false"].contains(fields[0]) else { return .unknown }
        return .found(isPullRequest: fields[0] == "true", title: fields[1])
    }

    /// The branch a pull request comes from: through the CLI, which sees private repositories, else
    /// through GitHub's public API. Nil when neither answers.
    public func pullRequest(_ repository: GitHubRepository, number: Int) async -> PullRequestHead? {
        let path = "repos/\(repository.fullName)/pulls/\(number)"
        if let executable,
           let output = try? await runner.run(executable: executable,
                                              arguments: ["api", path, "--jq", Self.headFields], timeout: 20),
           output.exitCode == 0,
           let head = Self.head(fromFields: String(decoding: output.stdout, as: UTF8.self), in: repository) {
            return head
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/\(path)")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.head(fromJSON: data, in: repository)
    }

    /// The branch, the repository it lives in, whether it merged, the state and the title, as tab-separated fields.
    static let headFields = #"[.head.ref, (.head.repo.full_name // ""), (.merged_at != null), .state, .title] | @tsv"#

    static func head(fromFields text: String, in repository: GitHubRepository) -> PullRequestHead? {
        let fields = text.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 5 else { return nil }
        return head(branch: fields[0], fullName: fields[1], merged: fields[2] == "true", state: fields[3], title: fields[4],
                    in: repository)
    }

    static func head(fromJSON data: Data, in repository: GitHubRepository) -> PullRequestHead? {
        struct Pull: Decodable {
            struct Head: Decodable {
                struct Repo: Decodable { let full_name: String }
                let ref: String
                let repo: Repo?
            }
            let head: Head
            let state: String
            let title: String
            let merged_at: String?
        }
        guard let pull = try? JSONDecoder().decode(Pull.self, from: data) else { return nil }
        return head(branch: pull.head.ref, fullName: pull.head.repo?.full_name ?? "", merged: pull.merged_at != nil,
                    state: pull.state, title: pull.title, in: repository)
    }

    /// A branch Git could take as an argument: never an option, never a control character.
    private static func head(branch: String, fullName: String, merged: Bool, state: String, title: String,
                             in repository: GitHubRepository) -> PullRequestHead? {
        guard !branch.isEmpty, !branch.hasPrefix("-"), branch.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              branch.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return PullRequestHead(branch: branch, isSameRepository: fullName.lowercased() == repository.fullName.lowercased(),
                               title: title, state: merged ? "merged" : state)
    }
}

/// Page titles without the site's own decoration: `Fix login · Pull Request #12 · theam/shepherdr`
/// is `Fix login`. Nil for titles that only name the site or an error page.
public enum ResourceTitles {
    private static let generic: Set<String> = ["github", "gitlab", "bitbucket", "linear", "jira", "claude", "log in", "sign in",
                                                "page not found", "not found", "404", "just a moment...", "access denied"]

    /// Single-page apps such as Claude answer a missing page normally and only say so in its
    /// title, in your language.
    private static let notFound: Set<String> = [
        "page not found", "not found", "404", "página no encontrada", "no se encontró la página", "page introuvable",
        "seite nicht gefunden", "pagina non trovata", "página não encontrada", "pagina niet gevonden",
        "ページが見つかりません", "页面未找到", "페이지를 찾을 수 없습니다",
    ]

    /// Whether a page that loaded fine says it doesn't exist.
    public static func isNotFoundPage(_ raw: String) -> Bool {
        notFound.contains(stripped(raw).lowercased())
    }

    public static func clean(_ raw: String, for resource: SessionResource) -> String? {
        let title = stripped(raw)
        guard !title.isEmpty, !generic.contains(title.lowercased()), !notFound.contains(title.lowercased()),
              title != resource.name else { return nil }
        return title
    }

    private static func stripped(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Site suffixes come after a separator: GitHub and GitLab use ·, others | – — or -.
        for separator in [" · ", " | ", " — ", " – "] {
            if let range = title.range(of: separator) { title = String(title[..<range.lowerBound]) }
        }
        for suffix in [" - Linear", " - Jira", " - Bitbucket", " - Claude"] where title.hasSuffix(suffix) {
            title.removeLast(suffix.count)
        }
        // Jira and Linear repeat the issue key; GitLab the reference: `[OPS-9] Title`, `ENG-42 Title`, `Title (!31)`.
        return title.replacingOccurrences(of: #"^\[?[A-Z][A-Z0-9]*-[0-9]+\]?\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\([!#][0-9]+\)$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
