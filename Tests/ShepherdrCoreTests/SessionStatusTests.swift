import Foundation
import Testing
@testable import ShepherdrCore

struct SessionStatusTests {
    private static func id(_ terminal: String, on machine: String = "local") -> Agent.ID {
        Agent.ID(machineID: machine, terminalID: terminal)
    }

    private static func agent(_ state: AgentState, stale: Bool = false) -> OwnStatus { OwnStatus(.agent(state), isStale: stale) }
    private static func shell(_ activity: ShellActivity) -> OwnStatus { OwnStatus(.shell(activity)) }

    @Test func needingYouAndWorkingWinOverHolds() {
        #expect(SessionStatus.of(Self.agent(.blocked), isHeld: true) == .needsYou)
        #expect(SessionStatus.of(Self.agent(.working), isHeld: true) == .working)
        for state in [AgentState.idle, .done, .unknown] {
            #expect(SessionStatus.of(Self.agent(state), isHeld: true) == .waiting)
        }
        #expect(SessionStatus.of(Self.agent(.done), isHeld: false) == .done)
        #expect(SessionStatus.of(Self.agent(.idle), isHeld: false) == .idle)
        // What a machine that doesn't answer last said can't be trusted.
        #expect(SessionStatus.of(Self.agent(.working, stale: true), isHeld: true) == .stale)
        #expect(SessionStatus.of(Self.shell(.running), isHeld: false) == .running)
        #expect(SessionStatus.of(Self.shell(.finished), isHeld: false) == .finished)
        #expect(SessionStatus.of(Self.shell(.atPrompt), isHeld: false) == .shell)
    }

    @Test func aHoldStartsWithItsSessionAndFinishesWhenItIsFreeAgain() {
        #expect(HoldPhase.pending.advanced(by: .idle) == .pending)
        #expect(HoldPhase.pending.advanced(by: .shell) == .pending)
        #expect(HoldPhase.pending.advanced(by: .working) == .started)
        #expect(HoldPhase.pending.advanced(by: .waiting) == .started)
        #expect(HoldPhase.started.advanced(by: .needsYou) == .started)
        #expect(HoldPhase.started.advanced(by: .idle) == .finished)
        #expect(HoldPhase.started.advanced(by: .shell) == .finished)
        // A turn that ended before anyone looked, or a command that ran between two looks.
        #expect(HoldPhase.pending.advanced(by: .done) == .finished)
        #expect(HoldPhase.pending.advanced(by: .finished) == .finished)
        // Busy again, it is waited for again.
        #expect(HoldPhase.finished.advanced(by: .working) == .started)
        #expect(HoldPhase.finished.advanced(by: .idle) == .finished)
        for status in [SessionStatus.stale, .unknown] {
            #expect(HoldPhase.started.advanced(by: status) == .started)
        }
    }

    @Test func aChainOfHoldsWaitsForItsLastSession() {
        let planner = Self.id("planner"), lead = Self.id("lead"), script = Self.id("script", on: "remote:forge")
        var engine = StatusEngine()
        var holds: [Agent.ID: [Hold]] = [planner: [Hold(awaited: lead)], lead: [Hold(awaited: script)]]
        var own: [Agent.ID: OwnStatus] = [planner: Self.agent(.idle), lead: Self.agent(.idle), script: Self.shell(.running)]
        holds = engine.settle(own: own, holds: holds)
        #expect(engine.statuses[script] == .running)
        #expect(engine.statuses[lead] == .waiting)
        // The lead waits for the script, so the planner keeps waiting for the lead.
        #expect(engine.statuses[planner] == .waiting)
        #expect(holds[planner]?.first?.phase == .started)

        own[script] = Self.shell(.atPrompt)
        holds = engine.settle(own: own, holds: holds)
        #expect(engine.statuses[script] == .shell)
        #expect(holds[lead]?.first?.phase == .finished)
        #expect(engine.statuses[lead] == .idle)
        // The lead is free again, so the planner's hold on it finished too.
        #expect(holds[planner]?.first?.phase == .finished)
        #expect(engine.statuses[planner] == .idle)
    }

