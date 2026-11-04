import Foundation

/// The model and reasoning effort a session's agent runs with right now.
public struct AgentRunInfo: Equatable, Sendable {
    public let model: String?
    public let effort: String?

    public init(model: String?, effort: String?) {
        self.model = model
        self.effort = effort
    }

    /// `claude-sonnet-5-5` as "Sonnet 5.5"; other names as they are.
    public var modelTitle: String? {
        guard let model else { return nil }
        guard model.hasPrefix("claude-") else { return model }
        let parts: [String] = model.dropFirst("claude-".count).split(separator: "-").map(String.init)
            .filter { !($0.count == 8 && $0.allSatisfy(\.isNumber)) }
        let family = parts.prefix { !$0.allSatisfy(\.isNumber) }.joined(separator: " ").capitalized
        let version = parts.drop { !$0.allSatisfy(\.isNumber) }.joined(separator: ".")
        return [family, version].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Reads what Claude Code and Codex keep on this Mac about their sessions: Claude Code's transcripts
/// in `~/.claude/projects` and Codex's rollouts in `~/.codex/sessions`. A session is found by the
/// folder it works in, taking the one that wrote last, so two agents in one folder can be mixed up.
public struct AgentTranscripts: Sendable {
    private let home: URL
    /// How much of the end of a file is read: its last lines hold the current model and limits.
    private static let tail = 1_000_000

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    /// The model and effort of the Claude Code session working in `directory`.
    public func claude(directory: String) -> AgentRunInfo? {
        // Claude Code names a project's folder after its path, every other character turned into "-".
        let name = String(directory.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let folder = home.appending(path: ".claude/projects/\(name)")
        guard let file = newest(in: folder, matching: { $0.pathExtension == "jsonl" }) else { return nil }
        for line in lastLines(of: file).reversed() {
            guard let object = Self.object(line), object["type"] as? String == "assistant",
                  let model = (object["message"] as? [String: Any])?["model"] as? String, model.hasPrefix("claude") else { continue }
            return AgentRunInfo(model: model, effort: object["effort"] as? String ?? object["perTurnEffort"] as? String)
        }
        return nil
    }

    /// The model and effort of the Codex session working in `directory`.
    public func codex(directory: String) -> AgentRunInfo? {
        for file in codexRollouts().prefix(60) where Self.directory(of: file) == directory {
            for line in lastLines(of: file).reversed() {
                guard let object = Self.object(line), object["type"] as? String == "turn_context",
                      let payload = object["payload"] as? [String: Any], let model = payload["model"] as? String else { continue }
                return AgentRunInfo(model: model, effort: payload["effort"] as? String)
            }
        }
        return nil
    }

    /// The Codex account's limits as its latest session saw them. A limit that has started again since
    /// is left out: what it showed no longer holds.
    public func codexUsage(now: Date = .now) -> SubscriptionUsage? {
        for file in codexRollouts().prefix(20) {
            for line in lastLines(of: file).reversed() {
                guard let object = Self.object(line), let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count", let limits = payload["rate_limits"] as? [String: Any] else { continue }
                func window(_ key: String) -> SubscriptionUsage.Window? {
                    guard let found = limits[key] as? [String: Any], let used = (found["used_percent"] as? NSNumber)?.doubleValue,
                          let reset = (found["resets_at"] as? NSNumber)?.doubleValue else { return nil }
                    let date = Date(timeIntervalSince1970: reset)
                    return date > now ? SubscriptionUsage.Window(utilization: used, resetsAt: date) : nil
                }
                let usage = SubscriptionUsage(session: window("primary"), week: window("secondary"))
                if usage.session != nil || usage.week != nil { return usage }
            }
        }
        return nil
    }

    // MARK: Files

    /// Codex's rollouts, the last written first. They live in a folder per day.
    private func codexRollouts() -> [URL] {
        let root = home.appending(path: ".codex/sessions")
        var found: [(URL, Date)] = []
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                                  options: [.skipsHiddenFiles])
        while let url = walk?.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl",
                  let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            found.append((url, date))
        }
        return found.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private func newest(in folder: URL, matching keep: (URL) -> Bool) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter(keep).max {
            let dates = [$0, $1].map { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            return dates[0] < dates[1]
        }
    }

    /// The folder a Codex rollout works in, from its first line.
    private static func directory(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file), let head = try? handle.read(upToCount: 262_144) else { return nil }
        try? handle.close()
        guard let end = head.firstIndex(of: 10), let object = object(head[..<end]) else { return nil }
        return (object["payload"] as? [String: Any])?["cwd"] as? String
    }

    /// The complete lines in the last part of a file.
    private func lastLines(of file: URL) -> [Data] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        let start = size > UInt64(Self.tail) ? size - UInt64(Self.tail) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: true).map { Data($0) }
        // Cut in the middle: its first line is partial.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    private static func object(_ line: some DataProtocol) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
    }
}
