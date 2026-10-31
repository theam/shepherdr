import Foundation

/// Web links Shepherdr hands to macOS instead of a session's browser. macOS opens them in the
/// default browser, where Slack's pages offer its app.
public enum ExternalLinks {
    /// Slack's workspaces, channels, messages and files, which belong in the Slack app. Its sign-in
    /// and authorization pages stay, so "Sign in with Slack" still works in a session's browser.
    public static func contains(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host()?.lowercased(), host == "slack.com" || host.hasSuffix(".slack.com") else { return false }
        let path = url.path().lowercased()
        return !["/oauth/", "/openid/"].contains { path.hasPrefix($0) }
    }
}
