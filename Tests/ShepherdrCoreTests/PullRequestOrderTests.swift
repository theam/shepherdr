import Foundation
import Testing
@testable import ShepherdrCore

struct PullRequestOrderTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func pull(_ number: Int, _ kind: GitHubInboxItem.Kind = .myPullRequest, repo: String = "a/b", draft: Bool = false,
                      decision: String? = nil, lines: Int = 50, days: Double = 1, base: String = "main", head: String? = nil,
                      fork: Bool = false, conflicts: Bool = false) -> GitHubInboxItem {
        GitHubInboxItem(kind: kind, repository: InboxRepository(parsing: repo)!, number: number, title: "PR \(number)",
                        url: URL(string: "https://github.com/\(repo)/pull/\(number)")!, author: kind == .myPullRequest ? "chema" : "ana",
                        updatedAt: now, isDraft: draft, reviewDecision: decision,
                        details: PullRequestDetails(additions: lines, deletions: 0, changedFiles: 2, createdAt: now.addingTimeInterval(-days * 86_400),
                                                    baseBranch: base, headBranch: head ?? "branch-\(number)", isFromFork: fork,
                                                    hasConflicts: conflicts))
    }

    private func checks(passed: Int = 0, failed: Int = 0, running: Int = 0) -> PullRequestChecks {
        PullRequestChecks(passed: passed, failed: failed, running: running, isOpen: true, head: "abc")
    }

    private func steps(_ pulls: [GitHubInboxItem], _ checks: [Int: PullRequestChecks] = [:]) -> [PullRequestStep] {
        let byKey = Dictionary(uniqueKeysWithValues: pulls.compactMap { pull in checks[pull.number].map { (pull.key, $0) } })
        return PullRequestOrder.steps(for: pulls, checks: byKey, now: now)
    }

    @Test func eachPullRequestGetsWhatItNeedsInThatOrder() throws {
        let issue = GitHubInboxItem(kind: .assignedIssue, repository: InboxRepository(parsing: "a/b")!, number: 9, title: "Bug",
                                    url: URL(string: "https://github.com/a/b/issues/9")!, author: "ana", updatedAt: now)
        let pulls = [pull(8, decision: "APPROVED"), pull(7, decision: "REVIEW_REQUIRED"), pull(6, draft: true),
                     pull(5, decision: "REVIEW_REQUIRED"), pull(4, conflicts: true), pull(3, decision: "CHANGES_REQUESTED"),
                     pull(2, .reviewRequested), pull(1, decision: "APPROVED"), issue]
        let found = steps(pulls, [1: checks(passed: 3), 2: checks(passed: 2), 3: checks(failed: 1), 4: checks(passed: 2, failed: 1),
                                  5: checks(passed: 4, failed: 1), 7: checks(passed: 2), 8: checks(passed: 1, running: 1)])
        #expect(found.map(\.item.number) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(found.map(\.action) == [.merge, .review, .address, .resolve, .fix, .finish, .wait, .wait])

        let reasons = Dictionary(uniqueKeysWithValues: found.map { ($0.item.number, $0.reasons) })
        #expect(reasons[1] == ["approved", "checks passed", "+50 −0 · 2 files", "open 1d"])
        #expect(reasons[2] == ["by @ana", "checks passed", "+50 −0 · 2 files", "open 1d"])
        #expect(reasons[3] == ["changes requested", "1 of 1 checks failed", "+50 −0 · 2 files", "open 1d"])
        // The reason behind the action leads; the rest keep their order.
        #expect(reasons[4] == ["conflicts with main", "waiting for review", "1 of 3 checks failed", "+50 −0 · 2 files", "open 1d"])
        #expect(reasons[5]?.prefix(2) == ["1 of 5 checks failed", "waiting for review"])
        #expect(reasons[6] == ["draft", "+50 −0 · 2 files", "open 1d"])
        #expect(reasons[7]?.prefix(2) == ["waiting for review", "checks passed"])
        // Approved but still checking: nothing to merge yet.
        #expect(reasons[8]?.prefix(2) == ["checks running", "approved"])
    }

    @Test func reviewsGoReadyFirstThenSmallThenOld() {
        let reviews = [pull(1, .reviewRequested, lines: 5), pull(2, .reviewRequested, lines: 800, days: 10),
                       pull(3, .reviewRequested, lines: 5), pull(4, .reviewRequested, lines: 5, days: 3),
                       pull(5, .reviewRequested, lines: 5), pull(6, .reviewRequested, draft: true, lines: 5),
                       pull(7, .reviewRequested, lines: 60), pull(8, .reviewRequested, lines: 5, conflicts: true)]
        let found = steps(reviews, [1: checks(failed: 1), 2: checks(passed: 1), 3: checks(passed: 1), 4: checks(passed: 1),
                                    5: checks(running: 1), 6: checks(passed: 1), 8: checks(passed: 1)])
        // Failing checks or conflicts mean the author will push again; drafts aren't ready.
        #expect(found.map(\.item.number) == [4, 3, 7, 2, 5, 1, 8, 6])
        #expect(found.allSatisfy { $0.action == .review })
    }

    @Test func stackedPullRequestsGoAfterTheirBase() throws {
        let pulls = [pull(10, decision: "APPROVED", head: "feature-a"), pull(11, decision: "APPROVED", base: "feature-a"),
                     pull(20, .reviewRequested, head: "api"), pull(21, .reviewRequested, base: "api"),
                     pull(30, .reviewRequested, repo: "c/d", base: "feature-a"),
                     pull(40, .reviewRequested, head: "release", fork: true), pull(41, .reviewRequested, base: "release"),
                     pull(50, decision: "REVIEW_REQUIRED", head: "base-x"), pull(51, .reviewRequested, base: "base-x")]
        let passed = checks(passed: 1)
        let found = steps(pulls, [10: passed, 11: passed, 20: checks(failed: 1), 21: passed, 30: passed, 40: passed, 41: passed,
                                  50: passed, 51: passed])
        // 21 waits for the review of its base, 20; 11 isn't merged before 10. A pull request that's only
        // waiting, 50, holds nothing back. Other repositories' and forks' branches aren't bases.
        #expect(found.map(\.item.number) == [10, 40, 41, 51, 30, 20, 21, 11, 50])
        let byNumber = Dictionary(uniqueKeysWithValues: found.map { ($0.item.number, $0) })
        #expect(byNumber[11]?.action == .wait && byNumber[11]?.reasons.first == "stacked on #10")
        #expect(byNumber[21]?.stackedOn?.number == 20 && byNumber[51]?.stackedOn?.number == 50)
        #expect(byNumber[30]?.stackedOn == nil && byNumber[41]?.stackedOn == nil && byNumber[10]?.stackedOn == nil)

        let loop = steps([pull(61, .reviewRequested, base: "x", head: "y"), pull(60, .reviewRequested, base: "y", head: "x")])
        #expect(loop.map(\.item.number) == [60, 61])
    }

    @Test func missingDetailsAndChecksLeaveTheirReasonsOut() {
        let bare = GitHubInboxItem(kind: .myPullRequest, repository: InboxRepository(parsing: "a/b")!, number: 1, title: "Bare",
                                   url: URL(string: "https://github.com/a/b/pull/1")!, author: "chema", updatedAt: now,
                                   reviewDecision: "APPROVED")
        let found = PullRequestOrder.steps(for: [bare], checks: [:], now: now)
        #expect(found.map(\.action) == [.merge] && found.first?.reasons == ["approved"])
        #expect(steps([pull(2, .reviewRequested)], [2: checks()]).first?.reasons.contains("no checks") == true)
        #expect(PullRequestOrder.steps(for: [], checks: [:]).isEmpty)
    }

    @Test func agesAreShort() {
        #expect(PullRequestOrder.age(since: now, now: now) == "1m")
        #expect(PullRequestOrder.age(since: now.addingTimeInterval(-600), now: now) == "10m")
        #expect(PullRequestOrder.age(since: now.addingTimeInterval(-7_200), now: now) == "2h")
        #expect(PullRequestOrder.age(since: now.addingTimeInterval(-3 * 86_400), now: now) == "3d")
    }
}
