import SwiftUI
import ShepherdrCore
import ShepherdrDictation
import ShepherdrTerminalUI

/// One session in the work area: its live terminal and a composer for the next prompt.
/// The view is identified by its terminal target, so refreshes never reconnect it.
struct SessionView: View {
    let context: SessionContext
    @Bindable var model: AppModel
    /// Survives switching sessions: the prompt editor's state and the browser's tabs.
    let workspace: SessionWorkspace
    @ViewState<TerminalStore> private var terminal: TerminalStore
    @ViewState<Bool> private var showDetails = false
    @ViewState<CGFloat> private var editorHeight: CGFloat = 60
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("terminalFontFamily") private var fontFamily = ConsoleFonts.defaultFamily
    @AppStorage(ConsoleFonts.ligaturesKey) private var ligatures = false
    @AppStorage("showsResources") private var showsResources = true

    init(context: SessionContext, model: AppModel, mode: TerminalMode) {
        self.context = context
        self.model = model
        workspace = model.workspace(for: Agent.ID(machineID: context.machine.id, terminalID: context.target.terminalID))
        _terminal = ViewState(initialValue: TerminalStore(target: context.target, mode: mode))
    }

    private var id: Agent.ID { .init(machineID: context.machine.id, terminalID: context.target.terminalID) }
    private var isLive: Bool { terminal.status == .interactive }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            RelationsPanel(id: id, model: model)
            HStack(spacing: 0) {
                workArea
                if showsResources && !workspace.visibleResources.isEmpty {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    ResourcesPanel(workspace: workspace, checks: model.checksMonitor) { showsResources = false }
                        .frame(width: 230)
                }
            }
        }
        .background(Theme.background)
        .onAppear { model.activeTerminal = terminal }
        .onDisappear { if model.activeTerminal === terminal { model.activeTerminal = nil } }
        .task(id: id) {
            // Once the terminal is attached: Herdr refuses an attach while a read of the pane runs.
            for _ in 0..<50 where terminal.status == .connecting || terminal.status == .disconnected {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await model.harvestResources(for: id)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            terminal.disconnect()
        }
    }

    private var workArea: some View {
        BrowserSplit(showsBrowser: workspace.browser.isVisible) {
            VStack(spacing: 0) {
                banners
                if context.canConnect {
                    TerminalSurface(store: terminal, palette: Theme.terminal,
                                    font: ConsoleFonts.font(family: fontFamily, size: fontSize, ligatures: ligatures),
                                    focusRequest: model.terminalFocusRequest,
                                    resolveFile: { [model, id] path in model.file(at: path, for: id) },
                                    onResources: { [model, id] found in model.collectResources(found, for: id) },
                                    onDropFiles: { [model, id, terminal] files in model.drop(files, into: id, terminal: terminal) }
                    ) { [model, id] url, external in
                        model.openLink(url, from: id, external: external)
                    }
                    .padding(.leading, 10).padding(.top, 6)
                    .background(Theme.background)
                    .overlay { if terminal.status == .connecting { connecting } }
                    .overlay(alignment: .bottomTrailing) { HistoryBadge(terminal: terminal) }
                } else {
                    offline
                }
                if workspace.isEditorOpen { editor }
                bottomBar
            }
        } browser: {
            BrowserPanel(browser: workspace.browser)
        }
    }

    @ViewBuilder private var banners: some View {
        if let notice = model.sessionNotices[id] {
            banner(notice, dismiss: { model.sessionNotices[id] = nil })
        }
        if case .failed(let message) = model.dictation.state {
            banner("Dictation: \(message)", dismiss: { model.dictation.dismissFailure() })
        }
        if let message = terminal.message {
            banner(message)
        } else if terminal.isControlledElsewhere {
            banner("Another client is typing in this terminal, so it is locked here.",
                   action: ("TAKE OVER", { terminal.takeOver() }))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if let agent = context.agent {
                StateGlyph(state: agent.agent.state, stale: agent.isStale, background: !model.backgroundCommands(of: agent).isEmpty)
            } else {
                Text("$").font(Theme.mono(13, .bold)).foregroundStyle(Theme.phosphor)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(context.target.workspace).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text("›").font(Theme.mono(13)).foregroundStyle(Theme.faint)
                    Text(context.title).font(Theme.mono(13)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(locationLine).font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                    Text("·").font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    PaneIDButton(paneID: context.paneID, workspace: context.target.workspace, machine: context.machine.machine)
                        .layoutPriority(1)
                }
            }
            Spacer(minLength: 8)
            if let agent = context.agent {
                let background = model.backgroundCommands(of: agent)
                if !background.isEmpty {
                    BackgroundLabel(commands: background)
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim).frame(maxWidth: 220, alignment: .trailing)
                }
                StateTag(state: agent.agent.state, stale: agent.isStale)
            }
            lockButton
            HStack(spacing: 4) {
                Button { terminal.open() } label: { Text("↻").frame(width: 16, height: 14) }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .disabled(terminal.status == .connecting || !context.canConnect)
                    .help("Reconnect to this terminal")
                resourcesButton
                browserButton
            }
            Button { showDetails.toggle() } label: { Text("i") }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .help("Session details")
                .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                    SessionDetails(context: context).frame(width: 320)
                }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)
        .background(Theme.panel)
    }

    private var locationLine: String {
        let machine = context.machine.machine
        let place = machine.isLocal ? "local" : "\(machine.name) (\(machine.target ?? "ssh"))"
        let directory = context.agent?.project ?? ""
        return [place, "session \(machine.session)", directory].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Open lock: keyboard, paste and prompts go to the session. Closed lock: read-only.
    private var lockButton: some View {
        let locked = terminal.mode == .observe
        return Button { terminal.open(mode: locked ? .control : .observe) } label: {
            Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 16, height: 14)
                .shadow(color: !locked && isLive ? Theme.phosphor.opacity(0.8) : .clear, radius: 3)
        }
        .buttonStyle(ConsoleButtonStyle(tint: locked ? Theme.amber : Theme.phosphor))
        .disabled(terminal.status == .connecting || !context.canConnect)
        .help(locked ? "Locked: read-only. Click to unlock and type here (⌘E)"
                     : "Unlocked: typing and prompts go to this session. Click to lock it read-only (⌘E)")
        .accessibilityLabel(locked ? "Unlock session" : "Lock session")
    }

    private var resourcesButton: some View {
        let links = workspace.visibleResources.count
        return Button { showsResources.toggle() } label: { Text("≡").frame(width: 16, height: 14) }
            .buttonStyle(ConsoleButtonStyle(tint: showsResources && links > 0 ? Theme.phosphor : Theme.dim))
            .disabled(links == 0)
            .help(links > 0 ? "Pull requests, issues and Claude artifacts this session linked to"
                             : "Pull requests, issues and Claude artifacts this session links to gather here")
    }

    private var browserButton: some View {
        Button { model.toggleBrowser() } label: {
            Image(systemName: "globe").font(.system(size: 11, weight: .semibold)).frame(width: 16, height: 14)
        }
        .buttonStyle(ConsoleButtonStyle(tint: workspace.browser.isVisible ? Theme.phosphor : Theme.dim))
        .help("This session's browser (⌘B). Its tabs stay open while you work elsewhere.")
    }

    // MARK: Banners and states

    private func banner(_ message: String, dismiss: (() -> Void)? = nil, action: (String, () -> Void)? = nil) -> some View {
        let failed = terminal.status == .failed
        return HStack(alignment: .top, spacing: 10) {
            Text(failed ? "✗" : "!").font(Theme.mono(12, .bold))
            VStack(alignment: .leading, spacing: 3) {
                Text(message).font(Theme.mono(11.5)).textSelection(.enabled)
                if let detail = terminal.detail {
                    Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(4).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if let dismiss {
                Button("OK", action: dismiss).buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
            } else if let action {
                Button(action.0, action: action.1).buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
                    .disabled(terminal.status == .connecting)
                    .help("Detach the other client's input and control this terminal from Shepherdr")
            } else if terminal.status == .failed || terminal.status == .ended {
                Button("RECONNECT") { terminal.open() }.buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
            }
        }
        .foregroundStyle(failed ? Theme.red : Theme.amber)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background((failed ? Theme.red : Theme.amber).opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var connecting: some View {
        Text("connecting to \(context.target.workspace)…")
            .font(Theme.mono(12)).foregroundStyle(Theme.phosphor)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
    }

    private var offline: some View {
        VStack(spacing: 10) {
            Text("[ \(context.machine.connection.title.uppercased()) ]").font(Theme.mono(13, .bold)).foregroundStyle(Theme.amber)
            Text(context.machine.failure?.message ?? "This machine is not reachable right now.")
                .font(Theme.mono(11)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            if context.isStale { Text("showing last known state").font(Theme.mono(10)).foregroundStyle(Theme.faint) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private var draft: Binding<String> {
        Binding { model.drafts[id] ?? "" } set: { model.drafts[id] = $0 }
    }

    /// The optional editor for long prompts, opened from the bottom bar or with ⌘L.
    private var editor: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("›").font(Theme.mono(15, .bold))
                .foregroundStyle(isLive ? Theme.phosphor : Theme.faint)
                .shadow(color: isLive ? Theme.phosphor.opacity(0.7) : .clear, radius: 4)
                .padding(.top, 3)
            ZStack(alignment: .topLeading) {
                if draft.wrappedValue.isEmpty {
                    Text(placeholder).font(Font(ConsoleFonts.font(family: fontFamily, size: 13, ligatures: ligatures)))
                        .foregroundStyle(Theme.faint)
                        .padding(.top, 5).allowsHitTesting(false)
                }
                PromptEditor(text: draft, height: $editorHeight, isEnabled: true,
                             font: ConsoleFonts.font(family: fontFamily, size: 13, ligatures: ligatures),
                             focusRequest: model.promptFocusRequest, history: model.prompts(for: id),
                             onSubmit: submit)
                    .frame(height: max(editorHeight, 60))
            }
            VStack(alignment: .trailing, spacing: 6) {
                Button(action: submit) { Text("SEND ⏎") }
                    .buttonStyle(ConsoleButtonStyle(prominent: true))
                    .disabled(!isLive || draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(isLive ? "Send to the session (⏎). ⇧⏎ adds a line." : "Unlock the session to send")
                Button { model.togglePromptEditor() } label: { Text("CLOSE") }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .help("Close the editor and keep the draft (⌘L)")
            }
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.phosphor.opacity(0.35)).frame(height: 1) }
    }

    /// Always-visible controls: the prompt editor, dictation, quick keys and this session's browser.
    /// With the browser open the column narrows, so the bar falls back to icons.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            barContent(compact: false)
            barContent(compact: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func barContent(compact: Bool) -> some View {
        HStack(spacing: 6) {
            let hasDraft = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let prompt = compact ? "✎" : "✎ PROMPT"
            barToggle(hasDraft && !workspace.isEditorOpen ? "\(prompt) •" : prompt, active: workspace.isEditorOpen,
                      help: "Prompt editor for long prompts (⌘L)") { model.togglePromptEditor() }
            DictationButton(model: model, id: id, compact: compact)
            Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, compact ? 1 : 4)
            key("esc", .escape, help: "Escape — interrupts most agents (⌘⎋)")
            key("^C", .interrupt, help: "Control-C")
            key("tab", .tab, help: "Tab")
            key("↑", .up, help: "Up arrow")
            key("↓", .down, help: "Down arrow")
            key("⏎", .enter, help: "Return")
            Spacer(minLength: 8)
        }
    }

    private func barToggle(_ title: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).lineLimit(1) }
            .buttonStyle(ConsoleButtonStyle(tint: active ? Theme.phosphor : Theme.dim, prominent: active))
            .fixedSize()
            .help(help)
    }

    private var placeholder: String {
        switch terminal.status {
        case .interactive: "next prompt for \(context.target.workspace)…"
        case .connecting: "connecting…"
        default: terminal.isControlledElsewhere ? "another client has input — take over to send" : "locked — draft here, unlock to send"
        }
    }

    private func key(_ label: String, _ key: TerminalKey, help: String) -> some View {
        Button { terminal.press(key) } label: { Text(label) }
            .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
            .fixedSize()
            .disabled(!isLive)
            .help(help)
    }

    private func submit() {
        let text = draft.wrappedValue
        guard terminal.submit(prompt: text) else { return }
        model.remember(text, for: id)
        draft.wrappedValue = ""
        workspace.isEditorOpen = false
        model.terminalFocusRequest += 1
    }
}

/// Herdr metadata for the selected session.
private struct SessionDetails: View {
    let context: SessionContext

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConsoleHeader(title: "Session")
            if let row = context.agent {
                field("Agent", row.agent.kind)
                field("State", row.agent.state == .unknown ? "Unknown (\(row.agent.reportedState))" : row.agent.state.title)
                field("Tab", "\(row.agent.tabName) · \(row.agent.tabID)")
                field("Pane", row.agent.paneID)
                field("Directory", row.agent.directory ?? "Not reported")
                if row.agent.isLaunchPending { field("Launch", "Pending in Herdr") }
            } else {
                field("Pane", context.target.title)
            }
            field("Machine", context.machine.machine.isLocal ? "Local" : "\(context.machine.machine.name) · \(context.machine.machine.target ?? "")")
            field("Herdr session", context.machine.machine.session)
            field("Terminal ID", context.target.terminalID)
            if let date = context.machine.lastSuccess {
                field("Last received", date.formatted(date: .abbreviated, time: .standard))
            }
            Text("Leaving a session detaches this client only. The pane keeps running in Herdr.")
                .font(Theme.mono(9.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .textSelection(.enabled)
        .background(Theme.panel)
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.faint)
            Text(value).font(Theme.mono(11.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sessions related by waiting: the ones this session is on hold for, and the ones on hold for it.
struct RelationsPanel: View {
    let id: Agent.ID
    let model: AppModel

    var body: some View {
        let awaited = model.relations.waitingFor(id)
        let waiters = model.relations.waiters(of: id)
        if !awaited.isEmpty || !waiters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !awaited.isEmpty {
                    line(model.waitState(for: id) == .ready ? "READY · WAITED FOR" : "ON HOLD · WAITING FOR",
                         ids: awaited, removable: true) {
                        WaitForMenu(id: id, model: model) { Text("+").font(Theme.mono(11, .bold)) }
                        Button("RESUME") { model.relations.stopWaiting(id) }
                            .buttonStyle(ConsoleButtonStyle(tint: Theme.cyan))
                            .help("Stop waiting: clear this session's hold")
                    }
                }
                if !waiters.isEmpty {
                    line("WAITED ON BY", ids: waiters, removable: false) { EmptyView() }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Theme.cyan.opacity(0.06))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    private func line(_ title: String, ids: [Agent.ID], removable: Bool,
                      @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Image(systemName: removable ? "hourglass" : "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.cyan)
            Text(title).font(Theme.mono(9.5, .bold)).tracking(1).foregroundStyle(Theme.cyan).fixedSize()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ids, id: \.self) { other in chip(other, removable: removable) }
                }
            }
            trailing()
        }
    }

    private func chip(_ other: Agent.ID, removable: Bool) -> some View {
        let row = model.row(for: other)
        return HStack(spacing: 6) {
            if let row {
                StateGlyph(state: row.agent.state, stale: row.isStale, background: !model.backgroundCommands(of: row).isEmpty)
                Text(row.workspace).foregroundStyle(Theme.text)
                if model.showsMachineNames { Text("@\(row.machineName)").foregroundStyle(Theme.faint) }
                Text(row.agent.state == .blocked ? "needs you" : row.agent.state.title.lowercased())
                    .foregroundStyle(Theme.dim)
            } else {
                Text("◌").foregroundStyle(Theme.faint)
                Text("session gone").foregroundStyle(Theme.faint)
            }
            if removable {
                Button { model.relations.setWaiting(id, for: other, false) } label: { Text("×") }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Stop waiting for this session")
            }
        }
        .font(Theme.mono(10.5))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if row != nil { model.open(other) } }
        .help(row.map { "Open \($0.workspace)" } ?? "This session is no longer reported by Herdr")
    }
}

/// Picks the sessions another one waits for, as checkable menu items.
struct WaitForMenu<Label: View>: View {
    let id: Agent.ID
    let model: AppModel
    @ViewBuilder let label: () -> Label

    var body: some View {
        Menu {
            ForEach(model.rankedRows.filter { $0.id != id }) { other in
                Toggle(model.showsMachineNames ? "\(other.workspace) @\(other.machineName)" : other.workspace,
                       isOn: Binding { model.relations.isWaiting(id, for: other.id) }
                                 set: { model.relations.setWaiting(id, for: other.id, $0) })
            }
        } label: { label() }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose the sessions this one waits for")
    }
}

/// Records a prompt and transcribes it on this Mac into the session's prompt editor.
struct DictationButton: View {
    let model: AppModel
    let id: Agent.ID
    var compact = false

    var body: some View {
        let dictation = model.dictation
        let mine = model.dictationTarget == id
        HStack(spacing: 4) {
            if case .recording(let since) = dictation.state, mine {
                Button { model.toggleDictation() } label: {
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        HStack(spacing: 6) {
                            Circle().fill(Theme.background).frame(width: 7, height: 7)
                                .opacity(0.45 + Double(dictation.level) * 0.55)
                            Text(compact ? Self.elapsed(from: since, to: context.date)
                                         : "STOP \(Self.elapsed(from: since, to: context.date))")
                        }
                    }
                }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.red, prominent: true))
                .fixedSize()
                .help("Stop and transcribe into the prompt editor (⇧⌘D)")
                Button { model.cancelDictation() } label: { Text("×") }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .help("Discard this recording")
                modelStatus(dictation.model)
            } else if case .transcribing = dictation.state, mine {
                Text(compact ? "…" : dictation.model == .ready ? "TRANSCRIBING…" : "LOADING MODEL…")
                    .font(Theme.mono(10, .semibold)).foregroundStyle(Theme.phosphor).fixedSize()
                modelStatus(dictation.model)
            } else {
                Button { model.toggleDictation() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill").font(.system(size: 10, weight: .semibold))
                        if !compact { Text("DICTATE") }
                    }
                }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .fixedSize()
                .disabled(!dictation.isReady)
                .help(dictation.isReady ? "Dictate a prompt (⇧⌘D). It is transcribed on this Mac."
                                        : "Dictation is busy with another session")
            }
        }
    }

    @ViewBuilder private func modelStatus(_ state: Dictation.ModelState) -> some View {
        if case .downloading(let progress) = state {
            Text("↓ model \(Int(progress * 100))%").font(Theme.mono(9.5)).foregroundStyle(Theme.dim)
        }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The terminal beside its browser. The browser opens at half the width (an HSplitView would open it
/// at its minimum), and the divider between them can be dragged.
/// Shown while Herdr shows earlier output, so new output arriving out of sight is not mistaken for a
/// frozen terminal.
private struct HistoryBadge: View {
    let terminal: TerminalStore

    var body: some View {
        if terminal.linesBack > 0 {
            let live = terminal.status == .interactive
            Button { terminal.scrollToLatest() } label: { Text("↓ LATEST") }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 4))
                .disabled(!live)
                .help(live ? "You're reading earlier output. Back to the latest; typing also brings you back."
                           : "Herdr shows earlier output here. Unlock the session to scroll back down.")
                .padding(.trailing, 24).padding(.bottom, 10)
        }
    }
}

private struct BrowserSplit<Terminal: View, Browser: View>: View {
    let showsBrowser: Bool
    @ViewBuilder let terminal: Terminal
    @ViewBuilder let browser: Browser
    /// The browser's share of the width; every opening starts again from half.
    @ViewState private var fraction: CGFloat = 0.5
    private static var terminalMin: CGFloat { 380 }
    private static var browserMin: CGFloat { 320 }
    private static var dividerWidth: CGFloat { 5 }

    var body: some View {
        GeometryReader { proxy in
            let total = proxy.size.width
            HStack(spacing: 0) {
                terminal.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showsBrowser {
                    divider(total: total)
                    browser.frame(width: browserWidth(in: total)).frame(maxHeight: .infinity)
                }
            }
        }
        .coordinateSpace(name: Self.space)
        .onChange(of: showsBrowser) { _, shown in if shown { fraction = 0.5 } }
    }

    private static var space: String { "browserSplit" }

    private func browserWidth(in total: CGFloat, fraction: CGFloat? = nil) -> CGFloat {
        let available = total - Self.dividerWidth, upper = available - Self.terminalMin
        // Too narrow for both minimums: share it evenly.
        guard upper > Self.browserMin else { return max(available / 2, 0) }
        return min(max(available * (fraction ?? self.fraction), Self.browserMin), upper)
    }

    /// A strip of its own rather than an overlay, so the terminal and the web view never take its clicks.
    private func divider(total: CGFloat) -> some View {
        Theme.background
            .overlay { Rectangle().fill(Theme.line).frame(width: 1) }
            .frame(width: Self.dividerWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space)).onChanged { drag in
                let available = total - Self.dividerWidth
                guard available > 0 else { return }
                let width = total - drag.location.x - Self.dividerWidth / 2
                fraction = browserWidth(in: total, fraction: width / available) / available
            })
            .accessibilityHidden(true)
    }
}
