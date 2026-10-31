import Foundation
import Testing
@testable import ShepherdrCore

struct TerminalTests {
    let target = TerminalTarget(machine: .local, terminalID: "term-a", title: "Reviewer", workspace: "Orchard")

    @Test func testFramesAndBinaryInputUseStructuredJSON() throws {
        let frame = try TerminalJSON.event(Data(#"{"type":"terminal.frame","seq":4,"encoding":"ansi","width":80,"height":24,"full":true,"bytes":"G1sySkhlbGxv","future":true}"#.utf8))
        #expect(frame == .frame(.init(bytes: Data("\u{1b}[2JHello".utf8), columns: 80, rows: 24, isFull: true)))
        #expect(try TerminalJSON.event(Data(#"{"type":"terminal.closed","reason":"Already controlled"}"#.utf8)) == .closed("Already controlled"))
        #expect(try TerminalJSON.event(Data(#"{"type":"future.event"}"#.utf8)) == nil)
        #expect(throws: (any Error).self) {
            try TerminalJSON.event(Data(#"{"type":"terminal.frame","encoding":"ansi","width":80,"height":24,"full":true,"bytes":"??"}"#.utf8))
        }
        let input = Data([3, 27, 91, 65, 0, 255])
        let command = try TerminalJSON.command(.bytes(input))
        let json = try #require(JSONSerialization.jsonObject(with: command) as? [String: String])
        #expect(json["type"] == "terminal.input")
        #expect(Data(base64Encoded: try #require(json["bytes"])) == input)
        #expect(command.last == 10)
    }

    @Test func testLocalTargetClearsInheritedRoutingAndNeverTakesOver() throws {
        let command = try TerminalCommand.make(target: target, mode: .control, size: .init(columns: 90, rows: 32),
                                              executable: URL(fileURLWithPath: "/usr/bin/true"),
                                              environment: ["HERDR_SESSION": "wrong", "HERDR_SOCKET_PATH": "/wrong.sock", "HERDR_PANE_ID": "wrong", "PATH": "/usr/bin"])
        #expect(command.arguments == ["--session", "default", "terminal", "session", "control", "term-a", "--cols", "90", "--rows", "32"])
        #expect(command.environment["HERDR_SOCKET_PATH"] == nil)
        #expect(command.environment["HERDR_SESSION"] == nil)
        #expect(command.environment["HERDR_PANE_ID"] == nil)
        #expect(command.environment["SSH_ASKPASS_REQUIRE"] == "never")
    }

    @Test func testTakeoverIsAnExplicitControlFlag() throws {
        let command = try TerminalCommand.make(target: target, mode: .takeover, size: .init(columns: 90, rows: 32),
                                              executable: URL(fileURLWithPath: "/usr/bin/true"), environment: [:])
        #expect(command.arguments == ["--session", "default", "terminal", "session", "control", "term-a",
                                      "--cols", "90", "--rows", "32", "--takeover"])
        #expect(TerminalMode.takeover.acceptsInput && TerminalMode.control.acceptsInput && !TerminalMode.observe.acceptsInput)
    }

    @Test func testPromptsArePastedSafelyAndSubmittedSeparately() {
        #expect(TerminalPrompt.body("  \n ") == nil)
        #expect(TerminalPrompt.body("run the tests") == Data("run the tests".utf8))
        #expect(TerminalPrompt.body("first\r\nsecond\u{1b}[201~") == Data("\u{1b}[200~first\nsecond[201~\u{1b}[201~".utf8))
        #expect(TerminalPrompt.submit == Data([13]))
        #expect(TerminalKey.escape.bytes == Data([27]))
        #expect(TerminalKey.interrupt.bytes == Data([3]))
    }

    @Test func testRemoteCommandQuotesSessionAndTerminalLiterally() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("herdr")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let literal = "work' ; $(echo INJECTED) `echo DANGER`"
        let machine = Machine(profileID: "profile", name: "Remote", target: "user@builder", session: literal, isEnabled: true)
        let remote = TerminalTarget(machine: machine, terminalID: literal, title: "Agent", workspace: "Project")
        let command = try TerminalCommand.make(target: remote, mode: .observe, size: .init(), executable: nil)
        #expect(command.executable.path == "/usr/bin/ssh")
        #expect(command.arguments.contains("BatchMode=yes"))
        #expect(command.arguments.contains("StrictHostKeyChecking=yes"))
        #expect(command.arguments.contains("user@builder"))
        let script = "PATH=\(TerminalCommand.quote(directory.path + ":/usr/bin:/bin")); export PATH; " + (try #require(command.arguments.last))
        let output = try await ProcessRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 3)
        #expect(output.exitCode == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self).components(separatedBy: "\n").prefix(6)
                == ["--session", literal, "terminal", "session", "observe", literal][...])
    }

    @Test func testInvalidTargetsAndStableWindowIdentity() throws {
        let invalid = Machine(profileID: "p", name: "Bad", target: "-oProxyCommand=bad", session: "default", isEnabled: true)
        #expect(throws: HerdrFailure.self) {
            try TerminalCommand.make(target: .init(machine: invalid, terminalID: "a", title: "", workspace: ""), mode: .control, size: .init(), executable: nil)
        }
        let renamed = TerminalTarget(machine: .local, terminalID: "term-a", title: "New name", workspace: "New name")
        let remote = TerminalTarget(machine: Fixture.remote, terminalID: "term-a", title: "Reviewer", workspace: "Orchard")
        #expect(target == renamed)
        #expect(Set([target, renamed, remote]).count == 2)
        let snapshot = try Fixture.snapshot()
        #expect(snapshot.panes.count == 5)
        #expect(snapshot.panes.first { $0.terminalID == "term-shell" }?.directory == "/srv/docs")
    }

    @Test func testRealJSONStreamRoundTripAndDisconnect() async throws {
        let script = """
        printf '%s\\n' '{"type":"terminal.frame","encoding":"ansi","width":80,"height":24,"full":true,"bytes":"cmVhZHk="}'
        while IFS= read -r line; do
          printf '%s\\n' '{"type":"terminal.frame","encoding":"ansi","width":80,"height":24,"full":false,"bytes":"cmVjZWl2ZWQ="}'
        done
        """
        let command = TerminalCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: [:])
        let connection = try await CLITerminalConnection.start(command: command, mode: .control, startupTimeout: 2)
        defer { connection.close() }
        var events = connection.events.makeAsyncIterator()
        #expect(try await events.next() == .frame(.init(bytes: Data("ready".utf8), columns: 80, rows: 24, isFull: true)))
        try await connection.send(.bytes(Data("hello\r".utf8)))
        #expect(try await events.next() == .frame(.init(bytes: Data("received".utf8), columns: 80, rows: 24, isFull: false)))
        connection.close()
        #expect(try await events.next() == nil)
        await #expect(throws: HerdrFailure.self) { try await connection.send(.bytes(Data([3]))) }
    }

    @Test func cancellingAConnectionAsItStartsNeverWaits() async throws {
        // Cancelling runs the handler while the task's lock is held. A handler that waited for the
        // connection's queue, while that queue resumed the same task, hung the app for good.
        let command = TerminalCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec /bin/sleep 1"], environment: [:])
        let done = Flag()
        DispatchQueue.global().async {
            for attempt in 0..<200 {
                let task = Task.detached { try? await CLITerminalConnection.start(command: command, mode: .observe, startupTimeout: 0.2).close() }
                usleep(UInt32(attempt % 20) * 100)
                task.cancel()
            }
            done.set()
        }
        for _ in 0..<200 where !done.isSet { try await Task.sleep(for: .milliseconds(100)) }
        #expect(done.isSet, "Cancelling a starting connection waited for it")
    }

    @Test func testStreamFailureAndStartupTimeoutAreBounded() async throws {
        for script in ["echo 'permission denied' >&2; exit 255", "exec /bin/sleep 10"] {
            let command = TerminalCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: [:])
            let connection = try await CLITerminalConnection.start(command: command, mode: .observe, startupTimeout: 0.1)
            defer { connection.close() }
            await #expect(throws: HerdrFailure.self) {
                for try await _ in connection.events {}
            }
        }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private final class MockTerminalConnection: HerdrTerminalConnection, @unchecked Sendable {
    let events: AsyncThrowingStream<TerminalEvent, Error>
    let continuation: AsyncThrowingStream<TerminalEvent, Error>.Continuation
    private let lock = NSLock()
    private var inputs: [TerminalInput] = []
    private var closed = false
    var inputCount: Int { lock.withLock { inputs.count } }
    var sentBytes: [Data] {
        lock.withLock { inputs.compactMap { if case .bytes(let data) = $0 { data } else { nil } } }
    }
    var isClosed: Bool { lock.withLock { closed } }
    var scrolls: [String] {
        lock.withLock { inputs.compactMap { if case .scroll(let up, let lines) = $0 { "\(up ? "up" : "down") \(lines)" } else { nil } } }
    }
    var clicks: [String] {
        lock.withLock {
            inputs.compactMap { if case .mouse(let pressed, let column, let row) = $0 { "\(pressed ? "down" : "up") \(column),\(row)" } else { nil } }
        }
    }
    /// Attaches without a first frame until the test sends one.
    let holdsFrame: Bool
    init(holdsFrame: Bool = false) {
        let pair = AsyncThrowingStream<TerminalEvent, Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
        self.holdsFrame = holdsFrame
    }
    func send(_ input: TerminalInput) async throws { lock.withLock { inputs.append(input) } }
    func close() { lock.withLock { closed = true }; continuation.finish() }
    func frame() { continuation.yield(.frame(.init(bytes: Data("test".utf8), columns: 80, rows: 24, isFull: true))) }
}

