import Observation
import ShepherdrCore

/// The subscriptions' usage. Claude's is asked of Anthropic every five minutes; Codex's is read every
/// minute from what its latest session saw. Without a login or a session on this Mac there is nothing to show.
@MainActor @Observable
final class SubscriptionMonitor {
    private(set) var claude: SubscriptionUsage?
    private(set) var codex: SubscriptionUsage?
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    func start() {
        guard loops.isEmpty else { return }
        loops = [
            Task { [weak self] in
                while !Task.isCancelled {
                    // Keeps the last answer when one fails: a figure a few minutes old beats none.
                    if let usage = await ClaudeUsageClient().fetch() { self?.claude = usage }
                    try? await Task.sleep(for: .seconds(300))
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    self?.codex = await Task.detached { AgentTranscripts().codexUsage() }.value
                    try? await Task.sleep(for: .seconds(60))
                }
            },
        ]
    }
}
