import Foundation
import Testing
@testable import ShepherdrCore

struct HoldsTests {
    private func machine(_ id: String?, online: Bool = true, terminals: [String]) -> MachineState {
        var state = MachineState(machine: Machine(profileID: id, name: id ?? "Local", target: id, session: "default", isEnabled: true))
        state.connection = online ? .online : .unreachable
        state.snapshot = MachineSnapshot(version: "0.9.3", protocolVersion: 1, workspaces: [], agents: [], panes: terminals.map {
            TerminalPane(terminalID: $0, paneID: "w1:p1", workspaceID: "w1", tabID: "w1:t1", workspaceName: "w", title: "", directory: nil)
        })
        return state
    }

    @Test func holdsForgetSessionsTheirMachineStoppedReporting() {
        let here = Agent.ID(machineID: "local", terminalID: "term_here")
        let closed = Agent.ID(machineID: "local", terminalID: "term_closed")
        let remote = Agent.ID(machineID: "remote:box", terminalID: "term_remote")
        let unknown = Agent.ID(machineID: "remote:gone", terminalID: "term_x")
        let ids: Set = [here, closed, remote, unknown]
        let start = Date(timeIntervalSince1970: 1_000)
        var missing: [Agent.ID: Date] = [:]
        var machines = [machine(nil, terminals: ["term_here"]), machine("box", online: false, terminals: [])]
        func gone(_ held: Set<Agent.ID> = ids, after seconds: TimeInterval) -> [Agent.ID] {
            HoldUpkeep.gone(held, machines: machines, missingSince: &missing, now: start + seconds)
        }

        // Missing for a moment is not gone: a new session may not be in the snapshot yet.
        #expect(gone(after: 0).isEmpty)
        #expect(missing == [closed: start])
        #expect(gone(after: 29).isEmpty)
        #expect(gone(after: 30) == [closed])

        // A machine that doesn't answer says nothing; once it answers without the session, it counts.
        machines[1] = machine("box", terminals: [])
        #expect(gone(after: 31) == [closed])
        #expect(gone(after: 61) == [closed, remote])

        // A session that comes back starts over, and sessions no longer held are dropped.
        machines[0] = machine(nil, terminals: ["term_here", "term_closed"])
        #expect(gone([closed], after: 62).isEmpty)
        #expect(missing.isEmpty)
    }

    @Test func aShellRunsUntilItsCommandIsBackAtThePrompt() {
        var run = ShellRun()
        #expect(run.see(running: false, output: "~ $ ") == .atPrompt)
        #expect(run.see(running: true, output: nil) == .running)
        #expect(run.see(running: true, output: nil) == .running)
        // Back at its prompt: the hold, which saw it start, tells it finished.
        #expect(run.see(running: false, output: nil) == .atPrompt)
    }

    @Test func aCommandThatFinishedBetweenTwoLooksShowsAsFinished() {
        var run = ShellRun()
        #expect(run.see(running: false, output: "~ $ \n\n") == .atPrompt)
        // Typing at the prompt only changes its last line.
        #expect(run.see(running: false, output: "~ $ ./depl") == .atPrompt)
        #expect(run.see(running: false, output: "~ $ ./deploy.sh\ndeployed\n~ $ ") == .finished)
        #expect(run.see(running: false, output: "~ $ ./deploy.sh\ndeployed\n~ $ ") == .finished)

        // Without its output, an idle shell can't tell.
        var blind = ShellRun()
        blind.see(running: false, output: nil)
        #expect(blind.see(running: false, output: nil) == .atPrompt)
    }

    @Test func processInfoSaysWhetherTheShellRunsACommand() throws {
        func info(_ foreground: String) -> Data {
            Data(#"{"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":95919,"foreground_processes":[\#(foreground)],"pane_id":"w1:p1","shell_pid":95522},"type":"pane_process_info"}}"#.utf8)
        }
        #expect(try HerdrJSON.runsCommand(info(#"{"argv":["sleep","15"],"name":"sleep","pid":95919}"#)) == true)
        #expect(try HerdrJSON.runsCommand(info(#"{"argv":["-zsh"],"name":"zsh","pid":95522}"#)) == false)
        let older = Data(#"{"result":{"process_info":{"shell_pid":95522},"type":"pane_process_info"}}"#.utf8)
        #expect(try HerdrJSON.runsCommand(older) == nil)
    }
}
