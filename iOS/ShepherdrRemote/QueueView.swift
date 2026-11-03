import ShepherdrRemote
import SwiftUI

/// The Mac's queue, in its order: groups, projects, sessions with the ones they wait for nested
/// under them, and shells. Searching narrows it to the sessions that match.
struct QueueView: View {
    @Bindable var client: RelayClient
    @State private var showsSettings = false
    @State private var query = ""

    /// The same margin for the header and every row.
    static let insets = EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 10)

    var body: some View {
        List {
            header
                .listRowInsets(EdgeInsets(top: 4, leading: Self.insets.leading, bottom: 8, trailing: Self.insets.trailing))
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
            if let queue = client.queue {
                let rows = QueueSearch.rows(queue.rows, matching: query)
                if let compass = queue.compass, query.isEmpty || "compass".contains(query.lowercased()) {
                    NavigationLink(value: CompassLink()) { CompassRowView(compass: compass) }
                        .listRowInsets(EdgeInsets(top: 0, leading: Self.insets.leading + 8, bottom: 0, trailing: Self.insets.trailing + 8))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 8).fill(Theme.panel)
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(compass.needsYou ? Theme.amber.opacity(0.6) : Theme.line))
                                .padding(.leading, Self.insets.leading - 4).padding(.trailing, Self.insets.trailing).padding(.bottom, 6)
                                .background(Theme.background))
                        .listRowSeparator(.hidden)
                }
                ForEach(rows) { row in
                    Group {
                        if let session = row.session {
                            NavigationLink(value: SessionLink(row: row, session: session)) {
                                QueueRowView(row: row, flat: !query.isEmpty)
                            }
                        } else {
                            HeadingView(row: row, flat: !query.isEmpty)
                        }
                    }
                    .listRowInsets(Self.insets)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
                }
                if rows.isEmpty, !query.isEmpty {
                    Text("No session matches “\(query)”.").font(Theme.mono(12)).foregroundStyle(Theme.dim)
                        .listRowInsets(Self.insets).listRowBackground(Theme.background).listRowSeparator(.hidden)
                }
            } else if client.phase == .connected || client.phase == .connecting {
                HStack { ProgressView(); Text("Waiting for the queue…").font(Theme.mono(12)).foregroundStyle(Theme.dim) }
                    .listRowInsets(Self.insets).listRowBackground(Theme.background).listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(for: SessionLink.self) { link in
            SessionScreen(client: client, link: link)
        }
        .navigationDestination(for: CompassLink.self) { _ in
            CompassScreen(client: client)
        }
        .sheet(isPresented: $showsSettings) { SettingsSheet(client: client) }
        .refreshable { client.start() }
    }

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SHEPHERDR").font(Theme.mono(13, .semibold)).foregroundStyle(Theme.phosphor).tracking(3)
                Spacer()
                Button { showsSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(Theme.dim)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(client.mac?.name ?? "Mac").font(Theme.mono(13, .medium)).foregroundStyle(Theme.text)
                Spacer()
                Text(phaseLabel).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            }
            if case .failed(let message) = client.phase {
                Text(message).font(.footnote).foregroundStyle(Theme.amber)
            }
            if let queue = client.queue {
                let sessions = queue.rows.filter { $0.kind == .session }
                HStack(spacing: 6) {
                    chip("\(sessions.filter { $0.status == "needsYou" }.count) need you", Theme.amber)
                    chip("\(sessions.filter { $0.status == "working" }.count) working", Theme.phosphor)
                    chip("\(sessions.count) sessions", Theme.dim)
                }
                if queue.machines.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(queue.machines) { machine in
                                chip(machine.name, machine.isOnline ? Theme.dim : Theme.red)
                            }
                        }
                    }
                }
                searchField
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Theme.faint)
            TextField("Search sessions", text: $query)
                .font(Theme.mono(13)).foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 2)
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.mono(11)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.4)))
    }

    private var dotColor: Color {
        switch client.phase {
        case .connected: Theme.phosphor
        case .connecting: Theme.amber
        case .failed: Theme.red
        case .idle: Theme.faint
        }
    }

    private var phaseLabel: String {
        switch client.phase {
        case .connected: "live"
        case .connecting: "connecting…"
        case .failed: "offline"
        case .idle: "paused"
        }
    }
}

