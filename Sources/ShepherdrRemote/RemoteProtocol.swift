import Foundation

/// The relay's wire protocol: one WebSocket over TLS between Shepherdr on the Mac and Shepherdr
/// Remote on a phone. Control travels as JSON text messages; terminal frames as binary ones.
public enum RemoteProtocol {
    /// Bumped whenever a message changes in a way the other side can't read.
    public static let version = 1
    public static let defaultPort: UInt16 = 1337

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// A session or a pane on one of the Mac's machines, as Shepherdr addresses it.
public struct RemoteSessionID: Hashable, Codable, Sendable {
    public let machineID: String
    public let terminalID: String

    public init(machineID: String, terminalID: String) {
        self.machineID = machineID
        self.terminalID = terminalID
    }
}

/// What the phone sends.
public enum ClientMessage: Codable, Equatable, Sendable {
    /// The first message of a paired phone: its token proves who it is.
    case hello(deviceID: String, token: String, version: Int)
    /// The first message of a phone that scanned a pairing code.
    case pair(code: String, deviceName: String, version: Int)
    /// Streams a pane's terminal on a channel the phone numbers, at the phone's size.
    case attach(channel: Int, pane: RemoteSessionID, columns: Int, rows: Int)
    /// Takes control of a pane another client controls. Only ever the user's explicit choice.
    case takeOver(channel: Int)
    case detach(channel: Int)
    /// Keys typed into the terminal, as the terminal encodes them.
    case input(channel: Int, bytes: Data)
    case resize(channel: Int, columns: Int, rows: Int)
    /// Scrolls through the history Herdr keeps for the terminal.
    case scroll(channel: Int, up: Bool, lines: Int)
    /// A composed prompt for the agent in a pane, typed as a paste followed by Return.
    case prompt(pane: RemoteSessionID, text: String)
    /// Compass: a run now, as the Mac's ▶ RUN button does.
    case compassRun
    /// Compass: stop waiting for the open run. The agent keeps whatever it is doing.
    case compassCancel
    /// Compass: a day's page (`2026-11-02`), or today's when nil.
    case compassPage(day: String?)
    case ping
}

/// What the Mac sends.
public enum ServerMessage: Codable, Equatable, Sendable {
    case welcome(macName: String, version: Int)
    /// Pairing worked: the phone keeps the token and says hello with it from now on.
    case paired(deviceID: String, token: String, macName: String)
    /// The connection is refused, and why. The Mac closes it afterwards.
    case refused(reason: String)
    case queue(QueueSnapshot)
    case terminal(channel: Int, state: RemoteTerminalState, message: String?)
    /// The terminal starts over: clear the screen before the next frame.
    case reset(channel: Int)
    /// Something the phone asked for didn't work.
    case failure(message: String)
    /// The Compass page the phone asked for, or nil when that day has none.
    case compassPage(day: String, html: String?)
    case pong
}

public enum RemoteTerminalState: String, Codable, Sendable {
    case connecting
    /// The phone's keys reach the terminal.
    case control
    /// Another client controls the terminal: the phone watches and may take over.
    case controlledElsewhere
    case observing
    /// Herdr ended the terminal, or the Mac stopped streaming it.
    case ended
    case failed
}

/// Shepherdr's queue as the Mac's sidebar lists it, flattened for a phone: groups, project headings,
/// sessions with the sessions they wait for nested under them, and shells.
public struct QueueSnapshot: Codable, Equatable, Sendable {
    public var macName: String
    public var machines: [RemoteMachine]
    public var rows: [QueueRow]
    /// Compass, once it is set up on the Mac.
    public var compass: RemoteCompass?

    public init(macName: String, machines: [RemoteMachine], rows: [QueueRow], compass: RemoteCompass? = nil) {
        self.macName = macName
        self.machines = machines
        self.rows = rows
        self.compass = compass
    }
}

/// Compass as the Mac's column shows it: what its agent is doing, when it runs next, and the agent
/// itself. Pages travel on request, with `compassPage`.
public struct RemoteCompass: Codable, Equatable, Sendable {
    /// `● running since 10:02`, `✓ updated 09:00`, `! needs you in its terminal`…
    public let activity: String
    public let needsYou: Bool
    /// A run is under way: another can't start, and this one can be cancelled.
    public let isRunning: Bool
    /// `next run 14:00`, `runs when you ask`…
    public let next: String
    public let problem: String?
    /// Today's page changed since you last looked at it on the Mac.
    public let hasNews: Bool
    /// When today's page last changed, to fetch it again.
    public let pageModified: Date?
    public let today: String
    /// The days with a page, newest first.
    public let days: [String]
    /// The Compass agent's session, to open its terminal; nil until it starts.
    public let agent: QueueRow?

