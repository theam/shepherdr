import Foundation
import Testing
@testable import ShepherdrCore

private let box = Machine(profileID: "3c9e10aa", name: "buildbox", target: "box", session: "agents", isEnabled: true)
private let lab = Machine(profileID: "7b2d55f0", name: "Homelab", target: "lab", session: "default", isEnabled: true)
private let machines: [Machine] = [.local, box, lab]

private func row(_ terminal: String, on machine: Machine = .local, name: String = "claude", workspace: String? = nil,
                 state: AgentState = .idle) -> AgentRow {
    let agent = Agent(id: .init(machineID: machine.id, terminalID: terminal), name: name, kind: "claude", state: state,
                      reportedState: state.rawValue, workspaceID: "w-\(terminal)", workspaceName: workspace ?? terminal,
                      tabID: "w1:t1", tabName: "1", paneID: "w1:p1", directory: nil, project: nil, summary: nil, isLaunchPending: false)
    return AgentRow(agent: agent, machineName: machine.name, isStale: false)
}

private func letter(_ json: String, message: String? = nil, files: [String: Data] = [:]) throws -> Letter {
    var contents = files
    contents["letter.json"] = Data(json.utf8)
    if let message { contents["message.md"] = Data(message.utf8) }
    return try Letter(id: "20261015T101502Z-7f3a9c", contents: contents)
}

private let from = #""protocol":1,"id":"20261015T101502Z-7f3a9c","from":{"pane":"w4:p1","terminal":"term_fixer"}"#

