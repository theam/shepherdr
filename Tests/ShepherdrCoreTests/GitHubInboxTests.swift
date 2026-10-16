import Foundation
import Testing
@testable import ShepherdrCore

struct GitHubInboxTests {
    private let gh = URL(fileURLWithPath: "/usr/bin/true")
    private func repo(_ text: String) -> InboxRepository { InboxRepository(parsing: text)! }

    private let answer = """
    {"data":{
      "viewer":{"login":"chema"},
      "rateLimit":{"remaining":4990,"resetAt":"2026-10-09T13:00:00Z"},
      "issues":{"nodes":[
        {"number":12,"title":"Login loops","url":"https://github.com/Theam/Shepherdr/issues/12","updatedAt":"2026-10-08T10:00:00Z",
         "author":{"login":"ana"},"repository":{"nameWithOwner":"Theam/Shepherdr"}},
        {}]},
      "reviews":{"nodes":[
        {"number":30,"title":"Faster sync","url":"https://github.com/theam/tam-os/pull/30","updatedAt":"2026-10-09T09:30:00Z",
         "author":{"login":"luis"},"repository":{"nameWithOwner":"theam/tam-os"},"isDraft":true,"reviewDecision":"REVIEW_REQUIRED"}]},
      "mine":{"nodes":[
        {"number":31,"title":"Inbox","url":"https://github.com/theam/tam-os/pull/31","updatedAt":"2026-10-07T08:00:00.123Z",
         "author":null,"repository":{"nameWithOwner":"theam/tam-os"},"isDraft":false,"reviewDecision":"APPROVED"},
        {"number":30,"title":"Faster sync","url":"https://github.com/theam/tam-os/pull/30","updatedAt":"2026-10-09T09:30:00Z",
         "author":{"login":"luis"},"repository":{"nameWithOwner":"theam/tam-os"},"isDraft":true,"reviewDecision":"REVIEW_REQUIRED"}]}
    }}
    """

    @Test func repositoriesAreReadFromWhatPeoplePaste() {
        for text in ["Theam/Shepherdr", "https://github.com/theam/shepherdr", "https://github.com/theam/shepherdr.git",
                     "https://github.com/theam/shepherdr/pull/3", "github.com/theam/shepherdr/", "git@github.com:theam/shepherdr.git",
                     "git@github.com:theam/shepherdr", "ssh://git@github.com/theam/shepherdr.git", "  theam/shepherdr\n"] {
            #expect(InboxRepository(parsing: text)?.id == "theam/shepherdr", "\(text)")
        }
        #expect(repo("theam/shepherdr").displayName == "theam/shepherdr")
        for text in ["", "   ", "theam shepherdr", "theam/ shepherdr", "theam/..", "../shepherdr", "shepherdr", "theam/shepherdr/extra",
                     "https://gitlab.com/theam/shepherdr", "https://github.com/theam", "theam/\"}", "-x/y\" z"] {
            #expect(InboxRepository(parsing: text) == nil, "\(text)")
        }
    }

    @Test func itemsShareTheirKeyWithSessionResources() throws {
        let inbox = try #require(GitHubLookup.parseInbox(Data(answer.utf8)))
        for item in inbox.items {
            let resource = try #require(SessionResource(url: item.url))
            #expect(item.key == resource.key && item.id == resource.key)
            #expect(item.resource.key == item.key && item.resource.isVerified && item.resource.title == item.title)
            #expect(item.resource.kind == (item.kind == .assignedIssue ? .issue : .pullRequest))
        }
        #expect(inbox.items.first { $0.number == 12 }?.key == "github.com/theam/shepherdr#12")
    }

