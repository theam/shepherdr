import Foundation
import Testing
@testable import ShepherdrCore

struct OverviewTests {
    private func row(_ terminal: String, _ state: AgentState, on machine: String = "local", in directory: String? = nil,
                     stale: Bool = false) -> AgentRow {
        let agent = Agent(id: .init(machineID: machine, terminalID: terminal), name: "Claude Code", kind: "claude",
                          state: state, reportedState: state.rawValue, workspaceID: "w-\(terminal)", workspaceName: terminal,
                          tabID: "w1:t1", tabName: "1", paneID: "w1:p1", directory: directory, project: nil,
                          summary: nil, isLaunchPending: false)
        return AgentRow(agent: agent, machineName: machine, isStale: stale, lastSuccess: nil)
    }

    @Test func statesAndMachinesCombine() {
        let rows = [row("a", .blocked), row("b", .working), row("c", .working, on: "remote:forge"),
                    row("d", .idle, on: "remote:forge"), row("e", .working, on: "remote:mini", stale: true)]
        var filter = SessionFilter()
        #expect(rows.filter(filter.includes).count == 5)
        filter.toggle(.working)
        #expect(rows.filter(filter.includes).map(\.workspace) == ["b", "c"])
        filter.toggle(machine: "remote:forge")
        #expect(rows.filter(filter.includes).map(\.workspace) == ["c"])
        filter.toggle(.blocked)
        #expect(rows.filter(filter.includes).map(\.workspace) == ["c"])
        filter.toggle(.working)
        filter.toggle(.blocked)
        #expect(rows.filter(filter.includes).map(\.workspace) == ["c", "d"])
        // A machine that isn't answering shows its last known sessions, but not by state.
        filter = SessionFilter(machines: ["remote:mini"])
        #expect(rows.filter(filter.includes).map(\.workspace) == ["e"])
        filter.toggle(.working)
        #expect(rows.filter(filter.includes).isEmpty)
    }

    @Test func eachRowCountsWhatTheOtherRowChose() {
        let rows = [row("a", .blocked), row("b", .working), row("c", .working, on: "remote:forge"),
                    row("d", .idle, on: "remote:forge"), row("e", .working, on: "remote:mini", stale: true)]
        var filter = SessionFilter(states: [.working])
        #expect(filter.count(.working, in: rows) == 2)
        #expect(filter.count(.blocked, in: rows) == 1)
        #expect(filter.count(machine: "remote:forge", in: rows) == 1)
        #expect(filter.count(machine: "remote:mini", in: rows) == 0)
        filter = SessionFilter(machines: ["remote:forge"])
        #expect(filter.count(.working, in: rows) == 1)
        #expect(filter.count(.blocked, in: rows) == 0)
        #expect(filter.count(machine: "local", in: rows) == 2)
        #expect(filter.count(machine: "remote:mini", in: rows) == 1)
        filter.keep(machines: ["local"])
        #expect(filter.isEmpty)
    }

    @Test func foldersInUseComeMostUsedFirstWithoutWorktrees() {
        let rows = [row("a", .working, in: "/p/shepherdr"), row("b", .idle, in: "/p/herdr/"), row("c", .done, in: "/p/herdr"),
                    row("d", .working, in: "/p/shepherdr-wt"), row("e", .idle, in: "/p/api"), row("f", .idle, in: nil),
                    row("g", .idle, in: "relative")]
        let folders = FolderUse.ranked(rows, excluding: { $0.workspace == "d" })
        #expect(folders == [FolderUse(path: "/p/herdr", agents: 2), FolderUse(path: "/p/api", agents: 1),
                            FolderUse(path: "/p/shepherdr", agents: 1)])
        #expect(FolderUse.ranked(rows, limit: 1).map(\.path) == ["/p/herdr"])
        // Shells still without an agent add their folders after the agents' ones.
        let withShells = FolderUse.ranked(rows, shells: ["/p/api/", "/p/notes", "/p/notes", "/p/web", nil, "~"],
                                          excluding: { $0.workspace == "d" })
        #expect(withShells == [FolderUse(path: "/p/herdr", agents: 2), FolderUse(path: "/p/api", agents: 1, shells: 1),
                               FolderUse(path: "/p/shepherdr", agents: 1), FolderUse(path: "/p/notes", agents: 0, shells: 2),
                               FolderUse(path: "/p/web", agents: 0, shells: 1)])
    }

    @Test func usageIsReadFromTheScriptsLine() {
        #expect(MachineUsage.parse("motd\nshepherdr-usage 12 45 67\n") == MachineUsage(cpu: 12, memory: 45, disk: 67))
        #expect(MachineUsage.parse("shepherdr-usage 120 - 3") == MachineUsage(cpu: 100, memory: nil, disk: 3))
        #expect(MachineUsage.parse("shepherdr-usage - - -") == nil)
        #expect(MachineUsage.parse("sh: iostat: not found") == nil)
    }

    @Test func thisMacIsMeasuredDirectlyAndOthersOverSSH() async throws {
        let local = try #require(MachineUsage.command(for: .local))
        #expect(local.executable.path == "/bin/sh")
        let usage = try #require(await MachineUsage.read(.local))
        #expect(usage.cpu != nil && usage.memory != nil && usage.disk != nil)

        let remote = try #require(MachineUsage.command(for: Fixture.remote))
        #expect(remote.executable.path == "/usr/bin/ssh")
        #expect(remote.arguments.contains("BatchMode=yes") && remote.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(Array(remote.arguments.suffix(3).prefix(2)) == ["--", "builder"])
        let unsafe = Machine(profileID: "x", name: "x", target: "-oProxyCommand=evil", session: "default", isEnabled: true)
        #expect(MachineUsage.command(for: unsafe) == nil)
    }
}
