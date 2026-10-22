import Foundation
import Testing
@testable import ShepherdrCore

@Suite @MainActor struct SessionOrderTests {
    private let a = Agent.ID(machineID: "local", terminalID: "a")
    private let b = Agent.ID(machineID: "local", terminalID: "b")
    private let c = Agent.ID(machineID: "remote:one", terminalID: "a")
    private let d = Agent.ID(machineID: "remote:one", terminalID: "b")

    private func withDefaults(_ body: @MainActor (UserDefaults) async throws -> Void) async throws {
        let suite = "ShepherdrTests.SessionOrder.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await body(defaults)
    }

    @Test func prioritiesSurviveRelaunchAndDistinguishMachines() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c, d])
            order.move(c, .first, visibleIDs: [a, b, c, d])
            #expect(order.orderedIDs == [c, a, b, d])
            let reopened = SessionOrderStore(defaults: defaults)
            #expect(reopened.orderedIDs == [c, a, b, d])
            let data = try #require(defaults.data(forKey: SessionOrderStore.storageKey))
            let records = try #require(JSONSerialization.jsonObject(with: data) as? [[String: [String: String]]])
            #expect(records.allSatisfy { Set($0.keys) == ["session"] && Set($0["session"]!.keys) == ["machineID", "terminalID"] })
        }
    }

    @Test func discoveriesAppendWithoutLosingMissingSessionsOrFollowingRefreshOrder() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c])
            order.move(c, .first, visibleIDs: [a, b, c])
            order.synchronize(with: []) // Refresh starts before any machine has replied.
            order.synchronize(with: [b, a]) // Missing remote, different state/name sorting.
            let reopened = SessionOrderStore(defaults: defaults)
            reopened.synchronize(with: [d, c, b, a, d])
            #expect(reopened.orderedIDs == [c, a, b, d])
        }
    }

    @Test func filteredMovesPreserveHiddenSlotsAndBoundaries() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c, d])
            // b is hidden by a search or machine filter. Its slot must not change.
            order.move(d, .first, visibleIDs: [a, c, d])
            #expect(order.orderedIDs == [d, b, a, c])
            order.move(d, .down, visibleIDs: [d, a, c])
            #expect(order.orderedIDs == [a, b, d, c])
            order.move(d, .up, visibleIDs: [a, d, c])
            order.move(d, .last, visibleIDs: [d, a, c])
            #expect(order.orderedIDs == [a, b, c, d])
            #expect(!order.canMove(a, .up, visibleIDs: [a, c, d]))
            #expect(!order.canMove(d, .down, visibleIDs: [a, c, d]))
            #expect(!order.canMove(b, .first, visibleIDs: [a, c, d]))
            #expect(!order.canMove(nil, .up, visibleIDs: []))
            order.move(b, .first, visibleIDs: [a, c, d])
            #expect(order.orderedIDs == [a, b, c, d])
        }
    }

    @Test func droppingPlacesSessionsBeforeAfterAndAtTheEnd() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c, d])
            order.place(.session(d), .before(.session(a)))
            #expect(order.orderedIDs == [d, a, b, c])
            order.place(.session(d), .after(.session(b)))
            #expect(order.orderedIDs == [a, b, d, c])
            order.place(.session(a), .end)
            #expect(order.orderedIDs == [b, d, c, a])
            // Dropping an item onto itself, or naming unknown items, changes nothing.
            let gone = Agent.ID(machineID: "gone", terminalID: "x")
            order.place(.session(b), .before(.session(b)))
            order.place(.session(gone), .before(.session(b)))
            order.place(.session(b), .before(.session(gone)))
            #expect(SessionOrderStore(defaults: defaults).orderedIDs == [b, d, c, a])
        }
    }

    @Test func groupsHoldSessionsWithTheirOwnOrderAndMoveAsOne() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c, d])
            let all: [Agent.ID] = [a, b, c, d]
            // A new group takes its first session's place.
            let work = order.createGroup(named: "Work", with: c)
            #expect(order.entries.map(\.id) == [.session(a), .session(b), .group(work), .session(d)])
            order.place(.session(a), .into(group: work))
            #expect(order.groups.first?.members == [c, a])
            #expect(order.orderedIDs == [b, c, a, d])

            // Inside a group, sessions move among its members only.
            #expect(!order.canMove(c, .up, visibleIDs: all))
            order.move(a, .first, visibleIDs: all)
            #expect(order.groups.first?.members == [a, c])
            // The group moves as a single position, like a session.
            order.move(.group(work), .first, visible: order.visibleItems(all))
            #expect(order.orderedIDs == [a, c, b, d])
            order.move(b, .first, visibleIDs: all)
            #expect(order.entries.map(\.id) == [.session(b), .group(work), .session(d)])

            order.setCollapsed(work, true)
            order.renameGroup(work, to: "Client work")
            let reopened = SessionOrderStore(defaults: defaults)
            #expect(reopened.groups == [SessionGroup(id: work, name: "Client work", isCollapsed: true, members: [a, c])])
            #expect(reopened.orderedIDs == [b, a, c, d])

            // Ungrouping leaves the sessions where the group was, in the group's order.
            reopened.ungroup(work)
            #expect(reopened.groups.isEmpty)
            #expect(reopened.entries == [.session(b), .session(a), .session(c), .session(d)])
        }
    }

    @Test func layoutNumbersSessionsAcrossGroupsAndKeepsEmptyGroups() async throws {
        try await withDefaults { defaults in
            let client = MockHerdrClient()
            await client.set(.local, .success(try Fixture.snapshot()))
            let cluster = ClusterStore(client: client)
            await cluster.refresh()
            let ids = cluster.agents.map(\.id)
            try #require(ids.count >= 3)
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: ids)
            let group = order.createGroup(named: "Grouped", with: ids[2])
            let empty = order.createGroup(named: "Empty")
            let items = order.layout(cluster.agents)
            #expect(items.first?.id == .group(empty))
            #expect(items.first?.rows.isEmpty == true)
            #expect(order.ranked(cluster.agents).map(\.manualPriority) == Array(1...ids.count))
            let grouped = try #require(items.first { $0.id == .group(group) })
            #expect(grouped.rows.map(\.id) == [ids[2]])
            #expect(grouped.rows.first?.groupID == group)
            #expect(order.ranked(cluster.agents).first { $0.id == ids[0] }?.groupID == nil)
        }
    }

    @Test func droppingRespectsGroupBoundaries() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c, d])
            let first = order.createGroup(named: "First", with: a)
            let second = order.createGroup(named: "Second", with: c)
            order.moveToGroup(b, first)
            #expect(order.groups.map(\.members) == [[a, b], [c]])
            // Dropping a session next to a grouped session joins that group at that spot.
            order.place(.session(d), .before(.session(b)))
            #expect(order.groups.map(\.members) == [[a, d, b], [c]])
            // Groups never nest: dropped on a group or among its sessions, a group lands beside it.
            order.place(.group(second), .into(group: first))
            #expect(order.entries.map(\.id) == [.group(first), .group(second)])
            order.place(.group(second), .before(.session(a)))
            #expect(order.entries.map(\.id) == [.group(second), .group(first)])
            // A group cannot be dropped among its own sessions.
            order.place(.group(second), .after(.session(c)))
            #expect(order.entries.map(\.id) == [.group(second), .group(first)])
            // Removing a session from its group places it right after the group.
            order.moveToGroup(c, nil)
            #expect(order.entries.map(\.id) == [.group(second), .session(c), .group(first)])
            order.place(.session(d), .end)
            #expect(order.entries.map(\.id) == [.group(second), .session(c), .group(first), .session(d)])
        }
    }

    @Test func newSessionsTakeTheirSpotBeforeHerdrReportsThem() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b])
            let group = order.createGroup(named: "Work", with: b)
            // A shell created in a group, or next to a session, waits there for its agent.
            order.insert(c, .into(group: group))
            order.insert(d, .after(.session(a)))
            #expect(order.entries.map(\.id) == [.session(a), .session(d), .group(group)])
            #expect(order.groups.first?.members == [b, c])
            // Once Herdr reports them, discovery leaves them where they are.
            order.synchronize(with: [d, c, b, a])
            #expect(SessionOrderStore(defaults: defaults).orderedIDs == [a, d, b, c])
            // An unknown target leaves the new session at the end.
            let e = Agent.ID(machineID: "local", terminalID: "e")
            order.insert(e, .after(.session(Agent.ID(machineID: "gone", terminalID: "x"))))
            #expect(order.orderedIDs == [a, d, b, c, e])
        }
    }

    @Test func filteredMovesInsideGroupsPreserveHiddenSlots() async throws {
        try await withDefaults { defaults in
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: [a, b, c, d])
            let group = order.createGroup(named: "All", with: a)
            for id in [b, c, d] { order.moveToGroup(id, group) }
            // b is hidden by a filter; moving d to the top keeps b in its slot.
            order.move(d, .first, visibleIDs: [a, c, d])
            #expect(order.groups.first?.members == [d, b, a, c])
            #expect(!order.canMove(b, .up, visibleIDs: [a, c, d]))
        }
    }

    @Test func ordersSavedByEarlierVersionsAreMigrated() async throws {
        try await withDefaults { defaults in
            defaults.set(try JSONEncoder().encode([c, a, b]), forKey: SessionOrderStore.legacyStorageKey)
            let migrated = SessionOrderStore(defaults: defaults)
            #expect(migrated.orderedIDs == [c, a, b])
            migrated.synchronize(with: [d])
            #expect(SessionOrderStore(defaults: defaults).orderedIDs == [c, a, b, d])
        }
    }

    @Test func invalidPreferencesRecoverAndDuplicateIdentifiersAreNormalized() async throws {
        try await withDefaults { defaults in
            defaults.set(Data("not JSON".utf8), forKey: SessionOrderStore.storageKey)
            let recovered = SessionOrderStore(defaults: defaults)
            #expect(recovered.orderedIDs.isEmpty)
            recovered.synchronize(with: [a, a, b])
            #expect(SessionOrderStore(defaults: defaults).orderedIDs == [a, b])
            let malformed = [a, a, Agent.ID(machineID: "", terminalID: ""), b]
            defaults.removeObject(forKey: SessionOrderStore.storageKey)
            defaults.set(try JSONEncoder().encode(malformed), forKey: SessionOrderStore.legacyStorageKey)
            #expect(SessionOrderStore(defaults: defaults).orderedIDs == [a, b])
        }
    }

    @Test func clusterRefreshFailureAndRecoveryKeepManualRanking() async throws {
        try await withDefaults { defaults in
            let client = MockHerdrClient()
            await client.setCatalog(.success([Fixture.remote]))
            await client.set(.local, .success(try Fixture.snapshot()))
            await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
            let cluster = ClusterStore(client: client)
            await cluster.refresh()
            let order = SessionOrderStore(defaults: defaults)
            order.synchronize(with: cluster.agents.map(\.id))
            let promoted = try #require(cluster.agents.last { $0.id.machineID == Fixture.remote.id })
            order.move(promoted.id, .first, visibleIDs: cluster.agents.map(\.id))
            let expected = order.ranked(cluster.agents).map(\.id)

            await client.set(Fixture.remote, .failure(HerdrFailure(.unreachable, "Offline")))
            await cluster.refresh()
            order.synchronize(with: cluster.agents.map(\.id))
            #expect(order.ranked(cluster.agents).map(\.id) == expected)
            #expect(order.ranked(cluster.agents).first?.isStale == true)

            // A successful empty response removes rows, but not their saved positions.
            await client.set(Fixture.remote, .success(.init(version: "test", protocolVersion: 22, workspaces: [], agents: [])))
            await cluster.refresh()
            order.synchronize(with: cluster.agents.map(\.id))
            #expect(order.ranked(cluster.agents).map(\.manualPriority) == [1, 2, 3, 4])
            await client.set(Fixture.remote, .success(try Fixture.snapshot(machine: Fixture.remote)))
            await cluster.refresh()
            let reopened = SessionOrderStore(defaults: defaults)
            reopened.synchronize(with: cluster.agents.map(\.id))
            #expect(reopened.ranked(cluster.agents).map(\.id) == expected)
            #expect(reopened.ranked(cluster.agents).map(\.manualPriority) == Array(1...8))
        }
    }
}

