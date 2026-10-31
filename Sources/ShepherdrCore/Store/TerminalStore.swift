import Foundation
import Observation

@MainActor @Observable
public final class TerminalStore {
    public enum Status: Equatable { case disconnected, connecting, observing, interactive, ended, failed }

    /// Reconnecting on its own after the connection dropped, from the drop until a frame arrives again.
    public struct Reconnection: Equatable, Sendable {
        /// Attempts made since the connection dropped.
        public fileprivate(set) var attempts = 0
        /// When the next attempt starts, on a clock that stops while the Mac sleeps. Nil while an attempt runs.
        public fileprivate(set) var next: SuspendingClock.Instant?
        /// Tried for the whole budget without success: only a manual reconnect tries again.
        public fileprivate(set) var gaveUp = false
        fileprivate let started: SuspendingClock.Instant
    }

    public let target: TerminalTarget
    public private(set) var status: Status = .disconnected
    public private(set) var mode: TerminalMode = .observe
    public private(set) var message: String?
    public private(set) var detail: String?
    public private(set) var size = TerminalSize()
    @ObservationIgnored public var display: ((TerminalFrame) -> Void)?
    @ObservationIgnored public var resetDisplay: (() -> Void)?
    /// Called when the terminal ended for good in Herdr, such as a shell you typed `exit` in.
    @ObservationIgnored public var onGone: (() -> Void)?
    @ObservationIgnored private let client: any HerdrTerminalClient
    @ObservationIgnored private var connection: (any HerdrTerminalConnection)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    /// Attaches Herdr refused because something was reading the pane, such as Shepherdr collecting links.
    @ObservationIgnored private var busyRetries = 0

    /// Another client already controls this terminal; Shepherdr fell back to observing it.
    public private(set) var isControlledElsewhere = false

    public private(set) var reconnection: Reconnection?
    @ObservationIgnored private let reconnecting: ReconnectPolicy
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    /// Detached because nobody could see it for a while: it attaches again as soon as it shows.
    @ObservationIgnored public private(set) var isResting = false
    /// How long the terminal may be out of sight before it detaches.
    @ObservationIgnored private let restsAfter: Duration
    @ObservationIgnored private var restTask: Task<Void, Never>?
    /// Back from a rest: the screen keeps its last frame until Herdr sends the whole one again.
    @ObservationIgnored private var keepsScreen = false

    /// How many lines above the latest output Herdr shows: 0 at the bottom. Herdr keeps the history.
    public private(set) var linesBack = 0
    /// When you last typed or pasted here, such as to tell whether you're talking to an agent.
    @ObservationIgnored public private(set) var lastInput: Date?
    @ObservationIgnored private var scrollCheck: Task<Void, Never>?
    @ObservationIgnored private var scrolledSinceCheck = false

    public init(target: TerminalTarget, mode: TerminalMode = .observe,
                client: any HerdrTerminalClient = CLIHerdrClient(), reconnecting: ReconnectPolicy = .standard,
                restsAfter: Duration = .seconds(30)) {
        self.target = target
        self.mode = mode == .takeover ? .control : mode
        self.client = client
        self.reconnecting = reconnecting
        self.restsAfter = restsAfter
    }

    /// Connects afresh, as the user asks: any reconnection in progress starts over.
    public func open(mode: TerminalMode? = nil) {
        reconnection = nil
        isResting = false
        keepsScreen = false
        connect(mode: mode ?? self.mode)
    }

    /// Whether anyone can see this terminal: Shepherdr's window shows, and the screens are on and
    /// unlocked. Out of sight for a while, the terminal detaches, so a busy agent's output costs
    /// nothing while nobody looks; it attaches again, in the same mode, as soon as it shows. A
    /// detach on purpose is not a drop: nothing reconnects meanwhile, and coming back starts afresh.
    public func setVisible(_ visible: Bool) {
        guard visible else {
            guard restTask == nil, !isResting else { return }
            let patience = restsAfter
            restTask = Task { [weak self] in
                do { try await Task.sleep(for: patience) } catch { return }
                self?.rest()
            }
            return
        }
        restTask?.cancel()
        restTask = nil
        guard isResting else { return }
        isResting = false
        keepsScreen = true
        // Coming back never takes over another client's input on its own.
        connect(mode: mode == .takeover ? .control : mode)
    }