private actor MockTerminalClient: HerdrTerminalClient {
    var connections: [MockTerminalConnection]
    var modes: [TerminalMode] = []
    /// Connections opened in these modes report a control conflict instead of a frame.
    var conflicted: Set<TerminalMode> = []
    /// How many attaches find a read of the pane in progress first.
    var busy: Int
    /// How far back Herdr shows the terminal.
    var history = 0
    /// How many attaches fail before connecting, such as while SSH can't reach the machine.
    var failing: Int
    init(_ connections: [MockTerminalConnection], conflicted: Set<TerminalMode> = [], busy: Int = 0, failing: Int = 0) {
        self.connections = connections
        self.conflicted = conflicted
        self.busy = busy
        self.failing = failing
    }
    func linesBack(in target: TerminalTarget) async throws -> Int? { history }
    func scrolled(to lines: Int) { history = lines }
    func connect(to target: TerminalTarget, mode: TerminalMode, size: TerminalSize) async throws -> any HerdrTerminalConnection {
        modes.append(mode)
        if failing > 0 {
            failing -= 1
            throw HerdrFailure(.unreachable, "Could not keep the Herdr terminal connected (exit 255).")
        }
        let connection = connections.removeFirst()
        if busy > 0 {
            busy -= 1
            connection.continuation.yield(.closed("terminal attach failed: terminal \(target.terminalID) has a read in progress; retry"))
            connection.continuation.finish()
        } else if conflicted.contains(mode) {
            connection.continuation.yield(.closed("terminal attach failed: terminal \(target.terminalID) already has an attached client; retry with --takeover"))
            connection.continuation.finish()
        } else if !connection.holdsFrame { connection.frame() }
        return connection
    }
    func requestedModes() -> [TerminalMode] { modes }
}

