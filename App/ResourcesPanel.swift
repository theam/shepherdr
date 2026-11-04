import AppKit
import SwiftUI
import ShepherdrCore

/// The links a session has produced, at hand: pull requests, issues and Claude artifacts, the most
/// mentioned and opened first, ten of each until you ask for more. Clicking one opens it in the
/// session's browser.
struct ResourcesPanel: View {
    let workspace: SessionWorkspace
    let checks: ChecksMonitor
    /// Hides the panel; the header's resources button brings it back.
    let close: () -> Void
    /// Reads the session again: drops what it no longer mentions and updates the rest.
    let refresh: () async -> Void
    private static let shown = 10
    @ViewState private var expanded = Set<SessionResource.Kind>()
    @ViewState private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                ConsoleHeader(title: "Resources", trailing: "\(workspace.visibleResources.count)")
                Button {
                    isRefreshing = true
                    Task { await refresh(); isRefreshing = false }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 14, height: 14).contentShape(Rectangle()).opacity(isRefreshing ? 0.4 : 1)
                }
                .buttonStyle(.plain).disabled(isRefreshing)
                .help("Refresh: drop what the session no longer mentions and update the rest")
                .accessibilityLabel("Refresh Resources")
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Resources")
                .accessibilityLabel("Close Resources")
            }
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
    }

    private func row(_ resource: SessionResource) -> some View {
        let isOpen = workspace.browser.isVisible && workspace.browser.selected?.url == resource.url
        return Button { workspace.open(resource) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                ResourceIcon(look: ResourceIcon.look(of: resource, outcome: checks.outcome(of: resource),
                                                     issue: checks.issues[resource.key]))
                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
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