@Suite @MainActor struct SessionRelationTests {
    private let planner = Agent.ID(machineID: "local", terminalID: "planner")
    private let research = Agent.ID(machineID: "local", terminalID: "research")
    private let tests = Agent.ID(machineID: "remote:one", terminalID: "tests")

    private func withDefaults(_ body: @MainActor (UserDefaults) throws -> Void) throws {
        let suite = "ShepherdrTests.SessionRelations.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test func sessionsWaitForOthersAndRememberIt() throws {
        try withDefaults { defaults in
            let relations = SessionRelationStore(defaults: defaults)
            relations.setWaiting(planner, for: research, true)
            relations.setWaiting(planner, for: tests, true)
            relations.setWaiting(planner, for: research, true) // Already waiting: no duplicate.
            relations.setWaiting(planner, for: planner, true) // A session cannot wait for itself.
            #expect(relations.waitingFor(planner) == [research, tests])
            #expect(relations.waiters(of: tests) == [planner])
            #expect(relations.isWaiting(planner, for: tests))
            #expect(!relations.isWaiting(research, for: planner))

            let reopened = SessionRelationStore(defaults: defaults)
            #expect(reopened.waitingFor(planner) == [research, tests])
            reopened.setWaiting(planner, for: research, false)
            #expect(reopened.waitingFor(planner) == [tests])
            reopened.stopWaiting(planner)
            #expect(reopened.waits.isEmpty)
            #expect(SessionRelationStore(defaults: defaults).waits.isEmpty)
        }
    }

