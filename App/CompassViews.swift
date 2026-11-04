import AppKit
import SwiftUI
import ShepherdrCore

/// COMPASS and AGENTS, beside the window's buttons. Each tab says when it wants you: sessions
/// that need you, or a Compass page that changed or an agent waiting at a question.
struct ModeTabs: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            tab(.compass, "COMPASS", help: "Compass: the page of your day (⌥⌘1)") { compassBadge }
            tab(.agents, "AGENTS", help: "Agents: your sessions' queue (⌥⌘2)") { agentsBadge }
        }
        .fixedSize()
    }

    private func tab(_ mode: AppMode, _ title: String, help: String, @ViewBuilder badge: () -> some View) -> some View {
        let selected = model.mode == mode
        return Button { model.mode = mode } label: {
            HStack(spacing: 5) {
                Text(title).font(Theme.mono(9.5, .semibold)).tracking(1)
                badge()
            }
            .foregroundStyle(selected ? Theme.phosphor : Theme.dim)
            .padding(.horizontal, 9).frame(height: 22)
            .background(selected ? Theme.raised : Theme.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.phosphor.opacity(0.7) : Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder private var agentsBadge: some View {
        let live = model.agents.filter { !$0.isStale }
        let blocked = live.filter { $0.agent.state == .blocked }.count
        if blocked > 0 {
            Text("\(blocked)").font(Theme.mono(9.5, .bold)).foregroundStyle(Theme.amber)
        } else if !live.isEmpty {
            Text("\(live.count)").font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
        }
    }

    @ViewBuilder private var compassBadge: some View {
        let compass = model.compass
        switch compass.activity {
        case .needsYou: dot(Theme.amber)
        case .running: dot(Theme.cyan)
        default: if compass.hasNews && model.mode != .compass { dot(Theme.phosphor) }
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 6, height: 6).shadow(color: color.opacity(0.7), radius: 2)
    }
}

/// Compass's column, in place of the queue: how the last run went, when the next one is, and
/// every day's page with the copies its runs left.
struct CompassSidebar: View {
    @Bindable var model: AppModel
    let compass: CompassController
    @ViewState<String?> private var expandedDay: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if compass.isSetUp {
                ScrollView { history.frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                Spacer()
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .background(Theme.panel)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Text("◈").font(Theme.mono(15, .bold)).foregroundStyle(Theme.phosphor)
                    .shadow(color: Theme.phosphor.opacity(0.6), radius: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("COMPASS").font(Theme.mono(13, .heavy)).tracking(2.5).foregroundStyle(Theme.text)
                    Text(compass.isSetUp ? "\(AgentProgram(label: compass.config.agent).name) · this Mac" : "not set up yet")
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 0)
                if compass.isSetUp {
                    Button("▶ RUN") { compass.runNow() }
                        .buttonStyle(ConsoleButtonStyle())
                        .disabled(compass.openRun != nil)
                        .help(compass.openRun != nil ? "A run is under way" : "Update the page now (⌥⌘R)")
                }
            }
            if compass.isSetUp { status }
        }
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 12)
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            VStack(alignment: .leading, spacing: 4) {
                activityLine
                Text(nextLine).foregroundStyle(Theme.dim)
                if let problem = compass.configProblem {
                    Text(problem).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
                }
                if let problem = compass.problem {
                    HStack(alignment: .top, spacing: 6) {
                        Text("✗ \(problem)").foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("×") { compass.problem = nil }.buttonStyle(.plain).foregroundStyle(Theme.dim).help("Dismiss")
                    }
                }
                if compass.openRun != nil, compass.activity != .needsYou {
                    Button("cancel this run") { compass.cancelRun() }
                        .buttonStyle(.plain).foregroundStyle(Theme.faint)
                        .help("Stop waiting for this run. The agent keeps whatever it's doing.")
                }
                backupLine
            }
            .font(Theme.mono(10.5))
        }
    }

    @ViewBuilder private var activityLine: some View {
        switch compass.activity {
        case .needsYou:
            Text("! needs you in its terminal").foregroundStyle(Theme.amber)
        case .running(let since):
            Text("● running since \(Compass.time(since, calendar: compass.calendar))").foregroundStyle(Theme.cyan)
        case .waitingForYou:
            Text("○ the run waits until you stop typing").foregroundStyle(Theme.cyan)
        case .waitingForAgent:
            Text(compass.agentID == nil ? "○ starting the agent…" : "○ the run waits for the agent").foregroundStyle(Theme.cyan)
        case .waitingForMac(let blocker):
            Text("○ the run waits for \(blocker.summary)").foregroundStyle(Theme.cyan)
        case .idle:
            if let run = compass.lastFinished, let finished = run.finished {
                let time = Compass.time(finished, calendar: compass.calendar)
                let day = Compass.day(finished, calendar: compass.calendar) == compass.today ? "" : " · \(Self.shortDay(run.day, compass.calendar))"
                Text(run.outcome == .updated ? "✓ updated \(time)\(day)" : "✓ checked \(time)\(day) · no changes")
                    .foregroundStyle(Theme.phosphor)
            } else {
                Text("no runs yet").foregroundStyle(Theme.dim)
            }
        }
    }

    private var nextLine: String {
        if !compass.config.enabled { return "schedule paused" }
        if compass.config.schedule.kind == .manual { return "runs when you ask" }
        guard let next = compass.nextRun else { return compass.config.schedule.summary }
        let calendar = compass.calendar
        let day = Compass.day(next, calendar: calendar) == compass.today ? "" : "\(Self.shortDay(Compass.day(next, calendar: calendar), calendar)) "
        return "next run \(day)\(Compass.time(next, calendar: calendar))"
    }

    @ViewBuilder private var backupLine: some View {
        switch compass.backup {
        case .none:
            EmptyView()
        case .working:
            Text("↑ backing up…").foregroundStyle(Theme.dim)
        case .done(let date):
            Text(compass.config.backup == nil ? "✓ saved in Git \(Compass.time(date, calendar: compass.calendar))"
                                              : "↑ backed up \(Compass.time(date, calendar: compass.calendar))")
                .foregroundStyle(Theme.faint)
        case .failed(let message):
            Text("✗ backup failed").foregroundStyle(Theme.amber).help(message)
        }
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: 2) {
            let today = compass.today
            sectionTitle("TODAY · \(Self.shortDay(today, compass.calendar).uppercased())")
            if compass.hasTodaysPage {
                historyRow("today's page", mark: "◈", tint: Theme.phosphor, selected: compass.shown == .today) { compass.show(.today) }
            }
            ForEach(compass.state.runs.filter { $0.day == today }.reversed()) { run in runRow(run) }
            let earlier = compass.folder.days().filter { $0 != today }.prefix(60)
            if !earlier.isEmpty {
                sectionTitle("EARLIER").padding(.top, 12)
                ForEach(Array(earlier), id: \.self) { day in dayRows(day) }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(Theme.mono(9, .semibold)).tracking(1.4).foregroundStyle(Theme.faint)
            .padding(.horizontal, 6).padding(.bottom, 4)
    }

    private func runRow(_ run: CompassRun) -> some View {
        let time = Compass.time(run.slot ?? run.created, calendar: compass.calendar)
        let (mark, tint, label): (String, Color, String) = switch run.outcome {
        case .waiting: ("○", Theme.cyan, "waiting")
        case .running: ("●", Theme.cyan, "running")
        case .updated: ("✓", Theme.phosphor, run.kind == .first ? "first of the day" : run.kind == .last ? "last of the day" : "updated")
        case .unchanged: ("·", Theme.dim, "no changes")
        case .failed: ("✗", Theme.amber, run.problem ?? "failed")
        }
        let snapshot = run.snapshot.flatMap { path -> CompassController.Shown? in
            let parts = path.split(separator: "/")
            guard parts.count == 3 else { return nil }
            return .snapshot(day: String(parts[1]), time: String(parts[2].dropLast(5)))
        }
        return historyRow("\(time)  \(label)\(run.trigger == .manual ? " · you" : "")", mark: mark, tint: tint,
                          selected: snapshot != nil && compass.shown == snapshot) {
            if let snapshot { compass.show(snapshot) }
        }
        .disabled(snapshot == nil)
        .help(run.problem ?? (snapshot == nil ? "" : "The page as this run left it"))
    }

    @ViewBuilder private func dayRows(_ day: String) -> some View {
        let expanded = expandedDay == day
        historyRow(Self.shortDay(day, compass.calendar), mark: expanded ? "▾" : "▸", tint: Theme.dim,
                   selected: compass.shown == .day(day)) {
            compass.show(.day(day))
            expandedDay = expanded ? nil : day
        }
        if expanded {
            ForEach(compass.folder.snapshots(day), id: \.time) { snapshot in
                historyRow(snapshot.time.replacingOccurrences(of: "-", with: ":"), mark: "·", tint: Theme.faint,
                           selected: compass.shown == .snapshot(day: day, time: snapshot.time)) {
                    compass.show(.snapshot(day: day, time: snapshot.time))
                }
                .padding(.leading, 14)
            }
        }
    }

    private func historyRow(_ title: String, mark: String, tint: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(mark).foregroundStyle(tint).frame(width: 12)
                Text(title).foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.75)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .font(Theme.mono(11))
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(selected ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `Thu 15 Oct`.
    static func shortDay(_ day: String, _ calendar: Calendar) -> String {
        guard let date = Compass.date(ofDay: day, calendar: calendar) else { return day }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if compass.isSetUp {
                Text(compass.config.schedule.summary).lineLimit(1).truncationMode(.tail)
                    .help("When Compass updates the page. Change it in Settings → Compass, or ask the agent.")
            }
            Spacer(minLength: 4)
            if compass.isSetUp {
                Button { NSWorkspace.shared.open(compass.folder.root) } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim)
                    .help("Open ~/.shepherdr/compass in the Finder")
            }
            Button { if let guide = AppModel.guide { model.openHelp(guide) } } label: { Text("?").font(Theme.mono(13, .bold)) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                .help("Shepherdr guide (⌘?)")
            SettingsLink { Text("⚙").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                .help("Compass's schedule and backup are in Settings → Compass (⌘,)")
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// The page of the day beside its agent's terminal; before Compass is set up, what it is and a
/// way to start it.
struct CompassWorkArea: View {
    @Bindable var model: AppModel
    let compass: CompassController

    var body: some View {
        Group {
            if compass.isSetUp {
                BrowserSplit(showsBrowser: compass.showsAgent) { page } browser: { agent }
            } else {
                CompassWelcome(model: model, compass: compass)
            }
        }
        .background(Theme.background)
        .onAppear { compass.viewed() }
        .onChange(of: compass.pageModified) { if NSApp.isActive { compass.viewed() } }
    }

    @ViewBuilder private var page: some View {
        if compass.browser.tabs.isEmpty {
            VStack(spacing: 12) {
                Text("[ NO PAGE FOR TODAY YET ]").font(Theme.mono(14, .bold)).foregroundStyle(Theme.dim)
                Text(compass.openRun != nil ? "The agent is writing it." : "The next run writes it. Run Compass now to have it sooner.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("▶ RUN NOW") { compass.runNow() }.buttonStyle(ConsoleButtonStyle(prominent: true))
                        .disabled(compass.openRun != nil)
                    if let latest = compass.folder.days().first {
                        Button("SHOW \(CompassSidebar.shortDay(latest, compass.calendar).uppercased())") { compass.show(.day(latest)) }
                            .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BrowserPanel(browser: compass.browser)
        }
    }

    @ViewBuilder private var agent: some View {
        if let id = compass.agentID, let context = model.context(for: id) {
            SessionView(context: context, model: model, mode: .control, isCompass: true)
                .id(context.target)
        } else {
            VStack(spacing: 10) {
                Text("[ AGENT NOT RUNNING ]").font(Theme.mono(13, .bold)).foregroundStyle(Theme.dim)
                Text("Compass starts its agent for the next run.\nRun it now to talk to it.")
                    .font(Theme.mono(11)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                Button("▶ RUN NOW") { compass.runNow() }.buttonStyle(ConsoleButtonStyle())
                    .disabled(compass.openRun != nil || model.cluster.machines.first(where: { $0.machine.isLocal })?.connection != .online)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.panel)
        }
    }
}

/// What Compass is, before it's set up: start it, or bring it back from its backup.
private struct CompassWelcome: View {
    @Bindable var model: AppModel
    let compass: CompassController
    @ViewState<String> private var agent = "claude"
    @ViewState<String> private var remote = ""

    private var localOnline: Bool { model.cluster.machines.first { $0.machine.isLocal }?.connection == .online }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    PixelFlock(pixel: 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("COMPASS").font(Theme.mono(18, .heavy)).tracking(3).foregroundStyle(Theme.text)
                        Text("the page of your day, kept by an agent of its own").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    }
                }
                Text("An agent on this Mac keeps one page per day with what deserves your attention. You talk to it in the terminal beside the page, and buttons on the page start the sessions it suggests, once you check them.")
                    .font(Theme.mono(12)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
                Text("It starts small: it sums up your sessions, what needs you and what finished. Ask it for more, such as your calendar or your mail, and it changes its own instructions.")
                    .font(Theme.mono(12)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHAT STARTING IT DOES").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.faint)
                    bullet("Creates ~/.shepherdr/compass with its instructions, your prompt.md and a Git history.")
                    bullet("Starts the agent there, in a Herdr workspace named compass, out of your queue.")
                    bullet("Updates the page every hour from 9 to 18, Monday to Friday. Change it in Settings → Compass.")
                    bullet("Claude Code asks once whether you trust the folder: answer in Compass's terminal.")
                }
                HStack(spacing: 10) {
                    Picker("Agent", selection: $agent) {
                        ForEach(NewSessionRequest.agentKinds, id: \.self) { kind in Text(AgentProgram(label: kind).name).tag(kind) }
                    }
                    .frame(width: 220)
                    Button(compass.isPreparing ? "STARTING…" : "START COMPASS ⏎") { Task { await compass.setUp(agent: agent) } }
                        .buttonStyle(ConsoleButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(compass.isPreparing || !localOnline || compass.kit == nil)
                }
                if !localOnline {
                    Text("Herdr isn't answering on this Mac. Start it, then come back.").font(Theme.mono(10.5)).foregroundStyle(Theme.amber)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text("ALREADY HAVE A COMPASS BACKUP?").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.faint)
                    HStack(spacing: 8) {
                        TextField("git@github.com:you/compass.git", text: $remote)
                            .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.text)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                        Button("RESTORE") { Task { await compass.restore(from: remote.trimmingCharacters(in: .whitespaces)) } }
                            .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                            .disabled(remote.trimmingCharacters(in: .whitespaces).isEmpty || compass.isPreparing || !compass.hasGit)
                    }
                    Text(compass.hasGit ? "Shepherdr clones it into ~/.shepherdr/compass, with your prompt and every page."
                                        : "Restoring needs Git: install the Command Line Tools with xcode-select --install.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.faint)
                }
                if let problem = compass.problem {
                    Text("✗ \(problem)").font(Theme.mono(11)).foregroundStyle(Theme.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(36)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            // The agent the tools found on this Mac, if only one of them is there.
            let agents = model.courier.tools.tools(on: Machine.local.id).check?.agents.filter(\.isPresent).map(\.name) ?? []
            if agents == ["codex"] { agent = "codex" }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("›").foregroundStyle(Theme.phosphor)
            Text(text).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.mono(11))
    }
}