    @Test func answersAreSortedByKindNewestFirst() throws {
        let inbox = try #require(GitHubLookup.parseInbox(Data(answer.utf8)))
        #expect(inbox.viewer == "chema")
        #expect(inbox.items.map(\.number) == [30, 12, 31])
        let review = inbox.items[0], issue = inbox.items[1], mine = inbox.items[2]
        // Asked to review your own listed pull request: the review wins.
        #expect(review.kind == .reviewRequested && review.isDraft && review.reviewDecision == "REVIEW_REQUIRED" && review.author == "luis")
        #expect(issue.kind == .assignedIssue && !issue.isDraft && issue.reviewDecision == nil && issue.repository == repo("theam/shepherdr"))
        #expect(issue.updatedAt == ISO8601DateFormatter().date(from: "2026-10-08T10:00:00Z"))
        #expect(mine.kind == .myPullRequest && mine.reviewDecision == "APPROVED" && mine.author == "ghost")
        #expect(abs(mine.updatedAt.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-10-07T08:00:00Z")!) - 0.123) < 0.001)

        let withoutMine = #"{"data":{"viewer":{"login":"chema"},"issues":{"nodes":[]},"reviews":{"nodes":[]}}}"#
        #expect(GitHubLookup.parseInbox(Data(withoutMine.utf8))?.items.isEmpty == true)
        #expect(GitHubLookup.parseInbox(Data("nope".utf8)) == nil)
    }

    @Test func issuesKnowThePullRequestsLinkedToThem() throws {
        func pull(_ number: Int, _ state: String, draft: Bool = false, repo: String = "a/b") -> String {
            #"{"__typename":"PullRequest","number":\#(number),"state":"\#(state)","isDraft":\#(draft),"url":"https://github.com/\#(repo)/pull/\#(number)"}"#
        }
        let linked = """
        {"data":{"viewer":{"login":"chema"},
          "issues":{"nodes":[
            {"number":1,"title":"Linked","url":"https://github.com/a/b/issues/1","updatedAt":"2026-10-03T00:00:00Z",
             "author":{"login":"x"},"repository":{"nameWithOwner":"a/b"},
             "timelineItems":{"nodes":[
               {"__typename":"ConnectedEvent","subject":\(pull(5, "OPEN", draft: true))},
               {"__typename":"CrossReferencedEvent","willCloseTarget":true,"source":\(pull(6, "MERGED"))},
               {"__typename":"CrossReferencedEvent","willCloseTarget":false,"source":\(pull(7, "OPEN"))},
               {"__typename":"CrossReferencedEvent","willCloseTarget":true,"source":\(pull(5, "OPEN", draft: true))},
               {"__typename":"CrossReferencedEvent","willCloseTarget":true,"source":\(pull(5, "OPEN", repo: "c/d"))},
               {"__typename":"CrossReferencedEvent","willCloseTarget":true,"source":{"__typename":"Issue","number":8,"url":"https://github.com/a/b/issues/8"}},
               {"__typename":"ConnectedEvent","subject":{"__typename":"Issue","number":9,"url":"https://github.com/a/b/issues/9"}},
               {"__typename":"ConnectedEvent","subject":null},
               {}]}},
            {"number":2,"title":"Mentioned only","url":"https://github.com/a/b/issues/2","updatedAt":"2026-10-02T00:00:00Z",
             "author":{"login":"x"},"repository":{"nameWithOwner":"a/b"},
             "timelineItems":{"nodes":[{"__typename":"CrossReferencedEvent","willCloseTarget":false,"source":\(pull(7, "OPEN"))}]}},
            {"number":3,"title":"No timeline","url":"https://github.com/a/b/issues/3","updatedAt":"2026-10-01T00:00:00Z",
             "author":{"login":"x"},"repository":{"nameWithOwner":"a/b"}}]},
          "mine":{"nodes":[
            {"number":5,"title":"Fix","url":"https://github.com/a/b/pull/5","updatedAt":"2026-10-04T00:00:00Z",
             "author":{"login":"chema"},"repository":{"nameWithOwner":"a/b"},"isDraft":true,"reviewDecision":null,
             "timelineItems":{"nodes":[{"__typename":"ConnectedEvent","subject":\(pull(6, "OPEN"))}]}}]}
        }}
        """
        let inbox = try #require(GitHubLookup.parseInbox(Data(linked.utf8)))
        let byNumber = Dictionary(uniqueKeysWithValues: inbox.items.map { ($0.number, $0) })
        let first = try #require(byNumber[1]?.linkedPullRequests)
        // Connected by hand, set to close it, or both; the same number in another repository is
        // another pull request. A mention that won't close it, and issues, don't count.
        #expect(first.map(\.number) == [5, 6, 5])
        #expect(first[0] == LinkedPullRequest(number: 5, isOpen: true, isDraft: true, url: URL(string: "https://github.com/a/b/pull/5")!))
        #expect(!first[1].isOpen && !first[1].isDraft && first[2].url.absoluteString == "https://github.com/c/d/pull/5")
        #expect(byNumber[2]?.linkedPullRequests.isEmpty == true)
        #expect(byNumber[3]?.linkedPullRequests.isEmpty == true)
        #expect(byNumber[5]?.linkedPullRequests.isEmpty == true)
    }

