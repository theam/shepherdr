import Foundation

/// Keeps holds about sessions that are still there: a session that closed, from Shepherdr or
/// elsewhere, no longer waits, and nothing waits for it.
public enum HoldUpkeep {
    /// How long a session must be missing from its machine's snapshots before holds forget it: one
    /// just started on another machine may not be in the last snapshot yet.
    public static let grace: TimeInterval = 30

    /// The sessions among `ids` that their machine, answering, has stopped reporting for at least
    /// `grace`. `missingSince` remembers when each was first missing. A machine that doesn't answer,
    /// or isn't known, says nothing about its sessions.
    public static func gone(_ ids: Set<Agent.ID>, machines: [MachineState], missingSince: inout [Agent.ID: Date],
                            now: Date = Date()) -> [Agent.ID] {
        missingSince = missingSince.filter { ids.contains($0.key) }
        var gone: [Agent.ID] = []
        for id in ids {
            guard let state = machines.first(where: { $0.id == id.machineID }), state.connection == .online,
                  let snapshot = state.snapshot else { continue }
            if snapshot.panes.contains(where: { $0.terminalID == id.terminalID }) || snapshot.agents.contains(where: { $0.id == id }) {
                missingSince[id] = nil
                continue
            }
            let since = missingSince[id] ?? now
            missingSince[id] = since
            if now.timeIntervalSince(since) >= grace { gone.append(id) }
        }
        return gone.sorted { ($0.machineID, $0.terminalID) < ($1.machineID, $1.terminalID) }
    }
}

/// A shell another session waits for, as Shepherdr has seen it. A shell has no agent to hand its work back, so the session waits for the command it
/// runs, such as a script: the hold ends once that command is back at the shell's prompt.
public struct ShellRun: Equatable, Sendable {
    /// What it was doing when last seen.
    public private(set) var activity: ShellActivity = .atPrompt
    /// What it showed above its prompt line when first seen at its prompt. If that changes while it
    /// is at its prompt, a command ran and finished between two looks.
    private var printed: String?

    public init() {}

    /// Takes in a look at the shell: whether it runs a command, and if it doesn't, its last lines.
    /// A command seen running and back at the prompt is for the hold to tell; one that ran between
    /// two looks shows as finished here.
    @discardableResult
    public mutating func see(running: Bool, output: String?) -> ShellActivity {
        if running {
            activity = .running
            return activity
        }
        if activity == .running { activity = .atPrompt }
        // Typing at the prompt only changes its last line.
        guard let output else { return activity }
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if !lines.isEmpty { lines.removeLast() }
        let above = lines.joined(separator: "\n")
        if let printed, above != printed { activity = .finished }
        printed = above
        return activity
    }
}

/// Holds as tokens on the waiting session's pane in Herdr, from where a Mac without them, such as
/// a new one, gets them back. Each hold is its phase's letter and the awaited terminal, with its
/// machine when that isn't the waiting session's: `pterm_1,fterm_2@remote:devbox`. Herdr keeps 80
/// characters a token, so they spread over `shepherdr-waits`, `shepherdr-waits-2` and on.
public enum HoldTokens {
    public static let key = "shepherdr-waits"
    /// Herdr keeps 32 tokens a pane, shared with other tools: holds take a few at most.
    public static let chunks = 6
    static let length = 80

    public static func key(_ chunk: Int) -> String { chunk == 0 ? key : "\(key)-\(chunk + 1)" }
    public static var keys: [String] { (0..<chunks).map(key) }

    /// Each chunk's value, in order. Holds that don't fit are left out of Herdr's copy.
    public static func encode(_ holds: [Hold], waiter: Agent.ID) -> [String] {
        var values: [String] = []
        var current = ""
        for hold in holds {
            let machine = hold.awaited.machineID == waiter.machineID ? "" : "@\(hold.awaited.machineID)"
            let entry = "\(letter(hold.phase))\(hold.awaited.terminalID)\(machine)"
            guard entry.count <= length else { continue }
            if current.isEmpty { current = entry; continue }
            if current.count + 1 + entry.count <= length { current += ",\(entry)"; continue }
            values.append(current)
            current = entry
            if values.count == chunks { return values }
        }
        if !current.isEmpty { values.append(current) }
        return values
    }

    /// The holds a pane's tokens record, in order; nil when it has none.
    public static func decode(_ tokens: [String: String], waiter: Agent.ID) -> [Hold]? {
        let values = (0..<chunks).map { tokens[key($0)] ?? "" }
        guard values.contains(where: { !$0.isEmpty }) else { return nil }
        return values.flatMap { $0.split(separator: ",") }.compactMap { entry -> Hold? in
            guard let phase = phase(entry.first) else { return nil }
            let parts = entry.dropFirst().split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let terminal = parts.first, !terminal.isEmpty, parts.count == 1 || !parts[1].isEmpty else { return nil }
            return Hold(awaited: Agent.ID(machineID: parts.count == 2 ? parts[1] : waiter.machineID, terminalID: terminal),
                        phase: phase)
        }
    }

    /// The chunks a pane's tokens hold now, to compare with `encode`'s.
    public static func values(in tokens: [String: String]) -> [String] {
        Array((0..<chunks).map { tokens[key($0)] ?? "" }.reversed().drop { $0.isEmpty }.reversed())
    }

    private static func letter(_ phase: HoldPhase) -> Character {
        switch phase {
        case .pending: "p"
        case .started: "s"
        case .finished: "f"
        }
    }

    private static func phase(_ letter: Character?) -> HoldPhase? {
        switch letter {
        case "p": .pending
        case "s": .started
        case "f": .finished
        default: nil
        }
    }
}