    public init(activity: String, needsYou: Bool, isRunning: Bool, next: String, problem: String?, hasNews: Bool,
                pageModified: Date?, today: String, days: [String], agent: QueueRow?) {
        self.activity = activity
        self.needsYou = needsYou
        self.isRunning = isRunning
        self.next = next
        self.problem = problem
        self.hasNews = hasNews
        self.pageModified = pageModified
        self.today = today
        self.days = days
        self.agent = agent
    }
}

/// One of a session's resources, as the Mac's Resources column lists it.
public struct RemoteResource: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case pullRequest, issue, artifact, link, repository
    }

    public let kind: Kind
    /// `theam/shepherdr#12`, `ENG-42`…
    public let name: String
    /// The page's title, once the Mac checked it.
    public let title: String?
    public let url: String
    /// `open`, `merged` or `closed`, when the Mac knows.
    public let state: String?
    /// A pull request's checks: `passed`, `failed` or `running`.
    public let checks: String?
    public var id: String { url }

    public init(kind: Kind, name: String, title: String?, url: String, state: String? = nil, checks: String? = nil) {
        self.kind = kind
        self.name = name
        self.title = title
        self.url = url
        self.state = state
        self.checks = checks
    }
}

public struct RemoteMachine: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Online, loading, unreachable…, as Shepherdr words it.
    public let connection: String
    public let isOnline: Bool

    public init(id: String, name: String, connection: String, isOnline: Bool) {
        self.id = id
        self.name = name
        self.connection = connection
        self.isOnline = isOnline
    }
}

public struct QueueRow: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case group, project, session, shell, section }

    /// Unique within a snapshot.
    public let id: String
    public let kind: Kind
    /// Sessions and shells; nil for headings.
    public let session: RemoteSessionID?
    /// The session's place in the queue, counting from 1.
    public let number: Int?
    /// 0 at the top level; one more inside a group, a project or under a session waiting for it.
    public let depth: Int
    /// The session's name, or the heading's.
    public let title: String
    /// What the agent last said, or Herdr's summary.
    public let summary: String?
    /// The agent's kind, such as `claude`.
    public let agent: String?
    public let machine: String?
    /// A `SessionStatus` raw value: `needsYou`, `working`, `waiting`, `done`, `idle`, `stale`…
    public let status: String?
    /// For headings: how many of their sessions need you.
    public let needsYou: Int
    /// The panes of the session's Herdr tab, its own first; one for a session without splits.
    public let panes: [RemotePane]
    /// Where the session sits in its tree of sessions on hold, to draw the lines that tie it to the
    /// session waiting for it. Nil outside such a tree.
    public let tree: QueueTree?
    /// Inside a group, under its heading: the group's line runs down beside it.
    public let inGroup: Bool
    /// Under a project's heading: the project's line runs down beside it.
    public let inProject: Bool
    /// The session's pull requests, issues and links, the most relevant first.
    public let resources: [RemoteResource]

    public init(id: String, kind: Kind, session: RemoteSessionID? = nil, number: Int? = nil, depth: Int = 0,
                title: String, summary: String? = nil, agent: String? = nil, machine: String? = nil,
                status: String? = nil, needsYou: Int = 0, panes: [RemotePane] = [], tree: QueueTree? = nil,
                inGroup: Bool = false, inProject: Bool = false, resources: [RemoteResource] = []) {
        self.id = id
        self.kind = kind
        self.session = session
        self.number = number
        self.depth = depth
        self.title = title
        self.summary = summary
        self.agent = agent
        self.machine = machine
        self.status = status
        self.needsYou = needsYou
        self.panes = panes
        self.tree = tree
        self.inGroup = inGroup
        self.inProject = inProject
        self.resources = resources
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, session, number, depth, title, summary, agent, machine, status, needsYou, panes, tree, inGroup, inProject, resources
    }

    /// Reads rows from a Mac that doesn't send the lines or resources yet, so that a phone
    /// updated first still shows the queue.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id), kind: try container.decode(Kind.self, forKey: .kind),
                  session: try container.decodeIfPresent(RemoteSessionID.self, forKey: .session),
                  number: try container.decodeIfPresent(Int.self, forKey: .number),
                  depth: try container.decodeIfPresent(Int.self, forKey: .depth) ?? 0,
                  title: try container.decode(String.self, forKey: .title),
                  summary: try container.decodeIfPresent(String.self, forKey: .summary),
                  agent: try container.decodeIfPresent(String.self, forKey: .agent),
                  machine: try container.decodeIfPresent(String.self, forKey: .machine),
                  status: try container.decodeIfPresent(String.self, forKey: .status),
                  needsYou: try container.decodeIfPresent(Int.self, forKey: .needsYou) ?? 0,
                  panes: try container.decodeIfPresent([RemotePane].self, forKey: .panes) ?? [],
                  tree: try container.decodeIfPresent(QueueTree.self, forKey: .tree),
                  inGroup: try container.decodeIfPresent(Bool.self, forKey: .inGroup) ?? false,
                  inProject: try container.decodeIfPresent(Bool.self, forKey: .inProject) ?? false,
                  resources: try container.decodeIfPresent([RemoteResource].self, forKey: .resources) ?? [])
    }
}

