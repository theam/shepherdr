import AppKit
import SwiftUI
import ShepherdrCore

/// The home screen: cluster pulse at a glance, then every session as a card in priority order.
/// Choosing states and machines narrows the cards to any combination of them.
private enum HomeTab { case sessions, github }

struct OverviewView: View {
    @Bindable var model: AppModel
    @ViewState<HomeTab> private var tab = .sessions
    private var cluster: ClusterStore { model.cluster }
    private var machines: [MachineState] { cluster.machines.filter(\.machine.isEnabled) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                hero
                VStack(spacing: 10) {
                    stateTiles
                    machineTiles
                }
                MailPanel(session: nil, model: model)
                if let failure = cluster.discoveryFailure, failure.state != .notInstalled {
                    NoticeView(title: "Saved machines could not be refreshed", message: failure.message, detail: failure.detail)
                }
                ForEach(cluster.machines.filter { $0.failure != nil }) { state in
                    NoticeView(title: "\(state.machine.name): \(state.connection.title)" + (state.isStale ? " · showing the last known state" : ""),
                               message: state.failure?.message ?? "", detail: state.failure?.detail)
                }
                tabSelector
                switch tab {
                case .sessions: sessions
                case .github: GitHubInboxSection(model: model)
                }
            }
            .padding(.horizontal, 28).padding(.top, 40).padding(.bottom, 28)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .task { await model.usageMonitor.monitor(while: model.presence) { [cluster] in cluster.machines.map(\.machine).filter(\.isEnabled) } }
        .onChange(of: machines.map(\.id), initial: true) { model.sessionFilter.keep(machines: Set(machines.map(\.id))) }
    }

    private var tabSelector: some View {
        HStack(spacing: 8) {
            tabButton("SESSIONS", tab: .sessions)
            tabButton("GITHUB", tab: .github)
        }
    }

    private func tabButton(_ title: String, tab target: HomeTab) -> some View {
        Button(title) { tab = target }
            .buttonStyle(ConsoleButtonStyle(tint: Theme.phosphor, prominent: tab == target))
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 18) {
            PixelFlock(pixel: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text("SHEPHERDR").font(Theme.mono(28, .heavy)).tracking(6).foregroundStyle(Theme.text)
                    .shadow(color: Theme.phosphor.opacity(0.35), radius: 8)
                HStack(spacing: 0) {
                    Text("do androids dream of electric sheep?")
                    BlinkingCursor()
                }
                .font(Theme.mono(12)).foregroundStyle(Theme.phosphor.opacity(0.8))
            }
        }
    }

    /// Each tile counts the sessions the other row lets through.
    private var stateTiles: some View {
        let rows = model.agents
        let filter = model.sessionFilter
        return HStack(spacing: 10) {
            ForEach([SessionStatus.needsYou, .working, .waiting, .done, .idle], id: \.self) { state in
                StateTile(state: state, count: filter.count(state, in: rows, status: model.status(of:)),
                          isChosen: filter.states.contains(state),
                          isLeftOut: !filter.states.isEmpty && !filter.states.contains(state)) {
                    model.sessionFilter.toggle(state)
                }
            }
        }
    }

    private var machineTiles: some View {
        let rows = model.agents
        let filter = model.sessionFilter
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
            ForEach(machines) { state in
                MachineTile(state: state, count: filter.count(machine: state.id, in: rows, status: model.status(of:)),
                            usage: model.usageMonitor.usage[state.id], isChosen: filter.machines.contains(state.id),
                            isLeftOut: !filter.machines.isEmpty && !filter.machines.contains(state.id)) {
                    model.sessionFilter.toggle(machine: state.id)
                }
            }
        }
    }

    @ViewBuilder private var sessions: some View {
        let rows = model.overviewRows
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ConsoleHeader(title: "Sessions by priority",
                              trailing: model.sessionFilter.isEmpty ? (rows.isEmpty ? nil : "⌘1–⌘9 to jump")
                                                                    : "\(rows.count) of \(model.rankedRows.count)")
                if !model.sessionFilter.isEmpty {
                    Button("SHOW ALL") { model.sessionFilter = SessionFilter() }
                        .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                        .help("Stop filtering by state and machine")
                }
            }
            if rows.isEmpty {
                Text(emptyMessage).font(Theme.mono(12)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                    ForEach(rows) { row in
                        SessionCard(model: model, row: row, status: model.status(of: row), showsMachine: model.showsMachineNames,
                                    background: model.backgroundCommands(of: row)) {
                            model.open(row.id)
                        }
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        if !model.rankedRows.isEmpty { return "No sessions in the chosen states and machines." }
        if cluster.isRefreshing && cluster.lastRefresh == nil { return "Connecting to Herdr…" }
        if cluster.onlineCount == 0 { return "Herdr is not reachable. Open Settings (⌘,) → Machines for details, then refresh (⌘R)." }
        return "Connected. Agents appear here when Herdr detects them in a workspace."
    }
}

/// A tile that narrows the sessions below: chosen ones are outlined in their color, and those
/// left out by another choice in their row fade.
private struct FilterTile: ViewModifier {
    let accent: Color
    let isChosen: Bool
    let isLeftOut: Bool
    var isAlert = false
    @ViewState<Bool> private var hovering = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(isChosen ? accent.opacity(0.07) : hovering ? Theme.raised : Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: isChosen ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if isChosen { Rectangle().fill(accent).frame(width: 6, height: 6).padding(9) }
            }
            .contentShape(Rectangle())
            .opacity(isLeftOut && !hovering ? 0.45 : 1)
            .onHover { hovering = $0 }
    }

    private var border: Color {
        if isChosen { return accent.opacity(0.8) }
        if hovering { return accent.opacity(0.4) }
        return isAlert ? Theme.amber.opacity(0.5) : Theme.line
    }
}