    @Test func pullRequestsKnowWhatLandingThemTakes() throws {
        let sized = """
        {"data":{"viewer":{"login":"chema"},
          "reviews":{"nodes":[
            {"number":4,"title":"Stacked","url":"https://github.com/a/b/pull/4","updatedAt":"2026-10-03T00:00:00Z",
             "author":{"login":"ana"},"repository":{"nameWithOwner":"a/b"},"isDraft":false,"reviewDecision":null,
             "additions":120,"deletions":30,"changedFiles":7,"createdAt":"2026-10-01T09:00:00.5Z",
             "baseRefName":"feature-a","headRefName":"feature-b","isCrossRepository":true,"mergeable":"CONFLICTING"},
            {"number":5,"title":"Unknown","url":"https://github.com/a/b/pull/5","updatedAt":"2026-10-02T00:00:00Z",
             "author":{"login":"ana"},"repository":{"nameWithOwner":"a/b"},
             "additions":1,"deletions":0,"changedFiles":1,"createdAt":"2026-10-01T00:00:00Z",
             "baseRefName":"main","headRefName":"fix","mergeable":"UNKNOWN"},
            {"number":6,"title":"Sizeless","url":"https://github.com/a/b/pull/6","updatedAt":"2026-10-01T00:00:00Z",
             "author":{"login":"ana"},"repository":{"nameWithOwner":"a/b"},"baseRefName":"main","headRefName":"x"}]},
          "issues":{"nodes":[
            {"number":7,"title":"Issue","url":"https://github.com/a/b/issues/7","updatedAt":"2026-10-01T00:00:00Z",
             "author":{"login":"ana"},"repository":{"nameWithOwner":"a/b"},"additions":1,"deletions":0,"changedFiles":1,
             "createdAt":"2026-10-01T00:00:00Z","baseRefName":"main","headRefName":"x"}]}
        }}
        """
        let inbox = try #require(GitHubLookup.parseInbox(Data(sized.utf8)))
        let byNumber = Dictionary(uniqueKeysWithValues: inbox.items.map { ($0.number, $0) })
        let stacked = try #require(byNumber[4]?.details)
        #expect(stacked.additions == 120 && stacked.deletions == 30 && stacked.changedFiles == 7)
        #expect(stacked.baseBranch == "feature-a" && stacked.headBranch == "feature-b" && stacked.isFromFork && stacked.hasConflicts)
        #expect(abs(stacked.createdAt.timeIntervalSince(ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!) - 0.5) < 0.001)
        // GitHub still working out whether it merges cleanly is no conflict.
        #expect(byNumber[5]?.details?.hasConflicts == false && byNumber[5]?.details?.isFromFork == false)
        #expect(byNumber[6]?.details == nil && byNumber[7]?.details == nil)
    }

