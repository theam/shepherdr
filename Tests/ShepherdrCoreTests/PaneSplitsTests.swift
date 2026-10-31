import Foundation
import Testing
@testable import ShepherdrCore

struct PaneSplitsTests {
    /// The fixture, with Docs' writer and its shell side by side, and Orchard's two agents stacked
    /// in an area Herdr starts at a column and row of its own.
    private func splitSnapshot(layouts: String? = nil) throws -> MachineSnapshot {
        let layouts = layouts ?? """
        [{"tab_id":"w2:t1","workspace_id":"w2","zoomed":false,"area":{"x":0,"y":0,"width":120,"height":40},
          "panes":[{"pane_id":"w2:p1","focused":true,"rect":{"x":0,"y":0,"width":80,"height":40}},
                   {"pane_id":"w2:p2","focused":false,"rect":{"x":80,"y":0,"width":40,"height":40}}],
          "splits":[{"id":"split_0_root","direction":"right","ratio":0.66,"rect":{"x":0,"y":0,"width":120,"height":40}}]},
         {"tab_id":"w1:t1","workspace_id":"w1","area":{"x":2,"y":1,"width":100,"height":50},
          "panes":[{"pane_id":"w1:p1","rect":{"x":2,"y":1,"width":100,"height":25}},
                   {"pane_id":"w1:p2","rect":{"x":2,"y":26,"width":100,"height":25}}]}]
        """
        let json = String(decoding: try Fixture.data(), as: UTF8.self).replacingOccurrences(of: #""layouts": []"#, with: #""layouts": \#(layouts)"#)
        return try HerdrJSON.snapshot(Data(json.utf8), machine: .local)
    }

    @Test func eachTabsPanesTakeTheirPartOfIt() throws {
        let snapshot = try splitSnapshot()
        let docs = try #require(snapshot.split(of: "term-d"))
        #expect(docs.map(\.terminalID) == ["term-d", "term-shell"])
        #expect(docs[0].frame == CGRect(x: 0, y: 0, width: 80.0 / 120, height: 1))
        #expect(docs[1].frame == CGRect(x: 80.0 / 120, y: 0, width: 40.0 / 120, height: 1))
        // Either pane of a tab shows the same split.
        #expect(snapshot.split(of: "term-shell") == docs)
        let orchard = try #require(snapshot.split(of: "term-b"))
        #expect(orchard.map(\.frame) == [CGRect(x: 0, y: 0, width: 1, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)])
        // A tab with one pane, or with no layout, isn't split.
        #expect(snapshot.split(of: "term-c") == nil)
        #expect(try Fixture.snapshot().split(of: "term-d") == nil)
    }

    @Test func aShellBesideAnAgentShowsInItsSession() throws {
        let snapshot = try splitSnapshot()
        #expect(snapshot.showsInside(shell: "term-shell"))
        #expect(try !Fixture.snapshot().showsInside(shell: "term-shell"))
    }

    @Test func aTabOfShellsShowsAsItsFirstShell() {
        func pane(_ terminal: String, _ pane: String) -> TerminalPane {
            TerminalPane(terminalID: terminal, paneID: pane, workspaceID: "w1", tabID: "w1:t1", workspaceName: "scratch",
                         title: pane, directory: nil)
        }
        let layout = TabLayout(tabID: "w1:t1", panes: [
            .init(paneID: "w1:p2", frame: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
            .init(paneID: "w1:p1", frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ])
        let snapshot = MachineSnapshot(version: "0.9.3", protocolVersion: 22, workspaces: [], agents: [],
                                       panes: [pane("term-1", "w1:p1"), pane("term-2", "w1:p2")], layouts: ["w1:t1": layout])
        // The first in Herdr's layout stands for the tab, whatever its pane number.
        #expect(!snapshot.showsInside(shell: "term-2"))
        #expect(snapshot.showsInside(shell: "term-1"))
    }

    @Test func aLayoutShepherdrCantReadLeavesTheRestOfTheSnapshot() throws {
        let snapshot = try splitSnapshot(layouts: #"[{"tab_id":"w2:t1","area":"everywhere"}, {"panes":[]}]"#)
        #expect(snapshot.agents.count == 4)
        #expect(snapshot.layouts.isEmpty)
        #expect(snapshot.split(of: "term-d") == nil)
    }

    @Test func aClosedPaneLeavesItsTab() throws {
        let snapshot = try splitSnapshot()
        let shellGone = snapshot.closing(paneID: "w2:p2")
        #expect(shellGone.split(of: "term-d") == nil)
        #expect(shellGone.panes.count == 4 && shellGone.agents.count == 4)
        let writerGone = snapshot.closing(paneID: "w2:p1")
        #expect(writerGone.agents.map(\.id.terminalID).sorted() == ["term-a", "term-b", "term-c"])
        #expect(!writerGone.showsInside(shell: "term-shell"))
        #expect(writerGone.layouts["w1:t1"] == snapshot.layouts["w1:t1"])
    }

    @Test func splittingAPaneAsksHerdrForAShellBesideOrUnderIt() async throws {
        let answer = output(#"{"id":"cli:pane:split","result":{"type":"pane_info","pane":{"pane_id":"w2:p3","terminal_id":"term-new","tab_id":"w2:t1","workspace_id":"w2"}}}"#)
        let runner = RecordingRunner([answer, answer])
        let client = CLIHerdrClient(runner: runner, executable: URL(fileURLWithPath: "/test/herdr"))
        #expect(try await client.splitPane("w2:p1", .right, directory: "/srv/docs", on: Fixture.remote) == "term-new")
        #expect(try await client.splitPane("w2:p1", .down, directory: nil, on: .local) == "term-new")
        #expect(await runner.recordedArguments() == [
            ["--machine", "remote-1", "pane", "split", "w2:p1", "--direction", "right", "--cwd", "/srv/docs", "--no-focus"],
            ["pane", "split", "w2:p1", "--direction", "down", "--no-focus"],
        ])
        await #expect(throws: HerdrFailure.self) { _ = try await client.splitPane("--all", .right, directory: nil, on: .local) }
        await #expect(throws: HerdrFailure.self) { _ = try await client.splitPane("w2:p1", .right, directory: "-x", on: .local) }
        #expect(await runner.recordedArguments().count == 2)
    }
}
