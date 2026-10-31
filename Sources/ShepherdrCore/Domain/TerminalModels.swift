import Foundation

public struct TerminalPane: Identifiable, Equatable, Sendable {
    public let terminalID: String
    public let paneID: String
    public let workspaceID: String
    public let tabID: String
    public let workspaceName: String
    public let title: String
    /// The pane's foreground working directory, else the one it started in.
    public let directory: String?
    public var id: String { terminalID }
}

/// A window always targets this exact terminal and session, never the caller's focused pane.
public struct TerminalTarget: Hashable, Codable, Sendable {
    public let machine: Machine
    public let terminalID: String
    public let title: String
    public let workspace: String

    public init(machine: Machine, terminalID: String, title: String, workspace: String) {
        self.machine = machine
        self.terminalID = terminalID
        self.title = title
        self.workspace = workspace
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.machine.id == rhs.machine.id && lhs.machine.session == rhs.machine.session && lhs.terminalID == rhs.terminalID
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(machine.id)
        hasher.combine(machine.session)
        hasher.combine(terminalID)
    }
}

public enum TerminalMode: String, Sendable {
    case observe, control
    /// Control that explicitly replaces another attached client. Only ever chosen by the user.
    case takeover

    public var acceptsInput: Bool { self != .observe }
    var subcommand: String { self == .observe ? "observe" : "control" }
}

/// Encodes a composed prompt as terminal keystrokes. Multi-line text uses bracketed paste so
/// agents and shells insert it verbatim; the submitting Return is a separate keystroke so it is
/// never swallowed as part of a paste.
public enum TerminalPrompt {
    public static let submit = Data([13])

    public static func body(_ text: String) -> Data? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Strip escape characters so pasted text can never terminate bracketed paste early.
        let safe = normalized.replacingOccurrences(of: "\u{1b}", with: "")
        guard safe.contains("\n") else { return Data(safe.utf8) }
        return Data("\u{1b}[200~".utf8) + Data(safe.utf8) + Data("\u{1b}[201~".utf8)
    }
}

/// Keys offered next to the prompt composer for driving terminal agents without focusing the terminal.
public enum TerminalKey: String, CaseIterable, Sendable {
    case escape, interrupt, tab, up, down, enter

    public var bytes: Data {
        switch self {
        case .escape: Data([27])
        case .interrupt: Data([3])
        case .tab: Data([9])
        case .up: Data("\u{1b}[A".utf8)
        case .down: Data("\u{1b}[B".utf8)
        case .enter: Data([13])
        }
    }
}

public struct TerminalSize: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public init(columns: Int = 100, rows: Int = 30) {
        self.columns = min(500, max(2, columns))
        self.rows = min(250, max(2, rows))
    }
}

/// How a terminal reconnects on its own after its connection drops: the wait doubles after each
/// attempt up to the longest, and it stops trying once it has tried for the whole budget.
/// Time counts only while the Mac is awake.
public struct ReconnectPolicy: Sendable {
    public let first: Duration
    public let longest: Duration
    public let budget: Duration

    public init(first: Duration, longest: Duration, budget: Duration) {
        self.first = first
        self.longest = longest
        self.budget = budget
    }

    public static let standard = ReconnectPolicy(first: .seconds(1), longest: .seconds(300), budget: .seconds(3_600))

    /// The wait before the next attempt, after this many failed ones.
    public func delay(after attempts: Int) -> Duration {
        min(first * (1 << min(max(attempts, 0), 20)), longest)
    }
}

public struct TerminalFrame: Equatable, Sendable {
    public let bytes: Data
    public let columns: Int
    public let rows: Int
    public let isFull: Bool
}

public enum TerminalEvent: Equatable, Sendable {
    case frame(TerminalFrame)
    case closed(String)
}

public enum TerminalInput: Sendable {
    case bytes(Data)
    case resize(TerminalSize)
    case scroll(up: Bool, lines: Int)
    /// The left button pressed or released at a zero-based cell of the visible terminal. Herdr
    /// encodes it for the program's mouse mode and drops it when the program doesn't read the mouse.
    case mouse(pressed: Bool, column: Int, row: Int)
    case release
    /// Local pacing between queued inputs; never written to the terminal.
    case pause(Duration)
}

public protocol HerdrTerminalConnection: Sendable {
    var events: AsyncThrowingStream<TerminalEvent, Error> { get }
    func send(_ input: TerminalInput) async throws
    /// Detaches this client only. It must never stop the server, pane or its shell.
    func close()
}

public protocol HerdrTerminalClient: Sendable {
    func connect(to target: TerminalTarget, mode: TerminalMode, size: TerminalSize) async throws -> any HerdrTerminalConnection
    /// How many lines above its latest output Herdr shows the terminal: 0 at the bottom; nil when
    /// Herdr cannot tell. Herdr keeps the history and scrolls it, for every client at once.
    func linesBack(in target: TerminalTarget) async throws -> Int?
}

extension HerdrTerminalClient {
    public func linesBack(in target: TerminalTarget) async throws -> Int? { nil }
}