    @Test func oneQueryCarriesTheSearchesAsVariables() async throws {
        let runner = RecordingRunner([output(answer)])
        let lookup = GitHubLookup(runner: runner, executable: gh)
        let result = await lookup.inbox(repositories: [repo("theam/shepherdr"), repo("theam/tam-os")])
        #expect((try? result.get())?.items.count == 3)
        let arguments = try #require(await runner.recordedArguments().first)
        #expect(Array(arguments.prefix(3)) == ["api", "graphql", "-f"])
        let query = arguments[3]
        #expect(query.hasPrefix("query=query($q0: String!, $q1: String!, $q2: String!)"))
        #expect(query.contains("viewer { login }") && query.contains("rateLimit { remaining resetAt }"))
        #expect(query.contains("issues: search(type: ISSUE, query: $q0, first: 50)") && query.contains("mine: search(type: ISSUE, query: $q2"))
        #expect(!query.contains("repo:"))
        #expect(query.contains("... on Issue { number title url updatedAt author { login } repository { nameWithOwner } "
                               + "timelineItems(itemTypes: [CONNECTED_EVENT, CROSS_REFERENCED_EVENT], first: 10)"))
        #expect(query.contains("... on CrossReferencedEvent { willCloseTarget source { __typename ... on PullRequest { number state isDraft url } } }"))
        #expect(query.contains("... on ConnectedEvent { subject { __typename ... on PullRequest { number state isDraft url } } }"))
        #expect(query.contains("... on PullRequest { number title url updatedAt author { login } repository { nameWithOwner } isDraft reviewDecision "
                               + "additions deletions changedFiles createdAt baseRefName headRefName isCrossRepository mergeable }"))
        #expect(Array(arguments.dropFirst(4)) == [
            "-f", "q0=is:open is:issue archived:false assignee:@me repo:theam/shepherdr repo:theam/tam-os",
            "-f", "q1=is:open is:pr archived:false review-requested:@me repo:theam/shepherdr repo:theam/tam-os",
            "-f", "q2=is:open is:pr archived:false author:@me repo:theam/shepherdr repo:theam/tam-os",
        ])

        let fewer = RecordingRunner([output(answer)])
        _ = await GitHubLookup(runner: fewer, executable: gh).inbox(repositories: [repo("a/b")], includeMyPullRequests: false)
        let other = try #require(await fewer.recordedArguments().first)
        #expect(other.count == 8 && !other[3].contains("mine:") && !other[3].contains("$q2"))
    }

    @Test func manyRepositoriesAreSplitOverSearchesGitHubAccepts() {
        let many = (0..<30).map { repo("some-organization/repository-number-\($0)") }
        let searches = GitHubLookup.inboxSearches(many, includeMyPullRequests: true)
        #expect(searches.count > 3 && searches.count % 3 == 0)
        #expect(searches.allSatisfy { $0.text.count <= GitHubLookup.searchLimit })
        let covered = searches.filter { $0.alias.hasPrefix("issues") }.flatMap { $0.text.split(separator: " ").filter { $0.hasPrefix("repo:") } }
        #expect(covered.count == 30)
        #expect(searches.first?.alias == "issues0")
    }

    @Test func nothingIsAskedWithoutTheCLIOrRepositories() async {
        let runner = RecordingRunner([])
        #expect(await GitHubLookup(runner: runner, executable: nil).inbox(repositories: [repo("a/b")]) == .failure(.notInstalled))
        let empty = await GitHubLookup(runner: runner, executable: gh).inbox(repositories: [])
        #expect((try? empty.get())?.items.isEmpty == true)
        #expect(await runner.recordedArguments().isEmpty)
    }

    @Test func partialAnswersStillCount() async {
        let partial = """
        {"data":{"viewer":{"login":"chema"},"issues":{"nodes":[
          {"number":1,"title":"One","url":"https://github.com/a/b/issues/1","updatedAt":"2026-10-01T00:00:00Z","author":{"login":"x"},
           "repository":{"nameWithOwner":"a/b"}}]},"reviews":null},
         "errors":[{"message":"Something went wrong"}]}
        """
        let runner = RecordingRunner([output(partial, stderr: "gh: Something went wrong", code: 1)])
        let result = await GitHubLookup(runner: runner, executable: gh).inbox(repositories: [repo("a/b")])
        #expect((try? result.get())?.items.map(\.number) == [1])
    }

    @Test func failuresSayWhatWentWrong() async {
        func inbox(_ answer: CommandOutput) async -> Result<GitHubInbox, GitHubSyncError> {
            await GitHubLookup(runner: RecordingRunner([answer]), executable: gh).inbox(repositories: [repo("a/b")])
        }
        let signedOut = output("", stderr: "To get started with GitHub CLI, please run:  gh auth login", code: 4)
        #expect(await inbox(signedOut) == .failure(.signedOut))
        #expect(await inbox(output("", stderr: "gh: Bad credentials (HTTP 401)", code: 1)) == .failure(.signedOut))
        let limited = #"{"data":{"rateLimit":{"remaining":0,"resetAt":"2026-10-09T13:00:00Z"}},"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#
        #expect(await inbox(output(limited, stderr: "gh: API rate limit exceeded for user", code: 1))
            == .failure(.rateLimited(resetAt: ISO8601DateFormatter().date(from: "2026-10-09T13:00:00Z"))))
        #expect(await inbox(output("", stderr: "HTTP 403: API rate limit exceeded", code: 1)) == .failure(.rateLimited(resetAt: nil)))
        #expect(await inbox(output("", stderr: "gh: connection refused", code: 1)) == .failure(.failed("gh: connection refused")))
        #expect(await inbox(output("", code: 1)) == .failure(.failed("unexpected answer from GitHub")))
    }

    @Test func repositoriesAreValidatedUnderTheirCurrentName() async throws {
        let runner = RecordingRunner([output("Theam/Shepherdr\n"), output("", stderr: "gh: Not Found (HTTP 404)", code: 1),
                                      output("", stderr: "run gh auth login", code: 4)])
        let lookup = GitHubLookup(runner: runner, executable: gh)
        #expect(await lookup.validate(repository: "https://github.com/THEAM/shepherdr") == .success(repo("theam/shepherdr")))
        #expect(await runner.recordedArguments().first == ["api", "repos/theam/shepherdr", "--jq", ".full_name"])
        #expect(await lookup.validate(repository: "a/b") == .failure(.failed("repository not found, or you can't see it")))
        #expect(await lookup.validate(repository: "a/b") == .failure(.signedOut))
        #expect(await lookup.validate(repository: "not a repo") == .failure(.failed("not an owner/repo or a github.com link")))
        #expect(await GitHubLookup(runner: runner, executable: nil).validate(repository: "a/b") == .failure(.notInstalled))
        #expect(await runner.recordedArguments().count == 3)
    }
}

