import Foundation
import Testing
@testable import ShepherdrCore

private let box = Machine(profileID: "3c9e10aa", name: "buildbox", target: "box", session: "agents", isEnabled: true)
private let lab = Machine(profileID: "7b2d55f0", name: "Homelab", target: "lab", session: "default", isEnabled: true)

private func agent(_ terminal: String, on machine: Machine = .local, name: String, workspace: String,
                   workspaceID: String, pane: String) -> SessionDirectory.Entry {
    SessionDirectory.Entry(agent: Agent(
        id: .init(machineID: machine.id, terminalID: terminal), name: name, kind: "claude", state: .idle,
        reportedState: "idle", workspaceID: workspaceID, workspaceName: workspace, tabID: "\(workspaceID):t1", tabName: "1",
        paneID: pane, directory: nil, project: nil, summary: nil, isLaunchPending: false))
}

private func shell(_ terminal: String, on machine: Machine = .local, workspace: String, workspaceID: String,
                   pane: String) -> SessionDirectory.Entry {
    SessionDirectory.Entry(pane: TerminalPane(terminalID: terminal, paneID: pane, workspaceID: workspaceID, tabID: "\(workspaceID):t1",
                                              workspaceName: workspace, title: "1 · \(pane)", directory: nil),
                           machineID: machine.id)
}

private let own = Agent.ID(machineID: Machine.local.id, terminalID: "term_0")
private let fixLogin = Agent.ID(machineID: Machine.local.id, terminalID: "term_1")
private let gateway = Agent.ID(machineID: Machine.local.id, terminalID: "term_2")
private let fixLoginOnBox = Agent.ID(machineID: box.id, terminalID: "term_b1")
private let api = Agent.ID(machineID: box.id, terminalID: "term_b2")
private let reviewerOnBox = Agent.ID(machineID: box.id, terminalID: "term_b3")
private let reviewerOnLab = Agent.ID(machineID: lab.id, terminalID: "term_c1")

private let directory = SessionDirectory(entries: [
    agent("term_0", name: "coordinator", workspace: "shepherdr", workspaceID: "w1", pane: "w1:p1"),
    agent("term_1", name: "fix-login", workspace: "login", workspaceID: "w2", pane: "w2:p1"),
    shell("term_2", workspace: "api gateway", workspaceID: "w3", pane: "w3:p1"),
    // An agent Herdr didn't name goes by its program's name, which says nothing about which one it is.
    agent("term_3", name: "Claude Code", workspace: "ui", workspaceID: "w4", pane: "w4:p1"),
    agent("term_4", name: "helper", workspace: "shepherdr", workspaceID: "w1", pane: "w1:p2"),
    agent("term_b1", on: box, name: "fix-login", workspace: "login", workspaceID: "w1", pane: "w1:p1"),
    agent("term_b2", on: box, name: "api", workspace: "api", workspaceID: "w2", pane: "w2:p1"),
    agent("term_b3", on: box, name: "reviewer", workspace: "review", workspaceID: "w3", pane: "w3:p1"),
    agent("term_c1", on: lab, name: "reviewer", workspace: "w5", workspaceID: "w5", pane: "w1:p1"),
], machines: [.local, box, lab])

/// The session named where `text` appears in `line`, clicked `offset` characters into it.
private func session(_ line: String, at text: String, offset: Int = 0, from caller: Agent.ID = own) -> Agent.ID? {
    let column = line.distance(from: line.startIndex, to: line.range(of: text)!.lowerBound) + offset
    return directory.session(in: Array(line), column: column, from: caller)
}

@Suite struct SessionLinkTests {
    @Test func paneIDsMeanTheCallersMachineUnlessALineNamesAnother() {
        #expect(session("In Herdr: pane w2:p1.", at: "w2:p1") == fixLogin)
        #expect(session("In Herdr: pane w2:p1.", at: "w2:p1", offset: 3) == fixLogin)
        #expect(session(#"{"pane_id":"w2:p1","focused":true}"#, at: "w2:p1") == fixLogin)
        #expect(session("pane w2:p1@buildbox is busy", at: "w2:p1") == api)
        // `shepherdr spawn` on this Mac says which saved machine the pane is on.
        let spawned = #"In Herdr: pane w3:p1, through "herdr --machine 3c9e10aa"."#
        #expect(session(spawned, at: "w3:p1") == reviewerOnBox)
        #expect(session("herdr --machine=Homelab pane list: w1:p1", at: "w1:p1") == reviewerOnLab)
        // Another machine's profiles aren't the ones Shepherdr knows.
        #expect(session(spawned, at: "w3:p1", from: reviewerOnLab) == nil)
        #expect(session("herdr --machine elsewhere pane w2:p1", at: "w2:p1") == nil)
    }