struct CompassLink: Hashable {}

/// Compass at the top of the queue, as the Mac's COMPASS tab: what its agent is doing and when it
/// runs next.
struct CompassRowView: View {
    let compass: RemoteCompass

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("◈").font(Theme.mono(12)).foregroundStyle(Theme.phosphor).frame(width: QueueRowView.numberWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("COMPASS").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.text).tracking(2)
                    if compass.hasNews { Circle().fill(Theme.phosphor).frame(width: 6, height: 6) }
                }
                Text(compass.activity).font(Theme.mono(10.5)).foregroundStyle(CompassScreen.color(of: compass)).lineLimit(1)
                Text(compass.next).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.top, 8).padding(.bottom, 14)
    }
}

struct SessionLink: Hashable {
    let row: QueueRow
    let session: RemoteSessionID

    static func == (a: Self, b: Self) -> Bool { a.session == b.session }
    func hash(into hasher: inout Hasher) { hasher.combine(session) }

    /// `shepherdr-remote://session?m=<machine>&t=<terminal>` opens that session.
    static func session(from url: URL) -> RemoteSessionID? {
        guard url.scheme == PairingInvite.scheme, url.host == "session",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let machine = items.first(where: { $0.name == "m" })?.value,
              let terminal = items.first(where: { $0.name == "t" })?.value else { return nil }
        return RemoteSessionID(machineID: machine, terminalID: terminal)
    }
}

/// One session or shell, indented as deep as the Mac nests it.
struct QueueRowView: View {
    let row: QueueRow
    /// While searching, every row stands on its own.
    var flat = false

    static let indent: CGFloat = 14
    /// The number's column, as wide as two digits.
    static let numberWidth: CGFloat = 18

    private var depth: Int { flat ? 0 : row.depth }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(row.number.map(String.init) ?? (row.kind == .shell ? "$" : "·"))
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .frame(width: Self.numberWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let summary = row.summary, !summary.isEmpty {
                    Text(summary).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineLimit(2)
                }
                let detail = [row.agent, row.machine].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty || ResourceLabel.pulls(of: row) != nil {
                    HStack(spacing: 6) {
                        if !detail.isEmpty { Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1) }
                        if let pulls = ResourceLabel.pulls(of: row) { pulls }
                    }
                }
            }
            Spacer(minLength: 4)
            Text(Theme.label(forStatus: row.status)).font(Theme.mono(9.5, .semibold))
                .foregroundStyle(Theme.color(forStatus: row.status)).tracking(1)
        }
        .padding(.leading, CGFloat(depth) * Self.indent)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) {
            if !flat {
                Rails(row: row)
                if let tree = row.tree { TreeLines(tree: tree, depth: row.depth) }
            }
        }
    }
}

/// The lines down a group and a project, under their headings, as the Mac's sidebar draws them.
struct Rails: View {
    let row: QueueRow