private struct StateTile: View {
    let state: SessionStatus
    let count: Int
    let isChosen: Bool
    let isLeftOut: Bool
    let toggle: () -> Void

    private var accent: Color { Theme.color(for: state) }

    var body: some View {
        let color = count > 0 ? accent : Theme.faint
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%02d", count)).font(Theme.mono(26, .bold)).foregroundStyle(color)
                    .shadow(color: count > 0 ? color.opacity(0.5) : .clear, radius: 6)
                Text(label).font(Theme.mono(10, .semibold)).tracking(1.5).foregroundStyle(isChosen ? Theme.text : Theme.dim)
            }
            .modifier(FilterTile(accent: accent, isChosen: isChosen, isLeftOut: isLeftOut,
                                 isAlert: count > 0 && state == .needsYou))
        }
        .buttonStyle(.plain)
        .help(isChosen ? "Stop showing only these sessions"
                       : state == .waiting ? "Show only sessions on hold, waiting for others; choose more to add them"
                                           : "Show only sessions in this state; choose more to add them")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    private var label: String { state == .needsYou ? "NEED YOU" : state.label.uppercased() }
}

/// A machine's sessions and how busy it is, to pick where the next agent goes.
private struct MachineTile: View {
    let state: MachineState
    let count: Int
    let usage: MachineUsage?
    let isChosen: Bool
    let isLeftOut: Bool
    let toggle: () -> Void

    var body: some View {
        let online = state.connection == .online
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ConnectionDot(state: state.connection)
                    Text(state.machine.name.uppercased()).font(Theme.mono(10, .semibold)).tracking(1.5)
                        .foregroundStyle(isChosen ? Theme.text : Theme.dim).lineLimit(1)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "%02d", count)).font(Theme.mono(26, .bold))
                            .foregroundStyle(count > 0 ? Theme.text : Theme.faint)
                        Text(online ? "SESSIONS" : status)
                            .font(Theme.mono(9, .semibold)).tracking(1.2)
                            .foregroundStyle(online ? Theme.faint : Theme.color(for: state.connection)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    UsageBars(usage: usage).fixedSize()
                }
            }
            .modifier(FilterTile(accent: Theme.phosphor, isChosen: isChosen, isLeftOut: isLeftOut))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }

    /// Short enough for the tile; the notice below the tiles explains it.
    private var status: String {
        switch state.connection {
        case .online: "ONLINE"
        case .loading: "CONNECTING"
        case .unreachable: "UNREACHABLE"
        case .notInstalled: "NO HERDR"
        case .notRunning: "HERDR OFF"
        case .incompatible: "INCOMPATIBLE"
        case .disabled: "DISABLED"
        }
    }

    private var help: String {
        let measured = usage == nil
            ? (state.machine.isLocal ? "Measuring this Mac…" : "No usage yet: Shepherdr measures it over SSH every 15 seconds.")
            : "Processor over one second, memory in use, and the disk holding the home folder, every 15 seconds."
        return measured + (isChosen ? "\nClick to stop showing only its sessions." : "\nClick to show only its sessions; choose more to add them.")
    }
}