struct LetterTests {
    @Test func lettersAreCheckedBeforeAnythingHappens() throws {
        #expect(try letter("{\(from),\"kind\":\"notify\"}", message: "Hi").content == .notify)
        let rejected: [(String, String?)] = [
            (#"{"protocol":2,"id":"20261015T101502Z-7f3a9c","kind":"notify","from":{}}"#, "x"),            // a newer format
            (#"{"protocol":1,"id":"20261015T101502Z-000000","kind":"notify","from":{}}"#, "x"),            // another letter's ID
            ("{\(from),\"kind\":\"notify\"}", nil),                                                         // nothing to say
            ("{\(from),\"kind\":\"open\",\"url\":\"file:///etc/passwd\"}", nil),                            // not http
            ("{\(from),\"kind\":\"open\",\"url\":\"javascript:alert(1)\"}", nil),
            ("{\(from),\"kind\":\"handoff\",\"files\":[\"files/../../x\"]}", "x"),                          // a path outside
            ("{\(from),\"kind\":\"handoff\",\"files\":[\"files/missing.md\"]}", "x"),                       // a missing file
            ("{\(from),\"kind\":\"wait\",\"sessions\":[]}", nil),
            ("{\(from),\"kind\":\"handoff\",\"to\":\"a\\nb\"}", "x"),                                       // control characters
            (#"{"protocol":1,"id":"20261015T101502Z-7f3a9c","kind":"notify","from":{"pane":"w1:p1","terminal":"../x"}}"#, "x"),
            ("{\(from),\"kind\":\"spawned\",\"child\":{\"machine\":\"elsewhere\",\"pane\":\"w9:p1\",\"terminal\":\"t\"}}", nil),
            ("{\(from),\"kind\":\"rm -rf\"}", "x"),
            ("not json", "x"),
        ]
        for (json, message) in rejected {
            #expect(throws: LetterError.self, "\(json)") { try letter(json, message: message) }
        }
        #expect(throws: LetterError.self) { try Letter(id: "../../etc", contents: ["letter.json": Data("{}".utf8)]) }
    }

    @Test func closeLettersNameSessionsOrNone() throws {
        #expect(try letter("{\(from),\"kind\":\"close\",\"sessions\":[],\"force\":false}").content == .close([], force: false))
        #expect(try letter("{\(from),\"kind\":\"close\",\"sessions\":[\"api\",\" \"],\"force\":true}").content == .close(["api"], force: true))
        // A letter that leaves out force closes nothing by force.
        #expect(try letter("{\(from),\"kind\":\"close\",\"sessions\":[\"api\"]}").content == .close(["api"], force: false))
        #expect(throws: LetterError.self) { try letter("{\(from),\"kind\":\"close\",\"sessions\":[\"a\\nb\"]}") }
    }

    @Test func headlinesAreTheFirstLineOfTheMessage() throws {
        let handoff = try letter("{\(from),\"kind\":\"handoff\",\"to\":null,\"files\":[]}", message: "\n  PR opened: theam/api#41  \nDetails")
        #expect(handoff.headline == "PR opened: theam/api#41")
    }
}

struct MailPlannerTests {
    private let planner = row("term_planner", name: "planner", workspace: "coordination")
    private let fixer = row("term_fixer", on: box, name: "fixer", workspace: "api")

    private func context(_ origin: Machine, trusted: Bool = false, rows: [AgentRow]? = nil,
                         waits: [Agent.ID: [Agent.ID]] = [:]) -> MailContext {
        MailContext(origin: origin, isTrusted: trusted, rows: rows ?? [planner, fixer], machines: machines, macName: "Studio", waits: waits)
    }

    private func items(_ actions: [MailAction]) -> [MailItem] {
        actions.compactMap { if case .keep(let item) = $0 { item } else { nil } }
    }

    @Test func aSpawnedSessionNestsUnderItsParentAndGetsItsPendingPrompt() throws {
        let spawned = try letter("{\(from),\"kind\":\"spawned\",\"child\":{\"machine\":\"profile:3c9e10aa\",\"pane\":\"w9:p1\",\"terminal\":\"term_new\",\"workspace\":\"w9\"},\"name\":\"api-fix\",\"agent\":\"claude\",\"placement\":\"workspace\",\"wait\":true,\"prompt\":\"pending\"}",
                                 message: "Fix the test")
        let actions = MailPlanner.plan(spawned, folder: "/inbox/local/x", context: context(.local))
        let parent = Agent.ID(machineID: "local", terminalID: "term_fixer")
        let child = Agent.ID(machineID: box.id, terminalID: "term_new")
        #expect(actions.prefix(2) == [.place(child, after: parent), .wait(parent, for: child)])
        let prompt = try #require(items(actions).first)
        #expect(prompt.kind == .prompt && prompt.recipient == child && prompt.status == .queued)
        #expect(MailPlanner.prompt(for: prompt, message: "Fix the test", messagePath: nil, attachments: []) == "Fix the test")

        // A remote machine's profiles mean something only to the Shepherdr running there.
        #expect(MailPlanner.plan(spawned, folder: "/x", context: context(box)) == [.elsewhere])

        // Without --no-wait it waits; with it, it only takes its place.
        let free = try letter("{\(from),\"kind\":\"spawned\",\"child\":{\"machine\":\"here\",\"pane\":\"w9:p1\",\"terminal\":\"term_new\"},\"name\":\"x\",\"agent\":null,\"wait\":false,\"prompt\":\"none\"}")
        #expect(MailPlanner.plan(free, folder: "/x", context: context(box)) ==
                [.place(.init(machineID: box.id, terminalID: "term_new"), after: .init(machineID: box.id, terminalID: "term_fixer"))])
    }

    @Test func lettersNamingAMachineThisShepherdrDoesntKeepAreLeftForAnother() throws {
        // Another Shepherdr keeps a Mac this one doesn't: a session requested there is for that one.
        let request = try letter("{\(from),\"kind\":\"spawn-request\",\"machine\":\"Laptop\",\"cwd\":\"~\",\"agent\":\"claude\",\"name\":\"docs-fix\",\"wait\":true,\"prompt\":null}")
        let elsewhere = MailPlanner.plan(request, folder: "/x", context: context(box))
        #expect(elsewhere == [.elsewhere])
        #expect(MailHandling(elsewhere) == .elsewhere)
        // This Mac and its machines go by their names in the lists, in any case.
        for name in ["studio", "Homelab", "BUILDBOX"] {
            let known = try letter("{\(from),\"kind\":\"spawn-request\",\"machine\":\"\(name)\",\"cwd\":\"~\",\"agent\":null,\"name\":null,\"wait\":false,\"prompt\":null}")
            #expect(MailHandling(MailPlanner.plan(known, folder: "/x", context: context(box))) == .waitsForUser, "\(name)")
        }
        // Sessions named on a machine it doesn't keep.
        let handoff = try letter("{\(from),\"kind\":\"handoff\",\"to\":\"planner@Laptop\",\"body\":\"message.md\",\"files\":[]}", message: "Done")
        #expect(MailPlanner.plan(handoff, folder: "/x", context: context(box)) == [.elsewhere])
        for json in ["\"kind\":\"wait\",\"sessions\":[\"planner\",\"reviewer@Laptop\"]", "\"kind\":\"resume\",\"sessions\":[\"reviewer@Laptop\"]",
                     "\"kind\":\"close\",\"sessions\":[\"reviewer@Laptop\"],\"force\":false"] {
            #expect(MailPlanner.plan(try letter("{\(from),\(json)}"), folder: "/x", context: context(box)) == [.elsewhere], "\(json)")
        }
        // A machine it does keep is looked up as before.
        let known = try letter("{\(from),\"kind\":\"handoff\",\"to\":\"planner@Studio\",\"body\":\"message.md\",\"files\":[]}", message: "Done")
        #expect(items(MailPlanner.plan(known, folder: "/x", context: context(box))).first?.recipient == planner.id)
    }

    @Test func whatOnlyAsksTheUserWaitsUnclaimedAndTheRestIsClaimedAtOnce() throws {
        let handoff = try letter("{\(from),\"kind\":\"handoff\",\"to\":null,\"body\":\"message.md\",\"files\":[]}", message: "Done")
        let waits = [planner.id: [fixer.id]]
        // From another machine to this Mac, it asks first; from a machine you trust, it goes.
        #expect(MailHandling(MailPlanner.plan(handoff, folder: "/x", context: context(box, waits: waits))) == .waitsForUser)
        #expect(MailHandling(MailPlanner.plan(handoff, folder: "/x", context: context(box, trusted: true, waits: waits))) == .applies)
        // With nobody waiting, you pick where it goes: that asks too.
        #expect(MailHandling(MailPlanner.plan(handoff, folder: "/x", context: context(box))) == .waitsForUser)
        // Notifications, holds and pins apply at once.
        let notify = try letter("{\(from),\"kind\":\"notify\"}", message: "Hi")
        #expect(MailHandling(MailPlanner.plan(notify, folder: "/x", context: context(box))) == .applies)
        #expect(MailHandling([]) == .applies)
    }

    @Test func handoffsGoToWhoeverWaitsAndAskBeforeCrossingFromAnotherMachine() throws {
        let handoff = try letter("{\(from),\"kind\":\"handoff\",\"to\":null,\"body\":\"message.md\",\"files\":[\"files/REPORT.md\"]}",
                                 message: "PR opened", files: ["files/REPORT.md": Data("# R".utf8)])
        let waits = [planner.id: [fixer.id]]
        let asked = items(MailPlanner.plan(handoff, folder: "/inbox/buildbox/x", context: context(box, waits: waits)))
        #expect(asked.count == 1)
        #expect(asked[0].recipient == planner.id && asked[0].status == .needsApproval && asked[0].kind == .handoff)
        #expect(asked[0].senderName == "fixer" && asked[0].originName == "buildbox" && asked[0].files == ["files/REPORT.md"])

        let trusted = items(MailPlanner.plan(handoff, folder: "/x", context: context(box, trusted: true, waits: waits)))
        #expect(trusted[0].status == .queued)

        // Within one machine nothing crosses, so nothing is asked.
        let coordinator = row("term_coord", on: box, name: "coord")
        let sameMachine = items(MailPlanner.plan(handoff, folder: "/x", context: context(box, rows: [coordinator, fixer],
                                                                                         waits: [coordinator.id: [fixer.id]])))
        #expect(sameMachine[0].status == .queued && sameMachine[0].recipient == coordinator.id)

        // Nobody waits: the user picks the recipient.
        let orphan = items(MailPlanner.plan(handoff, folder: "/x", context: context(box)))
        #expect(orphan[0].status == .needsRecipient && orphan[0].recipient == nil && orphan[0].sender == fixer.id)

        let text = MailPlanner.prompt(for: asked[0], message: "PR opened\n", messagePath: "/inbox/buildbox/x/message.md",
                                      attachments: ["/inbox/buildbox/x/files/REPORT.md"])
        #expect(text == "Handoff from fixer on buildbox, through Shepherdr:\n\nPR opened\n\nAttached file: /inbox/buildbox/x/files/REPORT.md")
        let long = MailPlanner.prompt(for: asked[0], message: String(repeating: "a", count: 7_000), messagePath: "/m.md", attachments: [])
        #expect(long.hasSuffix("The message is long, so it is in /m.md."))
    }

    @Test func handoffsCanNameTheirRecipient() throws {
        let named = try letter("{\(from),\"kind\":\"handoff\",\"to\":\"Coordination@Studio\",\"files\":[]}", message: "Done")
        let found = items(MailPlanner.plan(named, folder: "/x", context: context(box)))
        #expect(found[0].recipient == planner.id && found[0].status == .needsApproval)
        let missing = try letter("{\(from),\"kind\":\"handoff\",\"to\":\"nobody\",\"files\":[]}", message: "Done")
        let unknown = items(MailPlanner.plan(missing, folder: "/x", context: context(box)))
        #expect(unknown[0].status == .needsRecipient && unknown[0].problem == "No session is named nobody." && unknown[0].addressedTo == "nobody")
    }

    @Test func waitsResumesLinksAndNotices() throws {
        let sender = Agent.ID(machineID: box.id, terminalID: "term_fixer")
        let reviewer = row("term_rev", on: box, name: "reviewer")
        let wait = try letter("{\(from),\"kind\":\"wait\",\"sessions\":[\"reviewer\",\"ghost\"]}")
        let actions = MailPlanner.plan(wait, folder: "/x", context: context(box, rows: [planner, fixer, reviewer]))
        #expect(actions.first == .wait(sender, for: reviewer.id))
        if case .problem(let who, _) = actions.last { #expect(who == sender) } else { Issue.record("expected a problem") }

        let resume = try letter("{\(from),\"kind\":\"resume\",\"sessions\":[]}")
        #expect(MailPlanner.plan(resume, folder: "/x", context: context(box)) == [.stopWaiting(sender, for: nil)])

        let pin = try letter("{\(from),\"kind\":\"pin\",\"url\":\"https://example.com/docs\",\"title\":\"Docs\"}")
        guard case .pin(let target, let resource) = MailPlanner.plan(pin, folder: "/x", context: context(box)).first else {
            Issue.record("expected a pin")
            return
        }
        #expect(target == sender && resource.kind == .link && resource.title == "Docs" && resource.name == "example.com/docs")
        let pull = try letter("{\(from),\"kind\":\"pin\",\"url\":\"https://github.com/theam/api/pull/41\",\"title\":null}")
        if case .pin(_, let resource) = MailPlanner.plan(pull, folder: "/x", context: context(box)).first {
            #expect(resource.kind == .pullRequest)
        }

        // Pages from another machine are only suggested; from this Mac they open.
        let open = try letter("{\(from),\"kind\":\"open\",\"url\":\"http://localhost:3000\"}")
        let suggested = items(MailPlanner.plan(open, folder: "/x", context: context(box)))
        #expect(suggested[0].kind == .openPage && suggested[0].status == .needsApproval && suggested[0].url?.absoluteString == "http://localhost:3000")
        #expect(MailPlanner.plan(open, folder: "/x", context: context(.local)) ==
                [.open(.init(machineID: "local", terminalID: "term_fixer"), URL(string: "http://localhost:3000")!)])

        let notice = try letter("{\(from),\"kind\":\"notify\"}", message: "Migration finished")
        #expect(MailPlanner.plan(notice, folder: "/x", context: context(box)) == [.notify(sender, "Migration finished")])

        // Requests for sessions wait for the user unless the machine is trusted.
        let request = try letter("{\(from),\"kind\":\"spawn-request\",\"machine\":\"Studio\",\"cwd\":\"~/src/api\",\"agent\":\"codex\",\"name\":null,\"wait\":true,\"prompt\":\"message.md\"}",
                                 message: "Look")
        let asked = items(MailPlanner.plan(request, folder: "/x", context: context(box)))
        #expect(asked[0].status == .needsApproval && asked[0].request == .init(machine: "Studio", directory: "~/src/api", agent: "codex", name: nil, wait: true))
        #expect(items(MailPlanner.plan(request, folder: "/x", context: context(box, trusted: true)))[0].status == .queued)
    }
}

struct ClosePlanTests {
    private let planner = row("term_planner", name: "planner", workspace: "coordination")
    private let fixer = row("term_fixer", on: box, name: "fixer", workspace: "api", state: .working)
    private let reviewer = row("term_rev", on: box, name: "reviewer")
    private let busy = row("term_busy", on: box, name: "busy", workspace: "busy", state: .working)
    private let asking = row("term_ask", on: box, name: "asking", workspace: "asking", state: .blocked)
    private let compass = row("term_compass", name: "compass")

    private func plan(_ json: String, from origin: Machine, trusted: Bool = false) throws -> [MailAction] {
        let context = MailContext(origin: origin, isTrusted: trusted, rows: [planner, fixer, reviewer, busy, asking, compass],
                                  machines: machines, macName: "Studio", waits: [:], protected: [compass.id])
        return MailPlanner.plan(try letter("{\(from),\"kind\":\"close\",\(json)}"), folder: "/x", context: context)
    }

    /// The close requests a plan keeps for the user.
    private func requests(_ actions: [MailAction]) -> [MailItem] {
        actions.compactMap { if case .keep(let item) = $0, item.kind == .close, item.status == .needsApproval { item } else { nil } }
    }

    @Test func aSessionAsksTheUserToCloseItself() throws {
        for json in [#""sessions":[],"force":false"#, #""sessions":[],"force":true"#, #""sessions":["fixer"],"force":false"#] {
            let asked = requests(try plan(json, from: box))
            #expect(asked.map(\.recipient) == [fixer.id] && asked.first?.sender == fixer.id, "\(json)")
        }
        // A shell, such as a script's, too.
        let shell = Agent.ID(machineID: lab.id, terminalID: "term_fixer")
        #expect(requests(try plan(#""sessions":[],"force":false"#, from: lab)).map(\.recipient) == [shell])
    }

    @Test func otherSessionsAreAskedAboutUnlessTheyWorkOrNeedTheUser() throws {
        let asked = requests(try plan(#""sessions":["reviewer"],"force":false"#, from: box))
        #expect(asked.map(\.recipient) == [reviewer.id] && asked.first?.sender == fixer.id && asked.first?.addressedTo == "reviewer")
        let refused = try plan(#""sessions":["busy","asking","ghost"],"force":false"#, from: box)
        #expect(refused.count == 3)
        for (action, words) in zip(refused, ["busy is working", "asking needs the user", "No session is named ghost"]) {
            if case .problem(let who, let text) = action { #expect(who == fixer.id && text.contains(words), "\(text)") }
            else { Issue.record("expected a problem, got \(action)") }
        }
        let forced = requests(try plan(#""sessions":["busy","asking"],"force":true"#, from: box))
        #expect(forced.map(\.recipient) == [busy.id, asking.id])
        #expect(Set(forced.map(\.id)).count == 2)
    }

    @Test func closingIsAlwaysTheUsersCall() throws {
        // Whichever machine asks, however trusted, this Mac included: nothing closes on its own.
        for trusted in [false, true] {
            let asked = requests(try plan(#""sessions":["planner"],"force":false"#, from: box, trusted: trusted))
            #expect(asked.map(\.recipient) == [planner.id] && asked.first?.sender == fixer.id)
        }
        let sender = Agent.ID(machineID: "local", terminalID: "term_fixer")
        let fromHere = requests(try plan(#""sessions":["reviewer@buildbox"],"force":false"#, from: .local))
        #expect(fromHere.map(\.recipient) == [reviewer.id] && fromHere.first?.sender == sender)
    }

    @Test func compassAndLettersWithoutASenderCloseNothing() throws {
        let compassClose = try plan(#""sessions":["compass"],"force":true"#, from: .local)
        if case .problem(_, let text) = compassClose.first { #expect(text.contains("Compass")) } else { Issue.record("expected a problem") }
        let outside = MailPlanner.plan(try letter(#"{"protocol":1,"id":"20261015T101502Z-7f3a9c","from":{},"kind":"close","sessions":["reviewer"]}"#),
                                       folder: "/x", context: MailContext(origin: box, isTrusted: true, rows: [reviewer], machines: machines,
                                                                          macName: "Studio", waits: [:]))
        if case .problem(nil, _) = outside.first {} else { Issue.record("expected a problem without a session, got \(outside)") }
    }
}

struct SessionLookupTests {
    @Test func namesMatchAgentsBeforeWorkspacesAndPreferTheSendersMachine() {
        let local = row("t1", name: "reviewer", workspace: "api")
        let remote = row("t2", on: box, name: "reviewer", workspace: "api")
        let other = row("t3", on: box, name: "tester", workspace: "Reviewer")
        let rows = [local, remote, other]
        #expect(SessionLookup.find("Reviewer", in: rows, machines: machines, macName: "Studio", preferring: box.id) == .found(remote.id))
        #expect(SessionLookup.find("reviewer", in: rows, machines: machines, macName: "Studio", preferring: "local") == .found(local.id))
        #expect(SessionLookup.find("reviewer", in: rows, machines: machines, macName: "Studio", preferring: lab.id) == .ambiguous([local.id, remote.id]))
        #expect(SessionLookup.find("reviewer@studio", in: rows, machines: machines, macName: "Studio", preferring: box.id) == .found(local.id))
        #expect(SessionLookup.find("tester@buildbox", in: rows, machines: machines, macName: "Studio", preferring: nil) == .found(other.id))
        #expect(SessionLookup.find("ghost", in: rows, machines: machines, macName: "Studio", preferring: nil) == .missing)
        // An @ that names no machine is part of the name.
        #expect(SessionLookup.find("a@b", in: [row("t4", name: "a@b")], machines: machines, macName: "Studio", preferring: nil) == .found(.init(machineID: "local", terminalID: "t4")))
    }
}

@MainActor
struct MailStoreTests {
    private func defaults() -> UserDefaults {
        let name = "mail-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func item(_ id: String, sender: Agent.ID?, recipient: Agent.ID?, status: MailItem.Status) -> MailItem {
        MailItem(id: id, letterID: "20261015T101502Z-7f3a9c", kind: .handoff, origin: box.id, originName: "buildbox",
                 sender: sender, senderName: "fixer", recipient: recipient, status: status, received: Date(), folder: "/x",
                 headline: "PR", hasMessage: true, files: [], addressedTo: nil)
    }

    @Test func itemsAndReadLettersSurviveRelaunchButNotForever() {
        let defaults = defaults()
        let store = MailStore(defaults: defaults)
        let sender = Agent.ID(machineID: box.id, terminalID: "f")
        let recipient = Agent.ID(machineID: "local", terminalID: "p")
        store.add(item("a", sender: sender, recipient: recipient, status: .needsApproval))
        store.add(item("b", sender: sender, recipient: nil, status: .needsRecipient))
        store.add(item("a", sender: sender, recipient: nil, status: .queued))
        store.markRead(["20261015T101502Z-7f3a9c"], from: box.id, at: Date().addingTimeInterval(-40 * 86_400))
        store.markRead(["20261015T101503Z-7f3a9c"], from: box.id)

        let again = MailStore(defaults: defaults)
        #expect(again.items.map(\.id) == ["a", "b"])
        #expect(again.items(for: recipient).map(\.id) == ["a"])
        #expect(again.items(for: sender).map(\.id) == ["b"])
        #expect(again.needsUser(recipient))
        again.update("a") { $0.status = .queued }
        #expect(!again.needsUser(recipient))
        #expect(!again.hasRead("20261015T101502Z-7f3a9c", from: box.id))
        #expect(again.hasRead("20261015T101503Z-7f3a9c", from: box.id))
        again.remove("b")
        #expect(MailStore(defaults: defaults).items.map(\.id) == ["a"])
    }

    @Test func recentlyReadLettersAreTheOnesATripSkips() {
        let store = MailStore(defaults: defaults())
        store.markRead(["20261015T101502Z-aaaaaa"], from: box.id, at: Date().addingTimeInterval(-9 * 86_400))
        store.markRead(["20261015T101503Z-bbbbbb", "20261015T101504Z-cccccc"], from: box.id)
        store.markRead(["20261015T101505Z-dddddd"], from: lab.id)
        #expect(store.recentlyRead(from: box.id) == ["20261015T101504Z-cccccc", "20261015T101503Z-bbbbbb"])
        #expect(store.recentlyRead(from: box.id, limit: 1) == ["20261015T101504Z-cccccc"])
    }

    @Test func mailKeptBeforeClaimsNeedsNoClaim() throws {
        let kept = item("a", sender: nil, recipient: nil, status: .needsApproval)
        let data = try JSONEncoder().encode([kept])
        #expect(!String(decoding: data, as: UTF8.self).contains("isClaimed"))
        #expect(try JSONDecoder().decode([MailItem].self, from: data).first?.needsClaim == false)
        var waiting = kept
        waiting.isClaimed = false
        #expect(waiting.needsClaim)
    }

    @Test func deliveriesAreNamedTheSameOnEveryShepherdr() {
        #expect(item("remote:3c9e10aa/20261015T101502Z-7f3a9c/1", sender: nil, recipient: nil, status: .queued).deliveryID == "20261015T101502Z-7f3a9c/1")
        #expect(item("local/20261015T101502Z-7f3a9c/0/prompt", sender: nil, recipient: nil, status: .queued).deliveryID == "20261015T101502Z-7f3a9c/0/prompt")
        #expect(item("compass/20261015T101502Z-7f3a9c", sender: nil, recipient: nil, status: .queued).deliveryID == "20261015T101502Z-7f3a9c")
    }

    @Test func onlyNewDoorbellsCallForATrip() {
        let store = MailStore(defaults: defaults())
        let bells = ["term_a": "20261015T101502Z-7f3a9c"]
        #expect(store.hasNewDoorbells(bells, on: box.id))
        store.answer(bells, on: box.id)
        #expect(!store.hasNewDoorbells(bells, on: box.id))
        #expect(!store.hasNewDoorbells([:], on: box.id))
        #expect(store.hasNewDoorbells(["term_a": "20261015T101503Z-7f3a9c"], on: box.id))
        #expect(store.hasNewDoorbells(bells, on: "local"))
    }
}

struct DoorbellDecodingTests {
    @Test func doorbellsAreReadFromPanesAndAgents() throws {
        let json = """
        {"result":{"type":"session_snapshot","snapshot":{"version":"0.9.3","protocol":1,
          "workspaces":[{"workspace_id":"w1","label":"api","pane_count":2,"tab_count":1,"agent_status":"idle"}],
          "tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1"}],
          "panes":[{"pane_id":"w1:p1","terminal_id":"term_a","workspace_id":"w1","tab_id":"w1:t1","tokens":{"shepherdr-mail":"20261015T101502Z-7f3a9c"}},
                   {"pane_id":"w1:p2","terminal_id":"term_b","workspace_id":"w1","tab_id":"w1:t1","tokens":{"shepherdr-mail":"$(boom)"}},
                   {"pane_id":"w1:p3","terminal_id":"term_c","workspace_id":"w1","tab_id":"w1:t1"}],
          "agents":[{"terminal_id":"term_c","agent_status":"idle","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p3",
                     "tokens":{"shepherdr-mail":"20261015T101503Z-aaaaaa","summary":"x"}}]}}}
        """
        let snapshot = try HerdrJSON.snapshot(Data(json.utf8), machine: .local)
        #expect(snapshot.doorbells == ["term_a": "20261015T101502Z-7f3a9c", "term_c": "20261015T101503Z-aaaaaa"])
    }
}
