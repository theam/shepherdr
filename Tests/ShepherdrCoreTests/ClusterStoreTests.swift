import Testing
import Foundation
@testable import ShepherdrCore

@Suite @MainActor struct ClusterStoreTests {
    @Test func testMultipleMachinesAggregateAndSortAttentionFirst() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
        let store = ClusterStore(client: client)
        await store.refresh()
        #expect(store.machines.count == 2)
        #expect(store.onlineCount == 2)
        #expect(store.agents.count == 8)
        #expect(Set(store.agents.map(\.id)).count == 8)
        #expect(store.agents.prefix(2).map(\.agent.state) == [.blocked, .blocked])
        #expect(store.agents.contains { $0.matches("build studio") })
        #expect(store.agents.contains { $0.matches("packages/api") })
    }

    @Test func testPartialFailurePreservesDataAndRecoveryReplacesIt() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
        let store = ClusterStore(client: client)
        await store.refresh()
        let lastSuccess = store.lastSuccess[Fixture.remote.id]
        await client.set(Fixture.remote, .failure(HerdrFailure(.unreachable, "SSH timeout")))
        await store.refresh()
        #expect(store.onlineCount == 1)
        #expect(store.agents.count == 8)
        #expect(store.agents.filter(\.isStale).count == 4)
        #expect(lastSuccess != nil)
        #expect(store.lastSuccess[Fixture.remote.id] == lastSuccess)
        #expect(store.machines[1].failure?.message == "SSH timeout")
        await client.set(Fixture.remote, .success(MachineSnapshot(version: "test", protocolVersion: 22, workspaces: [], agents: [])))
        await store.refresh()
        #expect(store.onlineCount == 2)
        #expect(store.agents.count == 4)
        #expect(!(store.machines[1].isStale))
        #expect(store.machines[1].failure == nil)
    }

    @Test func testOneUnreachableMachineDoesNotPreventFirstLoad() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .failure(HerdrFailure(.unreachable, "Offline")))
        let store = ClusterStore(client: client)
        await store.refresh()
        #expect(store.agents.count == 4)
        #expect(store.machines[1].connection == .unreachable)
        #expect(!(store.machines[1].isStale))
    }

    @Test func testHealthyMachinePublishesBeforeSlowRemoteCompletes() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)), delay: .seconds(2))
        let store = ClusterStore(client: client)
        let refresh = Task { await store.refresh() }
        for _ in 0..<100 {
            if store.machines.count == 2 && store.onlineCount == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.onlineCount == 1)
        #expect(store.agents.count == 4)
        #expect(store.isRefreshing)
        refresh.cancel()
        await refresh.value
        #expect(!(store.isRefreshing))
    }

    @Test func testCatalogFailureKeepsKnownMachinesAndRefreshesThem() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
        let store = ClusterStore(client: client)
        await store.refresh()
        await client.setCatalog(.failure(HerdrFailure(.incompatible, "Invalid catalog")))
        await store.refresh()
        #expect(store.machines.count == 2)
        #expect(store.onlineCount == 2)
        #expect(store.discoveryFailure != nil)
        let calls = await client.callCount()
        #expect(calls == 4)
    }

    @Test func testDisabledProfilesAreVisibleButNeverQueriedAndRemovedProfilesDisappear() async throws {
        let disabled = Machine(profileID: "disabled", name: "Lab", target: "lab", session: "default", isEnabled: false)
        let client = MockHerdrClient()
        await client.setCatalog(.success([disabled]))
        let store = ClusterStore(client: client)
        await store.refresh()
        #expect(store.machines[1].connection == .disabled)
        let count = await client.callCount()
        #expect(count == 1)
        await client.setCatalog(.success([]))
        await store.refresh()
        #expect(store.machines.count == 1)
    }

    @Test func testOverlappingRefreshesAreCoalesced() async throws {
        let client = MockHerdrClient()
        await client.set(.local, .success(try Fixture.snapshot()), delay: .milliseconds(150))
        let store = ClusterStore(client: client)
        async let first: Void = store.refresh()
        async let second: Void = store.refresh()
        _ = await (first, second)
        let count = await client.callCount()
        #expect(count == 1)
    }

    @Test func aChangeShowsWithoutWaitingForASlowRemote() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
        let store = ClusterStore(client: client)
        await store.refresh()
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)), delay: .seconds(5))
        let slow = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.isRefreshing)
        let started = ContinuousClock.now
        try await store.closeSession(paneID: "w1:p1", onMachine: "local")
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await client.snapshotCalls().suffix(1) == ["local"])
        slow.cancel()
        await slow.value
    }

    @Test func anAnswerAskedBeforeAChangeNeverReplacesIt() async throws {
        let client = MockHerdrClient()
        let before = try Fixture.snapshot()
        await client.set(.local, .success(before))
        let store = ClusterStore(client: client)
        await store.refresh()
        // A refresh asks while the pane is still there, and answers after the change.
        await client.set(.local, .success(before), delay: .milliseconds(400))
        let late = Task { await store.refresh() }
        try await Task.sleep(for: .milliseconds(50))
        let after = before.closing(paneID: "w1:p1")
        await client.set(.local, .success(after))
        try await store.closeSession(paneID: "w1:p1", onMachine: "local")
        #expect(!store.agents.contains { $0.agent.paneID == "w1:p1" })
        await late.value
        #expect(!store.agents.contains { $0.agent.paneID == "w1:p1" })
        #expect(store.machines[0].snapshot == after)
    }

    @Test func aClosedPaneLeavesBeforeItsMachineAnswers() async throws {
        let client = MockHerdrClient()
        await client.setCatalog(.success([Fixture.remote]))
        await client.set(.local, .success(try Fixture.snapshot()))
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
        let store = ClusterStore(client: client)
        await store.refresh()
        await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)), delay: .seconds(5))
        let close = Task { try await store.closeSession(paneID: "w1:p1", onMachine: Fixture.remote.id) }
        for _ in 0..<100 where store.agents.contains(where: { $0.id.machineID == Fixture.remote.id && $0.agent.paneID == "w1:p1" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.agents.filter { $0.id.machineID == Fixture.remote.id }.count == 3)
        close.cancel()
        _ = try? await close.value
    }

    @Test func aPaneThatEndedOnItsOwnLeavesWithoutClosingAnything() async throws {
        let client = MockHerdrClient()
        let before = try Fixture.snapshot()
        await client.set(.local, .success(before))
        let store = ClusterStore(client: client)
        await store.refresh()
        await client.set(.local, .success(before.closing(paneID: "w1:p1")), delay: .milliseconds(300))
        let ended = Task { await store.paneClosed("w1:p1", onMachine: "local") }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!store.agents.contains { $0.agent.paneID == "w1:p1" })
        await ended.value
        #expect(await client.recordedChanges().isEmpty)
        #expect(await client.snapshotCalls().suffix(1) == ["local"])
    }

    @Test func testMissingHerdrProducesUsefulState() async {
        let client = MockHerdrClient()
        let failure = HerdrFailure(.notInstalled, "Install Herdr, then refresh.")
        await client.setCatalog(.failure(failure))
        await client.set(.local, .failure(failure))
        let store = ClusterStore(client: client)
        await store.refresh()
        #expect(store.machines[0].connection == .notInstalled)
        #expect(store.machines[0].failure?.message == failure.message)
        #expect(store.agents.isEmpty)
    }

    @Test func testCreatedSessionsAppearAfterTheChangeAndLocalCannotBeRemoved() async throws {
        let client = MockHerdrClient()
        await client.set(.local, .success(.init(version: "test", protocolVersion: 22, workspaces: [], agents: [])))
        await client.setAfterCreate(try Fixture.snapshot())
        let store = ClusterStore(client: client)
        await store.refresh()
        #expect(store.agents.isEmpty)
        let created = try await store.createSession(.init(directory: "/tmp/x", name: "x", agentKind: "claude"), onMachine: "local")
        #expect(created.terminalID == "term-new")
        #expect(!store.agents.isEmpty)
        try await store.closeSession(paneID: "w1:p1", onMachine: "local")
        #expect(await client.recordedChanges() == ["create local x", "close local w1:p1"])
        await #expect(throws: HerdrFailure.self) { try await store.removeMachine("local") }
        await #expect(throws: HerdrFailure.self) { try await store.closeSession(paneID: "p", onMachine: "remote:missing") }
    }
}
