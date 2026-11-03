import ShepherdrRemote
import SwiftUI

/// One session: a pane of its Herdr tab at a time, fitted to the phone, with keys and a composer
/// for prompts you type or dictate.
struct SessionScreen: View {
    @Bindable var client: RelayClient
    let link: SessionLink
    @State private var paneID: String?
    @State private var draft = ""
    @State private var dictation = Dictation()
    @FocusState private var composing: Bool
    @State private var showsResources = false
    @AppStorage("terminalFontSize") private var fontSize = 11.0

    /// The row as the queue shows it now, which may have gained or lost panes; Compass's agent is
    /// outside the queue.
    private var row: QueueRow {
        client.queue?.rows.first { $0.session == link.session }
            ?? client.queue?.compass?.agent.flatMap { $0.session == link.session ? $0 : nil }
            ?? link.row
    }

    private var panes: [RemotePane] {
        row.panes.isEmpty ? [RemotePane(pane: link.session, title: row.title, isAgent: row.kind == .session)] : row.panes
    }

    private var pane: RemotePane {
        panes.first { $0.id == paneID } ?? panes.first { $0.pane == link.session } ?? panes[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            if panes.count > 1 {
                Picker("Pane", selection: Binding(get: { pane.id }, set: { paneID = $0 })) {
                    ForEach(panes) { pane in Text(pane.title).tag(pane.id) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            TerminalPanel(client: client, pane: pane.pane, fontSize: fontSize)
                .id(pane.id)
            keys
            composer
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(row.title).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text([Theme.label(forStatus: row.status), row.machine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(Theme.mono(9.5)).foregroundStyle(Theme.color(forStatus: row.status))
                }
            }
            if !row.resources.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsResources = true } label: { Image(systemName: "list.bullet") }
                        .accessibilityLabel("Resources")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Larger Text", systemImage: "textformat.size.larger") { fontSize = min(18, fontSize + 1) }
                    Button("Smaller Text", systemImage: "textformat.size.smaller") { fontSize = max(7, fontSize - 1) }
                } label: { Image(systemName: "textformat.size") }
            }
        }
        .sheet(isPresented: $showsResources) { ResourcesSheet(title: row.title, resources: row.resources) }
        .alert("Shepherdr", isPresented: Binding(get: { client.notice != nil }, set: { if !$0 { client.notice = nil } })) {
            Button("OK") { client.notice = nil }
        } message: { Text(client.notice ?? "") }
    }

    // MARK: Keys

    private var keys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                key("esc", [27])
                key("⇧⏎", [27, 13])
                key("↑", Array("\u{1b}[A".utf8))
                key("↓", Array("\u{1b}[B".utf8))
                key("←", Array("\u{1b}[D".utf8))
                key("→", Array("\u{1b}[C".utf8))
                key("tab", [9])
                key("^C", [3])
                key("1", Array("1".utf8))
                key("2", Array("2".utf8))
                key("3", Array("3".utf8))
                key("⏎", [13])
                scroll("⇞", up: true)
                scroll("⇟", up: false)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Theme.panel)
    }

    private func key(_ label: String, _ bytes: [UInt8]) -> some View {
        Button { TerminalPanel.send(Data(bytes), to: pane.pane) } label: {
            Text(label).font(Theme.mono(12, .medium)).frame(minWidth: 30).padding(.vertical, 5).padding(.horizontal, 4)
        }
        .buttonStyle(.bordered).tint(Theme.dim)
    }

    private func scroll(_ label: String, up: Bool) -> some View {
        Button { TerminalPanel.scroll(up: up, in: pane.pane) } label: {
            Text(label).font(Theme.mono(12, .medium)).frame(minWidth: 30).padding(.vertical, 5).padding(.horizontal, 4)
        }
        .buttonStyle(.bordered).tint(Theme.dim)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .failed(let message) = dictation.state {
                Text(message).font(.caption).foregroundStyle(Theme.amber)
            }
            if case .preparing(let message) = dictation.state {
                Text(message).font(.caption).foregroundStyle(Theme.dim)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    TextField("Prompt for \(pane.title)…", text: $draft, axis: .vertical)
                        .font(Theme.mono(13)).lineLimit(1...6)
                        .focused($composing)
                    if dictation.isRecording, !dictation.volatile.isEmpty {
                        Text(draft.isEmpty ? dictation.volatile : "")
                            .font(Theme.mono(13)).foregroundStyle(Theme.dim).allowsHitTesting(false)
                    }
                }
                .padding(8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                Button { toggleDictation() } label: {
                    Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                        .font(.system(size: 20)).foregroundStyle(dictation.isRecording ? Theme.red : Theme.amber)
                        .frame(width: 36, height: 36)
                }
                Button { send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Theme.faint : Theme.phosphor)
                        .frame(width: 36, height: 36)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if dictation.isRecording {
                Text(dictation.volatile.isEmpty ? "Listening…" : dictation.volatile)
                    .font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(3)
            }
        }
        .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
        .background(Theme.panel)
    }

    private func toggleDictation() {
        if dictation.isRecording {
            Task {
                let text = await dictation.stop()
                guard !text.isEmpty else { return }
                let separator = draft.isEmpty || draft.hasSuffix(" ") || draft.hasSuffix("\n") ? "" : " "
                draft += separator + text
            }
        } else {
            Task { await dictation.start() }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.prompt(text, into: pane.pane)
        draft = ""
        composing = false
    }
}

/// A session's resources, as the Mac's Resources column lists them: tap one to open it in Safari.
struct ResourcesSheet: View {
    let title: String
    let resources: [RemoteResource]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                ForEach(RemoteResource.Kind.allCases, id: \.self) { kind in
                    let items = resources.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Section(Self.title(of: kind)) {
                            ForEach(items) { resource in
                                Button { if let url = URL(string: resource.url) { openURL(url) } } label: {
                                    ResourceRow(resource: resource)
                                }
                                .contextMenu {
                                    Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = resource.url }
                                }
                                .listRowBackground(Theme.panel)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    static func title(of kind: RemoteResource.Kind) -> String {
        switch kind {
        case .pullRequest: "Pull requests"
        case .issue: "Issues"
        case .artifact: "Claude artifacts"
        case .link: "Links"
        case .repository: "Repository"
        }
    }
}

private struct ResourceRow: View {
    let resource: RemoteResource

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(glyph).font(Theme.mono(12)).foregroundStyle(Theme.cyan).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(resource.name).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                    if let state = resource.state, state != "open" {
                        Text(state).font(Theme.mono(10)).foregroundStyle(state == "merged" ? Theme.lilac : Theme.dim)
                    }
                    if let mark = ResourceLabel.checksMark(resource) { mark }
                }
                Text(resource.title ?? URL(string: resource.url)?.host() ?? resource.url)
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var glyph: String {
        switch resource.kind {
        case .pullRequest: "⇄"
        case .issue: "◎"
        case .artifact: "◆"
        case .link: "↗"
        case .repository: "▣"
        }
    }
}