/// Processor, memory and disk as ten blocks each: amber from 70%, red from 90%.
private struct UsageBars: View {
    let usage: MachineUsage?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            bar("CPU", usage?.cpu)
            bar("MEM", usage?.memory)
            bar("DSK", usage?.disk)
        }
    }

    private func bar(_ label: String, _ value: Int?) -> some View {
        let color = value.map(Self.color) ?? Theme.faint
        return HStack(spacing: 6) {
            Text(label).font(Theme.mono(9, .semibold)).foregroundStyle(Theme.faint)
            HStack(spacing: 2) {
                ForEach(0..<10, id: \.self) { block in
                    Rectangle().fill(block < Self.blocks(value) ? color : Theme.line).frame(width: 5, height: 8)
                }
            }
            Text(value.map { "\($0)%" } ?? "—").font(Theme.mono(10)).foregroundStyle(color)
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value.map { "\($0)%" } ?? "unknown")")
    }

    /// Any use shows at least one block.
    static func blocks(_ value: Int?) -> Int {
        guard let value, value > 0 else { return 0 }
        return max(1, (value + 5) / 10)
    }

    static func color(_ value: Int) -> Color { value >= 90 ? Theme.red : value >= 70 ? Theme.amber : Theme.phosphor }
}

/// How busy each machine is, measured every 15 seconds while the overview is on screen.
@MainActor @Observable
final class MachineUsageMonitor {
    private(set) var usage: [String: MachineUsage] = [:]
    @ObservationIgnored private var measuredAt: [String: Date] = [:]
    @ObservationIgnored private var startedAt: [String: Date] = [:]
    @ObservationIgnored private var measuring = Set<String>()

    /// Measures until cancelled, such as when the overview leaves the screen; a machine that joins
    /// is measured right away. Nothing is measured while Shepherdr isn't on screen, such as while
    /// the screens sleep: it waits for it to be.
    func monitor(while presence: ScreenPresence, _ machines: @escaping @MainActor () -> [Machine]) async {
        await withDiscardingTaskGroup { group in
            while !Task.isCancelled {
                await presence.untilOnScreen()
                for machine in machines() where isDue(machine.id) {
                    measuring.insert(machine.id)
                    startedAt[machine.id] = Date()
                    group.addTask { await self.measure(machine) }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
    }

    private func isDue(_ id: String) -> Bool {
        !measuring.contains(id) && Date().timeIntervalSince(startedAt[id] ?? .distantPast) >= 15
    }

    private func measure(_ machine: Machine) async {
        let found = await MachineUsage.read(machine)
        measuring.remove(machine.id)
        if let found {
            usage[machine.id] = found
            measuredAt[machine.id] = Date()
        } else if Date().timeIntervalSince(measuredAt[machine.id] ?? .distantPast) > 60 {
            // A machine that stopped answering keeps its last reading for a minute.
            usage[machine.id] = nil
        }
    }
}

/// A session in the overview: a click opens it, and one on its pull requests or issues opens those.
private struct SessionCard: View {
    let model: AppModel
    let row: AgentRow
    let status: SessionStatus
    let showsMachine: Bool
    let background: [BackgroundCommand]
    let open: () -> Void
    @ViewState<Bool> private var hovering = false

    var body: some View {
        let color = Theme.color(for: status)
        // Not a button: its pull requests' label is one of its own.
        VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", row.manualPriority)).font(Theme.mono(10, .semibold)).foregroundStyle(Theme.faint)
                    StateGlyph(status: status, background: !background.isEmpty)
                    Text(row.workspace).font(Theme.mono(13, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    StateTag(status: status)
                }
                Text(row.title).font(Theme.mono(11)).foregroundStyle(Theme.text.opacity(0.7)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    HStack(spacing: 5) {
                        AgentMark(program: row.agent.program)
                        if showsMachine { Text("@\(row.machineName)") }
                    }
                    .layoutPriority(1)
                    SessionLinksLabel(model: model, id: row.id, showsIssues: true).layoutPriority(1)
                    BackgroundLabel(commands: background).foregroundStyle(Theme.dim)
                }
                .font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(hovering ? Theme.raised : Theme.panel, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(hovering ? color.opacity(0.6) : Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, open)
        .onHover { hovering = $0 }
        .opacity(row.isStale ? 0.6 : 1)
        .help("Open \(row.workspace)")
    }
}

struct BlinkingCursor: View {
    var body: some View {
        FrameCycle(count: 2, interval: 0.55, size: CGSize(width: 7, height: 13), key: 0) { frame, context in
            guard frame == 0 else { return }
            context.setFillColor(NSColor(Theme.phosphor).withAlphaComponent(0.9).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 7, height: 13))
        }
        .frame(width: 7, height: 13)
        .padding(.leading, 3)
        .accessibilityHidden(true)
    }
}