    /// Detaches a terminal that streams, or is on its way to: one that ended for good, or gave up
    /// reconnecting, stays as it is.
    private func rest() {
        restTask = nil
        let attached = status == .connecting || status == .observing || status == .interactive
        guard attached || reconnection?.gaveUp == false else { return }
        reconnection = nil
        isResting = true
        detach()
    }

    private func connect(mode: TerminalMode) {
        detach()
        self.mode = mode
        status = .connecting
        if mode != .observe { isControlledElsewhere = false }
        // While reconnecting, the banner keeps the last failure and the screen its last frame.
        if reconnection == nil && !keepsScreen {
            message = nil
            detail = nil
            resetDisplay?()
        }
        let attempt = generation
        task = Task { [weak self, client, target, size] in
            do {
                let stream = try await client.connect(to: target, mode: mode, size: size)
                guard let self, attempt == self.generation, !Task.isCancelled else { stream.close(); return }
                self.connection = stream
                defer { stream.close() }
                // Herdr may still show history someone scrolled to earlier.
                self.checkLinesBack()
                var closedBecause: String?
                for try await event in stream.events {
                    guard attempt == self.generation, !Task.isCancelled else { return }
                    switch event {
                    case .frame(let frame):
                        self.busyRetries = 0
                        if self.reconnection != nil || self.keepsScreen {
                            self.reconnection = nil
                            self.keepsScreen = false
                            self.message = nil
                            self.detail = nil
                            self.resetDisplay?()
                        }
                        // Written only on change: every write invalidates the views that read it.
                        let status: Status = mode.acceptsInput ? .interactive : .observing
                        if self.status != status { self.status = status }
                        // A takeover happens once; later reconnects ask politely again.
                        if mode == .takeover, self.mode != .control { self.mode = .control }
                        self.display?(frame)
                    case .closed(let reason):
                        if self.status == .connecting, Self.isBusy(reason), self.busyRetries < 5 {
                            // Herdr asks to retry an attach while a read of the pane is in progress.
                            self.busyRetries += 1
                            let delay = Duration.milliseconds(250 * self.busyRetries)
                            Task { [weak self] in
                                try? await Task.sleep(for: delay)
                                guard let self, attempt == self.generation else { return }
                                self.connect(mode: mode)
                            }
                            return
                        }
                        let rejected = self.status == .connecting && Self.isControlConflict(reason)
                        if mode.acceptsInput, rejected || Self.wasTakenOver(reason) {
                            // Never steal input implicitly: keep watching and let the user decide.
                            self.isControlledElsewhere = true
                            self.connect(mode: .observe)
                            return
                        }
                        closedBecause = reason
                        self.message = reason
                        self.detail = nil
                        self.status = .ended
                    }
                }
                if attempt == self.generation, self.status != .failed {
                    self.status = .ended
                    self.message = closedBecause ?? "Detached. The terminal continues in Herdr."
                    self.connection = nil
                    // A terminal that no longer exists won't come back.
                    if closedBecause.map(Self.isGone) == true {
                        self.reconnection = nil
                        self.onGone?()
                    } else { self.reconnectLater() }
                }
            } catch {
                guard let self, attempt == self.generation, !Task.isCancelled else { return }
                self.status = .failed
                self.message = error.localizedDescription
                self.detail = (error as? HerdrFailure)?.detail
                self.connection = nil
                // An incompatible Herdr or an invalid target fails the same way every time.
                if (error as? HerdrFailure)?.state == .incompatible { self.reconnection = nil } else { self.reconnectLater() }
            }
        }
    }

