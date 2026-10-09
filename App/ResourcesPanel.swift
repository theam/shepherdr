import AppKit
import SwiftUI
import ShepherdrCore

/// The links a session has produced, at hand: pull requests, issues and Claude artifacts, the most
/// mentioned and opened first, ten of each until you ask for more. Clicking one opens it in the
/// session's browser.
struct ResourcesPanel: View {
    let workspace: SessionWorkspace
    let checks: ChecksMonitor
    private static let shown = 10
    @ViewState private var expanded = Set<SessionResource.Kind>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ConsoleHeader(title: "Resources", trailing: "\(workspace.visibleResources.count)")
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SessionResource.Kind.allCases, id: \.self) { kind in
                        let items = SessionResources.ranked(workspace.resources, kind: kind)
                        if !items.isEmpty {
                            let isExpanded = expanded.contains(kind)
                            Text(kind.title.uppercased()).font(Theme.mono(9, .semibold)).tracking(1)
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 3)
                            ForEach(isExpanded ? items : Array(items.prefix(Self.shown))) { resource in row(resource) }
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
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }

    private func row(_ resource: SessionResource) -> some View {
        let isOpen = workspace.browser.isVisible && workspace.browser.selected?.url == resource.url
        return Button { workspace.open(resource) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Self.glyph(resource.kind)).font(Theme.mono(10.5, .bold))
                    .foregroundStyle(tint(of: resource)).frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(resource.name).font(Theme.mono(11, .medium)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(isOpen ? Theme.text : Theme.text.opacity(0.82))
                        ChecksMark(state: checks.checks[resource.key]?.state).font(Theme.mono(10, .bold))
                    }
                    Text(resource.title ?? resource.url.host() ?? "").font(Theme.mono(9.5))
                        .foregroundStyle(resource.title == nil ? Theme.faint : Theme.dim).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(isOpen ? Theme.raised : .clear)
            .overlay(alignment: .leading) { Rectangle().fill(Theme.phosphor).frame(width: 2).opacity(isOpen ? 1 : 0) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help(for: resource))
        .contextMenu {
            Button("Open") { workspace.open(resource) }
            Button("Open in Default Browser") {
                NSWorkspace.shared.open(resource.url)
                workspace.countOpen(of: resource.url)
            }
            Button("Copy Link") { copyToPasteboard(resource.url.absoluteString) }
            Divider()
            Button("Remove") { workspace.remove(resource) }
        }
    }

    private func help(for resource: SessionResource) -> String {
        var lines: [String] = []
        if let title = resource.title { lines.append(title) }
        if let status = status(of: resource) { lines.append(status) }
        if let summary = checks.checks[resource.key]?.summary, !summary.isEmpty { lines.append("Checks: " + summary) }
        lines.append(resource.url.absoluteString)
        lines.append("Mentioned \(resource.mentions)× · opened \(resource.opens)×")
        return lines.joined(separator: "\n")
    }

    private static func glyph(_ kind: SessionResource.Kind) -> String {
        switch kind {
        case .pullRequest: "⇄"
        case .issue: "◎"
        case .artifact: "◆"
        }
    }

    /// Its kind's color while open; lilac once it landed, as GitHub marks merged pull requests and
    /// completed issues; dimmed once dropped.
    private func tint(of resource: SessionResource) -> Color {
        switch checks.outcome(of: resource) {
        case .landed: Theme.lilac
        case .dropped: Theme.dim
        case nil:
            switch resource.kind {
            case .pullRequest: Theme.phosphor
            case .issue: Theme.amber
            case .artifact: Theme.cyan
            }
        }
    }

    private func status(of resource: SessionResource) -> String? {
        if let pull = checks.checks[resource.key], !pull.isOpen { return pull.isMerged ? "Merged" : "Closed without merging" }
        return switch checks.issues[resource.key] {
        case .completed: "Closed as completed"
        case .notPlanned: "Closed as not planned"
        case .duplicate: "Closed as a duplicate"
        case .open, nil: nil
        }
    }
}