@Suite @MainActor struct GitHubInboxStoreTests {
    private func repo(_ text: String) -> InboxRepository { InboxRepository(parsing: text)! }
    private func item(_ number: Int, updated: TimeInterval) -> GitHubInboxItem {
        GitHubInboxItem(kind: .assignedIssue, repository: repo("a/b"), number: number, title: "Issue \(number)",
                        url: URL(string: "https://github.com/a/b/issues/\(number)")!, author: "x",
                        updatedAt: Date(timeIntervalSince1970: updated))
    }

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suite = "ShepherdrTests.GitHubInbox.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    @Test func repositoriesAreFollowedPausedAndRemembered() async throws {
        try await withDefaults { defaults in
            let store = GitHubInboxStore(defaults: defaults)
            store.add(repo("a/b"))
            store.add(repo("c/d"))
            store.add(repo("A/B"))
            #expect(store.repositories.map(\.id) == ["a/b", "c/d"])
            store.setPaused(repo("a/b"), true)
            #expect(store.activeRepositories == [repo("c/d")])
            let reopened = GitHubInboxStore(defaults: defaults)
            #expect(reopened.repositories == store.repositories && reopened.repositories[0].isPaused)
            reopened.add(repo("a/b"))  // Adding a paused one resumes it.
            #expect(reopened.activeRepositories == [repo("a/b"), repo("c/d")])
            reopened.remove(repo("c/d"))
            #expect(GitHubInboxStore(defaults: defaults).repositories == [WatchedRepository(repository: repo("a/b"))])
        }
    }

    @Test func itemsChangedSinceSeenAreUnseenAgain() async throws {
        try await withDefaults { defaults in
            let store = GitHubInboxStore(defaults: defaults)
            store.add(repo("a/b"))
            let first = item(1, updated: 100), second = item(2, updated: 100)
            #expect(store.unseen([first, second]) == [first, second])
            store.markSeen(first)
            #expect(!store.isUnseen(first) && store.unseen([first, second]) == [second])
            #expect(!GitHubInboxStore(defaults: defaults).isUnseen(first))
            #expect(store.isUnseen(item(1, updated: 200)))
            #expect(!store.isUnseen(item(1, updated: 50)))
            store.markUnseen(first)
            #expect(store.isUnseen(first) && GitHubInboxStore(defaults: defaults).isUnseen(first))
            store.markSeen(second)
            store.remove(repo("a/b"))
            #expect(store.seen.isEmpty)
        }
    }
}