/// Searching the queue as the Mac's ⌘T does: the sessions and shells with every word typed in
/// their name, summary, agent, panes, state or resources, and `@name` for a machine; in the
/// queue's order, without headings.
public enum QueueSearch {
    public static func rows(_ rows: [QueueRow], matching query: String) -> [QueueRow] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return rows }
        return rows.filter { row in
            guard row.session != nil else { return false }
            let text = ([row.title, row.summary, row.agent, row.machine, row.status, statusWords(row.status)]
                + row.panes.map(\.title) + row.resources.flatMap { [$0.name, $0.title] })
                .compactMap { $0 }.joined(separator: " ").lowercased()
            return words.allSatisfy { word in
                if word.hasPrefix("@"), word.count > 1 { return (row.machine ?? "").lowercased().contains(word.dropFirst()) }
                return text.contains(word)
            }
        }
    }

    /// The words the phone shows for a status, such as `needs you` for `needsYou`.
    static func statusWords(_ status: String?) -> String? {
        switch status {
        case "needsYou": "needs you"
        case "waiting": "on hold"
        default: status
        }
    }
}

/// A session's place in a tree of sessions on hold: each awaited session nested under the session
/// waiting for it, as the Mac's sidebar draws it.
public struct QueueTree: Codable, Equatable, Sendable {
    /// 0 for the session at the top of the tree, one more for each level under it.
    public let depth: Int
    /// For each level between the top and this session, whether a line passes by.
    public let guides: [Bool]
    /// The last session nested under its parent ends the parent's line.
    public let isLast: Bool
    /// How many sessions are nested directly under this one.
    public let nested: Int

    public init(depth: Int, guides: [Bool], isLast: Bool, nested: Int) {
        self.depth = depth
        self.guides = guides
        self.isLast = isLast
        self.nested = nested
    }
}

public struct RemotePane: Codable, Equatable, Sendable, Identifiable {
    public let pane: RemoteSessionID
    /// The agent's name and kind, or the shell's title.
    public let title: String
    public let isAgent: Bool
    public var id: String { pane.terminalID }

    public init(pane: RemoteSessionID, title: String, isAgent: Bool) {
        self.pane = pane
        self.title = title
        self.isAgent = isAgent
    }
}

/// A terminal frame as a binary WebSocket message: a 9-byte header (channel, flags, columns, rows,
/// big endian) and then Herdr's ANSI bytes.
public struct RemoteFrame: Equatable, Sendable {
    public let channel: Int
    /// The frame repaints the whole screen.
    public let isFull: Bool
    public let columns: Int
    public let rows: Int
    public let bytes: Data

    public init(channel: Int, isFull: Bool, columns: Int, rows: Int, bytes: Data) {
        self.channel = channel
        self.isFull = isFull
        self.columns = columns
        self.rows = rows
        self.bytes = bytes
    }

    public func encoded() -> Data {
        var data = Data(capacity: 9 + bytes.count)
        let channel = UInt32(truncatingIfNeeded: channel)
        data.append(contentsOf: [UInt8(channel >> 24), UInt8(channel >> 16 & 0xFF), UInt8(channel >> 8 & 0xFF), UInt8(channel & 0xFF)])
        data.append(isFull ? 1 : 0)
        let columns = UInt16(clamping: columns), rows = UInt16(clamping: rows)
        data.append(contentsOf: [UInt8(columns >> 8), UInt8(columns & 0xFF), UInt8(rows >> 8), UInt8(rows & 0xFF)])
        data.append(bytes)
        return data
    }

    public init?(decoding data: Data) {
        let header = [UInt8](data.prefix(9))
        guard header.count == 9 else { return nil }
        channel = Int(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
        isFull = header[4] & 1 == 1
        columns = Int(UInt16(header[5]) << 8 | UInt16(header[6]))
        rows = Int(UInt16(header[7]) << 8 | UInt16(header[8]))
        bytes = data.dropFirst(9)
    }
}