    @Test func aNewSessionKeepsItsWaiterOnHoldUntilItHasWorked() {
        let planner = Self.id("planner"), child = Self.id("child")
        var engine = StatusEngine()
        var own: [Agent.ID: OwnStatus] = [planner: Self.agent(.idle), child: Self.agent(.unknown)]
        var holds = engine.settle(own: own, holds: [planner: [Hold(awaited: child)]])
        #expect(engine.statuses[planner] == .waiting)
        own[child] = Self.agent(.idle)
        holds = engine.settle(own: own, holds: holds)
        #expect(engine.statuses[planner] == .waiting)
        own[child] = Self.agent(.working)
        holds = engine.settle(own: own, holds: holds)
        own[child] = Self.agent(.idle)
        holds = engine.settle(own: own, holds: holds)
        #expect(holds[planner] == [Hold(awaited: child, phase: .finished)])
        #expect(engine.statuses[planner] == .idle)
        // Working on the planner's answer, it still says what it does.
        own[planner] = Self.agent(.working)
        engine.settle(own: own, holds: holds)
        #expect(engine.statuses[planner] == .working)
    }

    @Test func onlyWhatChangedAndWhatWaitsForItIsWorkedOutAgain() {
        let planner = Self.id("planner"), child = Self.id("child"), other = Self.id("other")
        var engine = StatusEngine()
        var own: [Agent.ID: OwnStatus] = [planner: Self.agent(.idle), child: Self.agent(.working), other: Self.agent(.done)]
        let holds = engine.settle(own: own, holds: [planner: [Hold(awaited: child)]])
        #expect(engine.statuses == [planner: .waiting, child: .working, other: .done])
        // A session that closed leaves no status behind, and its waiter keeps its hold as it was.
        own[child] = nil
        let after = engine.settle(own: own, holds: holds)
        #expect(engine.statuses == [planner: .waiting, other: .done])
        #expect(after == holds)
    }

    @Test func aLoopOfHoldsStillSettles() {
        let first = Self.id("first"), second = Self.id("second")
        var engine = StatusEngine()
        let holds = engine.settle(own: [first: Self.agent(.idle), second: Self.agent(.idle)],
                                  holds: [first: [Hold(awaited: second)], second: [Hold(awaited: first)]])
        #expect(engine.statuses[first] == .waiting)
        #expect(engine.statuses[second] == .waiting)
        #expect(holds.count == 2)
    }

    @Test func holdsGoToHerdrInTokensOfEightyCharacters() {
        let waiter = Self.id("term_65e3710d44c5f1", on: "remote:forge")
        let holds = (0..<8).map { index in
            Hold(awaited: Self.id("term_65e3710d44c5f\(index)", on: index == 1 ? "local" : "remote:forge"),
                 phase: [.pending, .started, .finished][index % 3])
        }
        let values = HoldTokens.encode(holds, waiter: waiter)
        #expect(values.count == 3)
        #expect(values.allSatisfy { $0.count <= 80 })
        #expect(values[0].hasPrefix("pterm_65e3710d44c5f0,sterm_65e3710d44c5f1@local,"))
        var tokens: [String: String] = ["shepherdr-mail": "letter"]
        for (index, value) in values.enumerated() { tokens[HoldTokens.key(index)] = value }
        #expect(Set(tokens.keys) == ["shepherdr-mail", "shepherdr-waits", "shepherdr-waits-2", "shepherdr-waits-3"])
        #expect(HoldTokens.decode(tokens, waiter: waiter) == holds)
        #expect(HoldTokens.values(in: tokens) == values)
        #expect(HoldTokens.decode(["shepherdr-mail": "letter"], waiter: waiter) == nil)
        #expect(HoldTokens.values(in: [:]).isEmpty)
        // Holds past what Herdr has room for stay on this Mac only.
        let many = (0..<40).map { Hold(awaited: Self.id("term_\(100_000_000_000_000 + $0)")) }
        #expect(HoldTokens.encode(many, waiter: waiter).count == HoldTokens.chunks)
        // A token another version wrote, or garbled, gives what it can.
        #expect(HoldTokens.decode(["shepherdr-waits": "xterm_1,fterm_2,p,s@m"], waiter: waiter)
                == [Hold(awaited: Self.id("term_2", on: "remote:forge"), phase: .finished)])
    }
}
