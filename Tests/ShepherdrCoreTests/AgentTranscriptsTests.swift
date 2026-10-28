import Foundation
import Testing
@testable import ShepherdrCore

struct AgentTranscriptsTests {
    private func home(_ files: [String: [String]]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appending(path: "transcripts-\(UUID().uuidString)")
        for (path, lines) in files {
            let file = home.appending(path: path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
        return home
    }

    @Test func claudeReadsTheLastModelAndEffortOfItsFolder() throws {
        let home = try home([".claude/projects/-Users-me-Code-my-app/a.jsonl": [
            #"{"type":"assistant","message":{"model":"claude-opus-5-5"},"effort":"low"}"#,
            #"{"type":"user"}"#,
            #"{"type":"assistant","message":{"model":"claude-sonnet-5-5"},"effort":"high"}"#,
            #"{"type":"system"}"#]])
        let info = try #require(AgentTranscripts(home: home).claude(directory: "/Users/me/Code/my.app"))
        #expect(info == AgentRunInfo(model: "claude-sonnet-5-5", effort: "high"))
        #expect(info.modelTitle == "Sonnet 5.5")
        #expect(AgentTranscripts(home: home).claude(directory: "/elsewhere") == nil)
    }

    @Test func codexFindsItsRolloutByFolderAndReadsTheLimits() throws {
        let future = Int(Date.now.timeIntervalSince1970) + 3600
        let limits = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":6.0,"resets_at":\#(future)},"secondary":{"used_percent":11.0,"resets_at":\#(future)}}}}"#
        let home = try home(["/.codex/sessions/2026/10/22/rollout-a.jsonl": [
            #"{"type":"session_meta","payload":{"cwd":"/work/one"}}"#,
            #"{"type":"turn_context","payload":{"cwd":"/work/one","model":"gpt-6.1-sol","effort":"medium"}}"#, limits]])
        let transcripts = AgentTranscripts(home: home)
        #expect(transcripts.codex(directory: "/work/one") == AgentRunInfo(model: "gpt-6.1-sol", effort: "medium"))
        #expect(transcripts.codex(directory: "/work/two") == nil)
        #expect(transcripts.codexUsage()?.session?.percent == 6)
        #expect(transcripts.codexUsage()?.week?.percent == 11)
        // A limit that has started again is no longer known.
        #expect(transcripts.codexUsage(now: .now.addingTimeInterval(7200)) == nil)
    }

    @Test func namesModelsPlainly() {
        #expect(AgentRunInfo(model: "claude-opus-5-5-20261001", effort: nil).modelTitle == "Opus 5.5")
        #expect(AgentRunInfo(model: "claude-haiku-5-5", effort: nil).modelTitle == "Haiku 5.5")
        #expect(AgentRunInfo(model: "gpt-6.1-sol", effort: nil).modelTitle == "gpt-6.1-sol")
    }
}