    /// Tries again after a wait that doubles with each attempt, until it has tried for the policy's
    /// budget. The waits and the budget run on the suspending clock, so time asleep doesn't count.
    private func reconnectLater() {
        let now = SuspendingClock.now
        var reconnection = reconnection ?? Reconnection(started: now)
        guard reconnection.started.duration(to: now) < reconnecting.budget else {
            reconnection.gaveUp = true
            self.reconnection = reconnection
            return
        }
        let next = now.advanced(by: reconnecting.delay(after: reconnection.attempts))
        reconnection.next = next
        self.reconnection = reconnection
        let attempt = generation
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(until: next, clock: .suspending) } catch { return }
            guard let self, attempt == self.generation, var reconnection = self.reconnection else { return }
            reconnection.attempts += 1
            reconnection.next = nil
            self.reconnection = reconnection
            self.reconnectTask = nil
            // Reconnecting never takes over another client's input on its own.
            self.connect(mode: self.mode == .takeover ? .control : self.mode)
        }
    }

    /// Detaches and stops reconnecting.
    public func disconnect() {
        reconnection = nil
        restTask?.cancel()
        restTask = nil
        isResting = false
        keepsScreen = false
        detach()
    }

    private func detach() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        resizeTask?.cancel()
        resizeTask = nil
        inputTask?.cancel()
        inputTask = nil
        scrollCheck?.cancel()
        scrollCheck = nil
        task?.cancel()
        task = nil
        connection?.close()
        connection = nil
        status = .disconnected
    }

    /// Explicit, user-initiated replacement of another controlling client.
    public func takeOver() { open(mode: .takeover) }

    /// Types a composed prompt and submits it with a separate Return keystroke.
    @discardableResult
    public func submit(prompt text: String) -> Bool {
        guard status == .interactive, let body = TerminalPrompt.body(text) else { return false }
        send(.bytes(body))
        send(.pause(.milliseconds(body.first == 27 ? 120 : 40)))
        send(.bytes(TerminalPrompt.submit))
        return true
    }

    public func press(_ key: TerminalKey) { send(.bytes(key.bytes)) }

    /// Clicks a cell for programs that read the mouse, such as Claude Code in full screen, which
    /// moves its cursor there. Herdr 0.9.2 and later deliver it; earlier versions ignore it.
    public func click(column: Int, row: Int) {
        send(.mouse(pressed: true, column: column, row: row))
        send(.mouse(pressed: false, column: column, row: row))
    }

    /// Scrolls through the history Herdr keeps, which Herdr then paints; in a full-screen program,
    /// such as less, Herdr scrolls the program instead. Herdr takes scrolling only from a client in control.
    public func scroll(up: Bool, lines: Int) {
        guard status == .interactive, lines > 0 else { return }
        send(.scroll(up: up, lines: lines))
        checkLinesBack()
    }

    /// Back to the latest output, as typing also does.
    public func scrollToLatest() {
        guard status == .interactive else { return }
        // Herdr scrolls up to 500 lines at a time.
        for _ in 0...(linesBack / 500) { send(.scroll(up: false, lines: 500)) }
        if linesBack != 0 { linesBack = 0 }
        checkLinesBack()
    }

    /// Asks Herdr how far back it shows the terminal once scrolling pauses, and again while it goes on.
    private func checkLinesBack() {
        scrolledSinceCheck = true
        guard scrollCheck == nil else { return }
        let attempt = generation
        scrollCheck = Task { [weak self, client, target] in
            while let self, self.scrolledSinceCheck, attempt == self.generation {
                self.scrolledSinceCheck = false
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                if let lines = try? await client.linesBack(in: target), attempt == self.generation, lines != self.linesBack {
                    self.linesBack = lines
                }
            }
            if let self, attempt == self.generation { self.scrollCheck = nil }
        }
    }

    public func send(_ input: TerminalInput) {
        guard status == .interactive, let connection else { return }
        // Herdr returns to the latest output whenever the terminal gets input.
        if case .bytes = input {
            lastInput = Date()
            if linesBack != 0 { linesBack = 0 }
        }
        let previous = inputTask
        let attempt = generation
        // Keep keyboard/paste/resize order even though the transport API is asynchronous.
        inputTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.generation == attempt else { return }
            do {
                if case .pause(let duration) = input { try await Task.sleep(for: duration) }
                else { try await connection.send(input) }
            }
            catch {
                guard let self, self.generation == attempt else { return }
                self.message = error.localizedDescription
                self.detail = (error as? HerdrFailure)?.detail
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        let next = TerminalSize(columns: columns, rows: rows)
        guard next != size else { return }
        size = next
        resizeTask?.cancel()
        resizeTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard let self else { return }
            if self.status == .interactive { self.send(.resize(self.size)) }
            // Observe has no stdin resize authority. Reopen just this observer at its new viewport.
            else if self.status == .observing || self.status == .connecting { self.connect(mode: self.mode) }
        }
    }

    nonisolated static func wasTakenOver(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("taken over")
    }

    nonisolated static func isBusy(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("in progress; retry")
    }

    /// Herdr ended the terminal because its program exited, or no longer has it.
    nonisolated static func isGone(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("not found") || reason.hasSuffix(" exited")
    }

    nonisolated static func isControlConflict(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("already has an attached client")
            || reason.localizedCaseInsensitiveContains("--takeover")
    }
}