@MainActor struct TerminalStoreTests {
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Terminal state did not settle within one second")
    }

    @Test func attachRefusedDuringAReadIsRetried() async throws {
        let connections = [MockTerminalConnection(), MockTerminalConnection(), MockTerminalConnection()]
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let client = MockTerminalClient(connections, busy: 2)
        let store = TerminalStore(target: target, mode: .control, client: client)
        defer { store.disconnect() }
        store.open()
        for _ in 0..<200 where store.status != .interactive { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.status == .interactive)
        #expect(store.message == nil)
        #expect(await client.requestedModes() == [.control, .control, .control])
    }

    @Test func testObservationNeverSendsInputAndModeSwitchDetachesOnlyItsConnection() async throws {
        let observer = MockTerminalConnection()
        let controller = MockTerminalConnection()
        let target = TerminalTarget(machine: Fixture.remote, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: MockTerminalClient([observer, controller]))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .observing }
        store.send(.bytes(Data([3])))
        #expect(observer.inputCount == 0)
        store.open(mode: .control)
        try await wait { store.status == .interactive }
        #expect(observer.isClosed)
        store.send(.bytes(Data("hello".utf8)))
        try await wait { controller.inputCount == 1 }
        store.disconnect()
        #expect(controller.isClosed)
        #expect(store.status == .disconnected)
        store.send(.bytes(Data([3])))
        #expect(controller.inputCount == 1)
    }

    @Test func testClosedAndFailedStreamsAreVisibleAndCanReconnect() async throws {
        let first = MockTerminalConnection()
        let second = MockTerminalConnection()
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: MockTerminalClient([first, second]))
        defer { store.disconnect() }
        store.open(mode: .control)
        try await wait { store.status == .interactive }
        first.continuation.finish(throwing: HerdrFailure(.unreachable, "Connection lost"))
        try await wait { store.status == .failed }
        #expect(store.message == "Connection lost")
        store.open(mode: .observe)
        try await wait { store.status == .observing }
        #expect(store.message == nil)
        second.continuation.yield(.closed("Controlled elsewhere"))
        second.continuation.finish()
        try await wait { store.status == .ended }
        #expect(store.message == "Controlled elsewhere")
    }

    @Test func testLiveSessionsSubmitPromptsAsPasteThenReturn() async throws {
        let controller = MockTerminalConnection()
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: MockTerminalClient([controller]))
        defer { store.disconnect() }
        #expect(!store.submit(prompt: "too early"))
        store.open()
        try await wait { store.status == .interactive }
        #expect(!store.submit(prompt: "   "))
        #expect(store.submit(prompt: "line one\nline two"))
        store.press(.escape)
        try await wait { controller.sentBytes.count == 3 }
        #expect(controller.sentBytes == [Data("\u{1b}[200~line one\nline two\u{1b}[201~".utf8), Data([13]), Data([27])])
    }

    @Test func scrollingMovesThroughHerdrsHistoryAndInputReturnsToTheLatest() async throws {
        let controller = MockTerminalConnection()
        let client = MockTerminalClient([controller])
        // Someone left the terminal scrolled back in Herdr.
        await client.scrolled(to: 30)
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: client)
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .interactive && store.linesBack == 30 }
        store.scrollToLatest()
        #expect(store.linesBack == 0)
        await client.scrolled(to: 0)
        store.scroll(up: true, lines: 3)
        store.scroll(up: true, lines: 4)
        await client.scrolled(to: 7)
        try await wait { store.linesBack == 7 }
        #expect(controller.scrolls == ["down 500", "up 3", "up 4"])
        // Herdr returns to the latest output on input.
        store.send(.bytes(Data("x".utf8)))
        #expect(store.linesBack == 0)
    }

    @Test func aClickReachesProgramsThatReadTheMouse() async throws {
        let command = try TerminalJSON.command(.mouse(pressed: true, column: 12, row: 5))
        #expect(String(decoding: command, as: UTF8.self)
            == #"{"action":"down","button":"left","column":12,"row":5,"type":"terminal.mouse"}"# + "\n")
        let controller = MockTerminalConnection()
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: MockTerminalClient([controller]))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .interactive }
        store.click(column: 12, row: 5)
        try await wait { controller.clicks.count == 2 }
        #expect(controller.clicks == ["down 12,5", "up 12,5"])
    }

    @Test func aLockedTerminalCannotScroll() async throws {
        let observer = MockTerminalConnection()
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: MockTerminalClient([observer]))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .observing }
        store.scroll(up: true, lines: 5)
        #expect(observer.scrolls.isEmpty)
    }

    @Test func aDroppedConnectionWaitsBeforeTryingAgain() async throws {
        let first = MockTerminalConnection()
        let client = MockTerminalClient([first, MockTerminalConnection()])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: client,
                                  reconnecting: .init(first: .seconds(60), longest: .seconds(60), budget: .seconds(3_600)))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .interactive }
        first.continuation.finish(throwing: HerdrFailure(.unreachable, "Connection lost"))
        try await wait { store.reconnection?.next != nil }
        #expect(store.status == .failed && store.reconnection?.attempts == 0)
        #expect(store.message == "Connection lost")
        // Reconnecting by hand starts over.
        store.open()
        #expect(store.reconnection == nil)
        try await wait { store.status == .interactive }
        #expect(await client.requestedModes() == [.control, .control])
    }

    @Test func aDroppedConnectionReconnectsOnItsOwn() async throws {
        let first = MockTerminalConnection()
        let second = MockTerminalConnection(holdsFrame: true)
        let client = MockTerminalClient([first, second])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: client,
                                  reconnecting: .init(first: .milliseconds(10), longest: .seconds(1), budget: .seconds(60)))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .interactive }
        first.continuation.finish(throwing: HerdrFailure(.unreachable, "Connection lost"))
        // The attempt waits for its first frame, with the failure still on show.
        try await wait { store.reconnection?.attempts == 1 }
        #expect(store.status == .connecting && store.reconnection?.next == nil)
        #expect(store.message == "Connection lost")
        second.frame()
        try await wait { store.status == .interactive }
        #expect(store.reconnection == nil)
        #expect(store.message == nil)
        #expect(await client.requestedModes() == [.control, .control])
    }

    @Test func reconnectingBacksOffWhileItHasBudget() async throws {
        let policy = ReconnectPolicy.standard
        #expect([0, 1, 3, 8, 9, 40].map(policy.delay(after:)) == [.seconds(1), .seconds(2), .seconds(8), .seconds(256), .seconds(300), .seconds(300)])
        let client = MockTerminalClient([], failing: 100)
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: client,
                                  reconnecting: .init(first: .milliseconds(5), longest: .milliseconds(20), budget: .seconds(3_600)))
        defer { store.disconnect() }
        store.open()
        try await wait { (store.reconnection?.attempts ?? 0) >= 3 }
        #expect(store.reconnection?.gaveUp == false)
    }

    @Test func reconnectingGivesUpAfterItsBudget() async throws {
        let client = MockTerminalClient([MockTerminalConnection()], failing: 100)
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        // A budget shorter than the first wait has run out by the time that attempt fails, however slow the machine.
        let store = TerminalStore(target: target, client: client,
                                  reconnecting: .init(first: .milliseconds(5), longest: .milliseconds(20), budget: .milliseconds(1)))
        defer { store.disconnect() }
        store.open()
        try await wait { store.reconnection?.gaveUp == true }
        #expect(store.reconnection?.attempts == 1)
        #expect(await client.requestedModes().count == 2)
        #expect(store.status == .failed && store.reconnection?.next == nil)
        // Giving up stops trying until the user reconnects, which starts over.
        try await Task.sleep(for: .milliseconds(60))
        #expect(await client.requestedModes().count == 2)
        store.open()
        #expect(store.reconnection == nil)
    }

    @Test func aTerminalNobodySeesRestsAndComesBackInItsMode() async throws {
        let first = MockTerminalConnection()
        let second = MockTerminalConnection(holdsFrame: true)
        let client = MockTerminalClient([first, second])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: client, restsAfter: .milliseconds(20))
        var resets = 0
        store.resetDisplay = { resets += 1 }
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .interactive }
        store.setVisible(false)
        try await wait { store.isResting }
        #expect(store.status == .disconnected && store.reconnection == nil && first.isClosed)
        // Resting isn't a drop: nothing reconnects meanwhile.
        try await Task.sleep(for: .milliseconds(60))
        #expect(await client.requestedModes() == [.control])
        #expect(store.reconnection == nil)
        let before = resets
        store.setVisible(true)
        #expect(!store.isResting && store.status == .connecting)
        // The screen keeps its last frame until Herdr sends the whole screen again.
        try await Task.sleep(for: .milliseconds(20))
        #expect(resets == before)
        second.frame()
        try await wait { store.status == .interactive }
        #expect(resets == before + 1)
        #expect(await client.requestedModes() == [.control, .control])
    }

    @Test func aGlanceAwayKeepsTheTerminalAttached() async throws {
        let client = MockTerminalClient([MockTerminalConnection()])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: client, restsAfter: .milliseconds(30))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .interactive }
        store.setVisible(false)
        store.setVisible(true)
        try await Task.sleep(for: .milliseconds(90))
        #expect(!store.isResting && store.status == .interactive)
        #expect(await client.requestedModes() == [.control])
    }

    @Test func aTerminalThatEndedForGoodDoesNotRest() async throws {
        let gone = MockTerminalConnection()
        let client = MockTerminalClient([gone])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: client, restsAfter: .milliseconds(10))
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .observing }
        gone.continuation.yield(.closed("terminal attach ended: terminal a not found"))
        gone.continuation.finish()
        try await wait { store.status == .ended }
        store.setVisible(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!store.isResting && store.status == .ended)
        store.setVisible(true)
        #expect(await client.requestedModes() == [.observe])
    }

    @Test func aTerminalReconnectingWhileNobodySeesItStartsAfreshWhenItShows() async throws {
        let client = MockTerminalClient([MockTerminalConnection()], failing: 1)
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: client,
                                  reconnecting: .init(first: .seconds(60), longest: .seconds(60), budget: .seconds(3_600)),
                                  restsAfter: .milliseconds(10))
        defer { store.disconnect() }
        store.open()
        try await wait { store.reconnection?.next != nil }
        store.setVisible(false)
        try await wait { store.isResting }
        #expect(store.reconnection == nil)
        store.setVisible(true)
        try await wait { store.status == .observing }
        #expect(store.reconnection == nil && store.message == nil)
        #expect(await client.requestedModes() == [.observe, .observe])
    }

    /// Herdr ends a terminal whose program exited, such as a shell you typed `exit` in, and refuses
    /// to attach to one it no longer has.
    @Test(arguments: ["terminal a exited", "terminal session control failed: terminal target a not found"])
    func aTerminalThatIsGoneIsNotRetried(reason: String) async throws {
        let gone = MockTerminalConnection()
        let client = MockTerminalClient([gone])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: client,
                                  reconnecting: .init(first: .milliseconds(5), longest: .milliseconds(5), budget: .seconds(60)))
        defer { store.disconnect() }
        var ends = 0
        store.onGone = { ends += 1 }
        store.open()
        try await wait { store.status == .observing }
        gone.continuation.yield(.closed(reason))
        gone.continuation.finish()
        try await wait { store.status == .ended }
        try await Task.sleep(for: .milliseconds(30))
        #expect(store.reconnection == nil)
        #expect(ends == 1)
        #expect(await client.requestedModes() == [.observe])
    }

    @Test func aDroppedConnectionIsNotAnEnd() async throws {
        let dropped = MockTerminalConnection()
        let client = MockTerminalClient([dropped, MockTerminalConnection()])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, client: client,
                                  reconnecting: .init(first: .milliseconds(50), longest: .milliseconds(50), budget: .seconds(60)))
        defer { store.disconnect() }
        var ends = 0
        store.onGone = { ends += 1 }
        store.open()
        try await wait { store.status == .observing }
        dropped.continuation.finish()
        try await wait { store.status == .ended }
        try await wait { store.status == .observing }
        #expect(ends == 0)
        #expect(await client.requestedModes() == [.observe, .observe])
    }

    @Test func testControlConflictFallsBackToWatchingUntilUserTakesOver() async throws {
        let rejected = MockTerminalConnection()
        let observer = MockTerminalConnection()
        let taker = MockTerminalConnection()
        let reconnect = MockTerminalConnection()
        let client = MockTerminalClient([rejected, observer, taker, reconnect], conflicted: [.control])
        let target = TerminalTarget(machine: .local, terminalID: "a", title: "Agent", workspace: "Project")
        let store = TerminalStore(target: target, mode: .control, client: client)
        defer { store.disconnect() }
        store.open()
        try await wait { store.status == .observing }
        #expect(store.isControlledElsewhere)
        #expect(store.message == nil)
        #expect(!store.submit(prompt: "blocked"))
        store.takeOver()
        try await wait { store.status == .interactive }
        #expect(!store.isControlledElsewhere)
        #expect(store.mode == .control)
        #expect(await client.requestedModes() == [.control, .observe, .takeover])
        // Another client taking over later also returns this view to watching, without retrying control.
        taker.continuation.yield(.closed("terminal attach taken over"))
        try await wait { store.status == .observing }
        #expect(store.isControlledElsewhere)
        #expect(await client.requestedModes() == [.control, .observe, .takeover, .observe])
    }
}