    var body: some View {
        ZStack(alignment: .topLeading) {
            if row.inGroup, row.kind != .group {
                Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 3)
            }
            if row.inProject, row.kind != .project {
                Rectangle().fill(Theme.faint.opacity(0.5)).frame(width: 1)
                    .padding(.leading, (row.inGroup ? QueueRowView.indent : 0) + 3)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// A session's pull requests in its queue row: `⇄ #12 ✓`, or `⇄ 3 PRs`.
enum ResourceLabel {
    @ViewBuilder static func pulls(of row: QueueRow) -> (some View)? {
        let pulls = row.resources.filter { $0.kind == .pullRequest }
        if let first = pulls.first {
            HStack(spacing: 3) {
                Text(pulls.count == 1 ? "⇄ \(number(of: first))" : "⇄ \(pulls.count) PRs")
                    .font(Theme.mono(10)).foregroundStyle(first.state == "merged" ? Theme.lilac : Theme.cyan)
                if pulls.count == 1, let mark = checksMark(first) { mark }
            }
        }
    }

    /// `#12` from `theam/shepherdr#12`.
    static func number(of resource: RemoteResource) -> String {
        resource.name.split(separator: "#").last.map { "#\($0)" } ?? resource.name
    }

    static func checksMark(_ resource: RemoteResource) -> Text? {
        switch resource.checks {
        case "passed": Text("✓").font(Theme.mono(10)).foregroundStyle(Theme.phosphor)
        case "failed": Text("✗").font(Theme.mono(10)).foregroundStyle(Theme.red)
        case "running": Text("◌").font(Theme.mono(10)).foregroundStyle(Theme.amber)
        default: nil
        }
    }
}

/// The lines tying sessions on hold to the sessions they wait for, as the Mac's sidebar draws
/// them: each level's line runs under its parent's number, and ends in an elbow at the session.
struct TreeLines: View {
    let tree: QueueTree
    /// The row's whole depth, of which the tree's levels are the last ones.
    let depth: Int
    /// Halfway down the title's first line, and below the parent's number.
    private let elbow: CGFloat = 15, parentBottom: CGFloat = 22

    var body: some View {
        let top = CGFloat(depth - tree.depth) * QueueRowView.indent
        Canvas { context, size in
            func x(_ level: Int) -> CGFloat { top + CGFloat(level - 1) * QueueRowView.indent + 3.5 }
            var path = Path()
            for (index, passes) in tree.guides.enumerated() where passes {
                path.addRect(CGRect(x: x(index + 1), y: 0, width: 1, height: size.height))
            }
            if tree.depth > 0 {
                let own = x(tree.depth)
                path.addRect(CGRect(x: own, y: 0, width: 1, height: tree.isLast ? elbow + 1 : size.height))
                path.addRect(CGRect(x: own, y: elbow, width: QueueRowView.indent - 7, height: 1))
            }
            if tree.nested > 0 {
                path.addRect(CGRect(x: x(tree.depth + 1), y: parentBottom, width: 1, height: max(0, size.height - parentBottom)))
            }
            context.fill(path, with: .color(Theme.faint.opacity(0.7)))
        }
        .allowsHitTesting(false)
    }
}

struct HeadingView: View {
    let row: QueueRow
    var flat = false

    var body: some View {
        HStack {
            Text(row.title.uppercased()).font(Theme.mono(10.5, .semibold)).foregroundStyle(Theme.faint).tracking(2)
            if row.needsYou > 0 {
                Text("\(row.needsYou) need you").font(Theme.mono(10)).foregroundStyle(Theme.amber)
            }
            Spacer()
        }
        .padding(.leading, flat ? 0 : CGFloat(row.depth) * QueueRowView.indent)
        .padding(.top, 12).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .topLeading) { if !flat { Rails(row: row) } }
    }
}

/// Paired Macs, dictation's language and pairing another Mac.
struct SettingsSheet: View {
    @Bindable var client: RelayClient
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Dictation.localeKey) private var dictationLocale = ""
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Macs") {
                    ForEach(client.macs) { mac in
                        Button {
                            client.select(mac)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(mac.name).foregroundStyle(Theme.text)
                                    Text(mac.hosts.map { "\($0):\(mac.port)" }.joined(separator: " · "))
                                        .font(Theme.mono(10)).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                if client.mac?.id == mac.id { Image(systemName: "checkmark").foregroundStyle(Theme.phosphor) }
                            }
                        }
                        .swipeActions { Button("Forget", role: .destructive) { client.forget(mac) } }
                    }
                    Button("Pair Another Mac…") { pairing = true }
                }
                Section {
                    Picker("Dictation language", selection: $dictationLocale) {
                        Text("Same as the iPhone").tag("")
                        Text("Español (España)").tag("es-ES")
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                    }
                } footer: {
                    Text("Your iPhone transcribes on the device, with Apple's speech recognition. The first time, iOS may download the language.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $pairing) { PairView(client: client, dismissible: true) }
        }
    }
}
