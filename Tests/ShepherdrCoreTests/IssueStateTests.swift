import Foundation
import Testing
@testable import ShepherdrCore

struct IssueStateTests {
    private func issue(_ link: String) -> SessionResource { SessionResource(url: URL(string: link)!)! }

    @Test func oneQueryAsksAboutEveryIssue() async {
        let answer = """
        {"data":{
          "i0":{"issue":{"state":"OPEN","stateReason":null}},
          "i1":{"issue":{"state":"CLOSED","stateReason":"COMPLETED"}},
          "i2":{"issue":{"state":"CLOSED","stateReason":"NOT_PLANNED"}},
          "i3":{"issue":{"state":"CLOSED","stateReason":"DUPLICATE"}},
          "i4":{"issue":null}},
         "errors":[{"type":"NOT_FOUND","message":"Could not resolve to an Issue with the number of 5."}]}
        """
        // gh fails when part of the query does, such as a number that is a pull request, but still prints the rest.
        let runner = RecordingRunner([output(answer, stderr: "gh: Could not resolve to an Issue with the number of 5.", code: 1)])
        let lookup = GitHubLookup(runner: runner, executable: URL(fileURLWithPath: "/usr/bin/true"))
        let issues = ["https://github.com/theam/shepherdr/issues/1", "https://github.com/theam/shepherdr/issues/2",
                      "https://github.com/theam/shepherdr/issues/3", "https://github.com/theam/shepherdr/issues/4",
                      "https://github.com/a/b/issues/5"].map(issue)
        let states = await lookup.issueStates(of: issues)
        #expect(states?[issues[0].key] == .open && states?[issues[0].key]?.isOpen == true)
        #expect(states?[issues[1].key] == .completed)
        #expect(states?[issues[2].key] == .notPlanned)
        #expect(states?[issues[3].key] == .duplicate && states?[issues[3].key]?.isOpen == false)
        #expect(states?[issues[4].key] == nil)
        let query = await runner.recordedArguments().first?.last ?? ""
        #expect(query.contains(#"i0: repository(owner: "theam", name: "shepherdr") { issue(number: 1) { state stateReason } }"#))
    }

    @Test func nothingIsAskedWithoutTheCLIOrForOddNames() async {
        let runner = RecordingRunner([])
        #expect(await GitHubLookup(runner: runner, executable: nil).issueStates(of: [issue("https://github.com/a/b/issues/1")]) == nil)
        if let odd = SessionResource(url: URL(string: "https://github.com/a%22%7D/b/issues/1")!) {
            #expect(await GitHubLookup(runner: runner, executable: URL(fileURLWithPath: "/usr/bin/true")).issueStates(of: [odd]) == nil)
        }
        #expect(await runner.recordedArguments().isEmpty)
    }
}
