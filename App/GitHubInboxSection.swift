import AppKit
import SwiftUI
import ShepherdrCore

/// The home screen's GitHub inbox: what the followed repositories ask of you, in a column per
/// kind, eight of each until you ask for more, or with the pull requests in a suggested order.
/// Clicking one opens it in the default browser and marks it seen.
struct GitHubInboxSection: View {
    @Bindable var model: AppModel
    private static let shown = 8
    @ViewState private var expanded = Set<GitHubInboxItem.Kind>()
    @AppStorage("suggestsPullRequestOrder") private var suggestsOrder = false

    private var monitor: GitHubInboxMonitor { model.inboxMonitor }
    private var store: GitHubInboxStore { model.githubInbox }
    /// The kinds in the order their columns show.
    private static let kinds: [GitHubInboxItem.Kind] = [.reviewRequested, .assignedIssue, .myPullRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
        }
        .task { await monitor.syncIfNeeded() }
        // Following, pausing or dropping a repository asks again right away.
        .onChange(of: store.activeRepositories) { Task { await monitor.sync() } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Once a minute is enough for "synced 3m ago".
            TimelineView(.everyMinute) { context in
                ConsoleHeader(title: "GitHub Inbox", trailing: trailing(now: context.date))
            }
            Toggle("SUGGEST ORDER", isOn: $suggestsOrder)
                .toggleStyle(ConsoleCheckboxStyle())
                .help("List your pull requests and reviews in the order to take them on: merge what's ready, review "
                      + "others' (ready, small and old ones first), then fix yours. Stacked pull requests go after their base.")
            Button("SYNC") { Task { await monitor.sync() } }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .disabled(monitor.isSyncing || store.activeRepositories.isEmpty)
                .help("Ask GitHub again now")
            Button("REPOS…") { model.showsGitHubRepositoriesSheet = true }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .help("Choose the repositories this inbox follows")
        }
    }

    private func trailing(now: Date) -> String? {
        if monitor.isSyncing { return "syncing…" }
        guard let inbox = monitor.inbox else { return store.activeRepositories.isEmpty ? nil : "never synced" }
        let synced = "synced \(Self.age(of: inbox.syncedAt, now: now))"
        return inbox.viewer.isEmpty ? synced : "@\(inbox.viewer) · \(synced)"
    }

    @ViewBuilder private var content: some View {
        if store.activeRepositories.isEmpty {
            message(store.repositories.isEmpty
                    ? "No repositories followed yet. Press REPOS… to add the ones whose issues and pull requests you want here."
                    : "Every followed repository is paused. Press REPOS… to resume one.")
        } else if let inbox = monitor.inbox {
            if let error = monitor.error {
                Text("! last sync failed: \(error.notice.title.lowercased()) · showing data from \(Self.age(of: inbox.syncedAt, now: Date()))")
                    .font(Theme.mono(10)).foregroundStyle(Theme.amber).lineLimit(1).truncationMode(.tail)
                    .help([error.notice.message, error.notice.detail].compactMap { $0 }.joined(separator: "\n"))
            }
            columns(inbox.items.filter { store.activeRepositories.contains($0.repository) })
        } else if let error = monitor.error {
            let notice = error.notice
            NoticeView(title: notice.title, message: notice.message, detail: notice.detail)
        } else {
            message("Asking GitHub…")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    /// In suggested order, the pull requests leave their columns for one ordered list.
    @ViewBuilder private func columns(_ items: [GitHubInboxItem]) -> some View {
        let steps = suggestsOrder ? PullRequestOrder.steps(for: items, checks: monitor.checks) : []
        let kinds = Self.kinds.filter { kind in (!suggestsOrder || kind == .assignedIssue) && items.contains { $0.kind == kind } }
        if kinds.isEmpty && steps.isEmpty {
            message("Nothing waiting for you in the followed repositories.")
        } else {
            if !steps.isEmpty { order(steps) }
            if !kinds.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)], spacing: 10) {
                    ForEach(kinds, id: \.self) { kind in column(kind, items.filter { $0.kind == kind }) }
                }
            }
        }
    }

    private func order(_ steps: [PullRequestStep]) -> some View {
        let unseen = store.unseen(steps.map(\.item)).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("SUGGESTED ORDER").font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
                Text(unseen > 0 ? "\(unseen) new · \(steps.count)" : "\(steps.count)")
                    .font(Theme.mono(9)).foregroundStyle(unseen > 0 ? Theme.phosphor : Theme.faint)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in row(step.item, place: (index + 1, step)) }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func column(_ kind: GitHubInboxItem.Kind, _ items: [GitHubInboxItem]) -> some View {
        let isExpanded = expanded.contains(kind)
        let unseen = store.unseen(items).count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(Self.title(kind)).font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
                Text(unseen > 0 ? "\(unseen) new · \(items.count)" : "\(items.count)")
                    .font(Theme.mono(9)).foregroundStyle(unseen > 0 ? Theme.phosphor : Theme.faint)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
            ForEach(isExpanded ? items : Array(items.prefix(Self.shown))) { item in row(item) }
            if items.count > Self.shown {
                Button {
                    if isExpanded { expanded.remove(kind) } else { expanded.insert(kind) }
                } label: {
                    Text(isExpanded ? "▴ fewer" : "▾ \(items.count - Self.shown) more")
                        .font(Theme.mono(9.5)).foregroundStyle(Theme.dim)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line, lineWidth: 1))
    }

    /// In suggested order, a row leads with its place and what to do, and says why under its title.
    private func row(_ item: GitHubInboxItem, place: (number: Int, step: PullRequestStep)? = nil) -> some View {
        let isUnseen = store.isUnseen(item)
        return Button { open(item) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let place {
                    Text("\(place.number)").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                        .frame(width: 18, alignment: .trailing)
                    Text(Self.label(place.step.action)).font(Theme.mono(9.5, .bold))
                        .foregroundStyle(Self.tint(place.step.action)).frame(width: 54, alignment: .leading)
                }
                Text(Self.glyph(item.kind)).font(Theme.mono(10.5, .bold))
                    .foregroundStyle(Self.tint(item.kind)).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("\(item.repository.displayName)#\(item.number)").font(Theme.mono(11, .medium))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(isUnseen ? Theme.text : Theme.text.opacity(0.7))
                        if item.isPullRequest {
                            ChecksMark(state: monitor.checks[item.key]?.state).font(Theme.mono(10, .bold))
                        }
                        if let badge = Self.badge(item) {
                            Text(badge.label).font(Theme.mono(9, .semibold)).foregroundStyle(badge.color)
                        }
                        if let linked = Self.linkedBadge(item) {
                            Text(linked.label).font(Theme.mono(9, .semibold)).foregroundStyle(linked.color)
                        }
                    }
                    Text(item.title).font(Theme.mono(9.5)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.tail)
                    if let place {
                        Text(place.step.reasons.joined(separator: " · ")).font(Theme.mono(9)).foregroundStyle(Theme.faint)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer(minLength: 4)
                Text(Self.age(of: item.updatedAt, now: Date())).font(Theme.mono(9)).foregroundStyle(Theme.faint)
                Rectangle().fill(Theme.phosphor).frame(width: 6, height: 6)
                    .opacity(isUnseen ? 1 : 0)
                    .accessibilityLabel(isUnseen ? "Unseen" : "")
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(for: item, step: place?.step))
        .contextMenu {
            Button("Open in Default Browser") { open(item) }
            Button("Copy Link") { copyToPasteboard(item.url.absoluteString) }
            Divider()
            if isUnseen {
                Button("Mark as Seen") { store.markSeen(item) }
            } else {
                Button("Mark as Unseen") { store.markUnseen(item) }
            }
        }
    }

    private func open(_ item: GitHubInboxItem) {
        NSWorkspace.shared.open(item.url)
        store.markSeen(item)
    }

    private func help(for item: GitHubInboxItem, step: PullRequestStep? = nil) -> String {
        var lines = [item.title, "by @\(item.author) · updated \(item.updatedAt.formatted(date: .abbreviated, time: .shortened))"]
        if let step { lines.append("\(Self.label(step.action)): \(Self.meaning(step.action)) (\(step.reasons.joined(separator: ", ")))") }
        if let badge = Self.badge(item) { lines.append(badge.help) }
        if let checks = monitor.checks[item.key], !checks.summary.isEmpty { lines.append("Checks: \(checks.summary)") }
        if !item.linkedPullRequests.isEmpty {
            let pulls = item.linkedPullRequests.map { pull in
                let state = pull.isOpen ? (pull.isDraft ? " (draft)" : "") : " (closed)"
                return "#\(pull.number)\(state)"
            }
            lines.append("Linked pull request\(pulls.count == 1 ? "" : "s"): \(pulls.joined(separator: ", "))")
        }
        lines.append(item.url.absoluteString)
        return lines.joined(separator: "\n")
    }

    private static func title(_ kind: GitHubInboxItem.Kind) -> String {
        switch kind {
        case .reviewRequested: "REVIEW REQUESTED"
        case .assignedIssue: "ASSIGNED ISSUES"
        case .myPullRequest: "YOUR PULL REQUESTS"
        }
    }

    private static func glyph(_ kind: GitHubInboxItem.Kind) -> String {
        switch kind {
        case .reviewRequested: "◇"
        case .assignedIssue: "◉"
        case .myPullRequest: "⇄"
        }
    }

    private static func tint(_ kind: GitHubInboxItem.Kind) -> Color {
        switch kind {
        case .reviewRequested: Theme.phosphor
        case .assignedIssue: Theme.amber
        case .myPullRequest: Theme.cyan
        }
    }

    private static func label(_ action: PullRequestStep.Action) -> String {
        switch action {
        case .merge: "MERGE"
        case .review: "REVIEW"
        case .address: "ADDRESS"
        case .resolve: "RESOLVE"
        case .fix: "FIX"
        case .finish: "FINISH"
        case .wait: "WAIT"
        }
    }

    /// Go in green, review in plain text, your own trouble in amber or red, and what can wait dimmed.
    private static func tint(_ action: PullRequestStep.Action) -> Color {
        switch action {
        case .merge: Theme.phosphor
        case .review: Theme.text
        case .address, .resolve: Theme.amber
        case .fix: Theme.red
        case .finish: Theme.dim
        case .wait: Theme.faint
        }
    }

    private static func meaning(_ action: PullRequestStep.Action) -> String {
        switch action {
        case .merge: "approved and green, merge it"
        case .review: "someone waits on your review"
        case .address: "answer the changes a reviewer asked for"
        case .resolve: "update it with its base branch"
        case .fix: "make its checks pass"
        case .finish: "finish the draft"
        case .wait: "nothing to do yet"
        }
    }

    /// A pull request's draft or review state, when there is one worth showing.
    private static func badge(_ item: GitHubInboxItem) -> (label: String, color: Color, help: String)? {
        guard item.isPullRequest else { return nil }
        if item.isDraft { return ("DRAFT", Theme.faint, "Draft pull request") }
        switch item.reviewDecision {
        case "APPROVED": return ("APPROVED", Theme.phosphor, "Approved")
        case "CHANGES_REQUESTED": return ("CHANGES", Theme.red, "Changes requested")
        case "REVIEW_REQUIRED": return ("REVIEW", Theme.amber, "Review required")
        default: return nil
        }
    }

    /// The pull requests linked to an issue, in cyan like your own: dimmed once none is open.
    private static func linkedBadge(_ item: GitHubInboxItem) -> (label: String, color: Color)? {
        let linked = item.linkedPullRequests
        guard !item.isPullRequest, let first = linked.first else { return nil }
        let label = linked.count == 1 ? "⇄ PR #\(first.number)" : "⇄ \(linked.count) PRs"
        return (label, linked.contains(where: \.isOpen) ? Theme.cyan : Theme.cyan.opacity(0.5))
    }

    /// `now`, `5m ago`, `3h ago`, `2d ago`.
    static func age(of date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(seconds / 60)m ago"
        case ..<86_400: return "\(seconds / 3_600)h ago"
        default: return "\(seconds / 86_400)d ago"
        }
    }
}
