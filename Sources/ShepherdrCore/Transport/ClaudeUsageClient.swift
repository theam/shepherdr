import Foundation

/// Asks Anthropic how much of this Mac's Claude subscription is used. It signs in as Claude Code does:
/// with the token Claude Code keeps in the login keychain, read through `security` and sent to Anthropic
/// only. The endpoint is not documented, so every failure just means "no data".
public struct ClaudeUsageClient: Sendable {
    public init() {}

    public func fetch() async -> SubscriptionUsage? {
        guard let token = await token() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return SubscriptionUsage.parse(data)
    }

    private func token() async -> String? {
        let security = URL(fileURLWithPath: "/usr/bin/security")
        guard let output = try? await ProcessRunner().run(
            executable: security, arguments: ["find-generic-password", "-s", "Claude Code-credentials", "-w"], timeout: 10),
              output.exitCode == 0,
              let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}