@Suite struct TerminalLinkTests {
    /// Builds a screen from text rows, padded to a fixed number of columns.
    private func screen(_ lines: [String], columns: Int = 40) -> [[Character]] {
        lines.map { Array($0.padding(toLength: columns, withPad: " ", startingAt: 0)) }
    }

    private func column(of text: String, in line: String) -> Int {
        line.distance(from: line.startIndex, to: line.range(of: text)!.lowerBound)
    }

    @Test func findsTheLinkUnderTheClickOnly() {
        let line = "docs: https://herdr.dev/docs/ and more"
        let rows = screen([line])
        #expect(TerminalLinks.url(in: rows, row: 0, column: column(of: "herdr", in: line))?.absoluteString == "https://herdr.dev/docs/")
        #expect(TerminalLinks.url(in: rows, row: 0, column: 1) == nil)
        #expect(TerminalLinks.url(in: rows, row: 0, column: column(of: "more", in: line)) == nil)
        #expect(TerminalLinks.url(in: rows, row: 3, column: 0) == nil)
    }

    @Test func dropsSurroundingPunctuationButKeepsBalancedBrackets() {
        let prose = "(see https://example.com/a?b=1)."
        let wiki = "https://en.wikipedia.org/wiki/Shepherd_(dog)"
        let rows = screen([prose, wiki], columns: 50)
        #expect(TerminalLinks.url(in: rows, row: 0, column: 10)?.absoluteString == "https://example.com/a?b=1")
        #expect(TerminalLinks.url(in: rows, row: 0, column: prose.count - 1) == nil)
        #expect(TerminalLinks.url(in: rows, row: 1, column: 3)?.absoluteString == wiki)
    }

    @Test func followsLinksThatWrapAcrossRows() {
        let rows = screen(["https://example.com/a/very/long/", "path/to/report.html is ready"], columns: 32)
        let expected = "https://example.com/a/very/long/path/to/report.html"
        #expect(TerminalLinks.url(in: rows, row: 0, column: 3)?.absoluteString == expected)
        #expect(TerminalLinks.url(in: rows, row: 1, column: 6)?.absoluteString == expected)
    }

    @Test func decorationAndOtherSchemesAreNotLinks() {
        let rows = screen(["│https://a.dev/x│", "file:///etc/hosts", "ssh://host", "https:// nothing"])
        #expect(TerminalLinks.url(in: rows, row: 0, column: 4)?.absoluteString == "https://a.dev/x")
        #expect(TerminalLinks.url(in: rows, row: 1, column: 4) == nil)
        #expect(TerminalLinks.url(in: rows, row: 2, column: 4) == nil)
        #expect(TerminalLinks.url(in: rows, row: 3, column: 2) == nil)
    }
}