    @Test func closingASessionForgetsItsRelations() throws {
        try withDefaults { defaults in
            let relations = SessionRelationStore(defaults: defaults)
            relations.setWaiting(planner, for: research, true)
            relations.setWaiting(tests, for: research, true)
            relations.setWaiting(tests, for: planner, true)
            relations.forget(research)
            #expect(relations.waits == [tests: [planner]])
            relations.forget(tests)
            #expect(SessionRelationStore(defaults: defaults).waits.isEmpty)
        }
    }

    @Test func awaitedSessionsNestUnderTheFirstSessionWaitingForThem() throws {
        try withDefaults { defaults in
            let relations = SessionRelationStore(defaults: defaults)
            let review = Agent.ID(machineID: "local", terminalID: "review")
            relations.setWaiting(planner, for: research, true)
            relations.setWaiting(planner, for: tests, true)
            relations.setWaiting(review, for: tests, true) // Already nested under the planner, listed first.
            relations.setWaiting(research, for: review, true) // Nests one level deeper.
            #expect(relations.parents(in: [planner, research, tests, review])
                    == [research: planner, tests: planner, review: research])
            // Only listed sessions nest: the planner hidden by a filter leaves its sessions in place.
            #expect(relations.parents(in: [research, tests, review]) == [review: research, tests: review])
            // A loop keeps the session listed first at the top.
            relations.setWaiting(research, for: planner, true)
            #expect(relations.parents(in: [planner, research])[planner] == nil)
            #expect(relations.parents(in: [research, planner]) == [planner: research])
        }
    }

    @Test func collapsedWaitsAreRememberedUntilTheWaitEnds() throws {
        try withDefaults { defaults in
            let relations = SessionRelationStore(defaults: defaults)
            relations.setCollapsed(planner, true) // Not waiting yet: nothing to collapse.
            #expect(relations.collapsed.isEmpty)
            relations.setWaiting(planner, for: research, true)
            relations.setWaiting(tests, for: research, true)
            relations.setCollapsed(planner, true)
            relations.setCollapsed(tests, true)
            #expect(SessionRelationStore(defaults: defaults).collapsed == [planner, tests])
            relations.setWaiting(planner, for: research, false)
            relations.forget(research)
            #expect(relations.collapsed.isEmpty)
            #expect(SessionRelationStore(defaults: defaults).collapsed.isEmpty)
        }
    }

    @Test func phasesAreRememberedAndChangesWaitToReachHerdr() throws {
        try withDefaults { defaults in
            let relations = SessionRelationStore(defaults: defaults)
            relations.setWaiting(planner, for: research, true)
            relations.setWaiting(planner, for: tests, true)
            #expect(relations.isHeld(planner))
            #expect(relations.unsynced == [planner])
            relations.markSynced(planner)
            relations.setHolds([Hold(awaited: research, phase: .finished), Hold(awaited: tests, phase: .started)], for: planner)
            #expect(relations.phase(of: planner, for: research) == .finished)
            #expect(relations.isHeld(planner))
            #expect(relations.unsynced == [planner])
            // Waiting again keeps how far it got.
            relations.setWaiting(planner, for: research, true)
            #expect(relations.phase(of: planner, for: research) == .finished)

            let reopened = SessionRelationStore(defaults: defaults)
            #expect(reopened.holds[planner] == [Hold(awaited: research, phase: .finished), Hold(awaited: tests, phase: .started)])
            #expect(reopened.unsynced == [planner])
            reopened.setHolds([Hold(awaited: tests, phase: .finished)], for: planner)
            #expect(!reopened.isHeld(planner))
            reopened.markSynced(planner)
            // Holds read back from Herdr are already there.
            reopened.setHolds([Hold(awaited: planner)], for: research, fromHerdr: true)
            #expect(reopened.unsynced.isEmpty)
            // A closed session's own tokens went with it; its waiters' change.
            reopened.forget(planner)
            #expect(reopened.unsynced == [research])
            #expect(SessionRelationStore(defaults: defaults).unsynced == [research])
        }
    }

    @Test func holdsChangingTellTheirListener() throws {
        try withDefaults { defaults in
            let relations = SessionRelationStore(defaults: defaults)
            var changes = 0
            relations.onChange = { changes += 1 }
            relations.setWaiting(planner, for: research, true)
            relations.setWaiting(planner, for: research, true)
            relations.setCollapsed(planner, true)
            relations.markSynced(planner)
            #expect(changes == 1)
            relations.forget(research)
            #expect(changes == 2)
        }
    }

    @Test func invalidOrDuplicatedRecordsAreDropped() throws {
        try withDefaults { defaults in
            let json = """
            [{"session":{"machineID":"local","terminalID":"planner"},
              "waitingFor":[{"machineID":"local","terminalID":"research"},{"machineID":"local","terminalID":"research"},
                            {"machineID":"local","terminalID":"planner"},{"machineID":"","terminalID":""}]},
             {"session":{"machineID":"","terminalID":""},"waitingFor":[{"machineID":"local","terminalID":"research"}]}]
            """
            defaults.set(Data(json.utf8), forKey: SessionRelationStore.storageKey)
            #expect(SessionRelationStore(defaults: defaults).waits == [planner: [research]])
            // Saved before phases: already waited for, so a session that is free now has finished.
            #expect(SessionRelationStore(defaults: defaults).holds[planner] == [Hold(awaited: research, phase: .started)])
            defaults.set(Data("not JSON".utf8), forKey: SessionRelationStore.storageKey)
            #expect(SessionRelationStore(defaults: defaults).waits.isEmpty)
        }
    }
}