    @Test func idsThatAreNotWholeOrNotThereLinkNothing() {
        #expect(session("pane w1:p1 is this one", at: "w1:p1") == nil)
        #expect(session("pane w9:p9 is gone", at: "w9:p9") == nil)
        #expect(session("see logs/w2:p1 for details", at: "w2:p1") == nil)
        #expect(session("pane w2:p1 is busy", at: "pane") == nil)
        #expect(session("pane w2:p1 is busy", at: " is") == nil)
    }

    @Test func terminalIDsMeanTheirSessionOnAnyMachine() {
        #expect(session("terminal term_c1 closed", at: "term_c1") == reviewerOnLab)
        #expect(session("terminal term_1: idle", at: "term_1") == fixLogin)
        #expect(session("terminal term_0 closed", at: "term_0") == nil)
        #expect(session("terminal term_x9 closed", at: "term_x9") == nil)
    }

    @Test func namesMeanTheCallersMachineFirst() {
        let started = "Started fix-login (claude) on buildbox, in /home/me/app, and sent it your prompt."
        #expect(session(started, at: "fix-login") == fixLogin)
        #expect(session(started, at: "fix-login", offset: 5) == fixLogin)
        #expect(session("Started fix-login.", at: "fix-login") == fixLogin)
        #expect(session("ask fix-login@buildbox to rebase", at: "fix-login") == fixLoginOnBox)
        #expect(session("ask fix-login@buildbox to rebase", at: "buildbox") == fixLoginOnBox)
        #expect(session("`api` is green", at: "api") == api)
        #expect(session("api: 3 tests failed", at: "api") == api)
        #expect(session("Started a shell, login, on this Mac.", at: "login") == fixLogin)
    }

    @Test func namesSharedElsewhereNeedTheirMachine() {
        #expect(session("hand it to reviewer", at: "reviewer") == nil)
        #expect(session("hand it to reviewer@Homelab now", at: "reviewer") == reviewerOnLab)
        #expect(session("hand it to reviewer@homelab now", at: "homelab") == reviewerOnLab)
        #expect(session("hand it to reviewer@nowhere now", at: "reviewer") == nil)
    }

    @Test func aSessionsOwnNamesAndWorkspaceAreAboutItself() {
        #expect(session("coordinator: waiting", at: "coordinator") == nil)
        #expect(session("cd shepherdr && swift test", at: "shepherdr") == nil)
        // Another pane of its workspace goes by a name of its own.
        #expect(session("helper is reviewing", at: "helper") == Agent.ID(machineID: "local", terminalID: "term_4"))
        #expect(session("cd shepherdr && swift test", at: "shepherdr", from: fixLogin) == own)
    }

    @Test func namesInsidePathsFilesAndLongerWordsAreNotSessions() {
        #expect(session("open /Users/me/projects/api now", at: "api") == nil)
        #expect(session("edit api.ts", at: "api") == nil)
        #expect(session("my-api is down", at: "api") == nil)
        #expect(session("mail api@example.com", at: "api") == nil)
        #expect(session("the apis are down", at: "api") == nil)
        #expect(session("fix-login-v2 shipped", at: "fix-login") == nil)
    }

    @Test func theLongestNameWins() {
        #expect(session("restart api gateway please", at: "api") == gateway)
        #expect(session("restart api gateway please", at: "gateway") == gateway)
        #expect(session("restart api please", at: "api") == api)
    }

    @Test func genericShortAndUnnamedNamesAreLeftOut() {
        #expect(session("Claude Code is ready", at: "Claude") == nil)
        #expect(session("open the ui", at: "ui") == nil)
        #expect(session("workspace w5 is quiet", at: "w5") == nil)
        #expect(SessionDirectory.isDistinctive("fix-login"))
        #expect(!SessionDirectory.isDistinctive("w12"))
        #expect(!SessionDirectory.isDistinctive("42"))
    }

    @Test func linksCarryTheirSessionOnly() {
        let link = SessionLink.url(for: Agent.ID(machineID: "remote:3c9e10aa", terminalID: "term_b1"))
        #expect(link.scheme == "shepherdr-session")
        #expect(SessionLink.session(in: link) == fixLoginOnBox)
        #expect(SessionLink.session(in: URL(string: "https://example.com/?machine=local&terminal=term_1")!) == nil)
        #expect(SessionLink.session(in: URL(string: "shepherdr-session:open?machine=local")!) == nil)
    }
}
