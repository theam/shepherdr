import AppKit
import SwiftUI
import ShepherdrCore
import ShepherdrDictation
import ShepherdrTerminalUI

/// One session in the work area: its live terminal and a composer for the next prompt. When its
/// Herdr tab is split, it shows every pane of the tab, and the composer and the controls act on
/// the one you work in. The view is identified by its terminal target, so refreshes never
/// reconnect it.
struct SessionView: View {
    let context: SessionContext
    @Bindable var model: AppModel
    /// Survives switching sessions: the prompt editor's state and the browser's tabs.
    let workspace: SessionWorkspace
    /// The session's own terminal, kept by the model while the session is out of sight, with what
    /// it last showed.
    private let holder: TerminalHolder
    private let mode: TerminalMode
    /// The terminal you work in: the session's own, or the split you last clicked.
    private var terminal: TerminalStore { holder(for: paneID).store }
    @ViewState<Bool> private var showDetails = false
    @ViewState<CGFloat> private var editorHeight: CGFloat = 60
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("terminalFontFamily") private var fontFamily = ConsoleFonts.defaultFamily
    @AppStorage(ConsoleFonts.ligaturesKey) private var ligatures = false
    @AppStorage("showsResources") private var showsResources = true
    /// Compass's agent, beside its page: no browser, resources or holds of its own.
    let isCompass: Bool

    init(context: SessionContext, model: AppModel, mode: TerminalMode, isCompass: Bool = false) {
        self.context = context
        self.model = model
        self.isCompass = isCompass
        workspace = model.workspace(for: Agent.ID(machineID: context.machine.id, terminalID: context.target.terminalID))
        holder = model.terminal(for: context, mode: mode)
        self.mode = mode
    }

    private var id: Agent.ID { .init(machineID: context.machine.id, terminalID: context.target.terminalID) }
    /// The pane you work in.
    private var paneID: Agent.ID { model.focusedPane(in: id) }

    /// A pane's terminal: the session's own, or one of its splits'.
    private func holder(for pane: Agent.ID) -> TerminalHolder {
        guard pane != id, let context = model.context(for: pane) else { return holder }
        return model.terminal(for: context, mode: mode)
    }
    private var isLive: Bool { terminal.status == .interactive }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if !isCompass { RelationsPanel(id: id, model: model) }
            MailPanel(session: id, model: model)
            HStack(spacing: 0) {
                workArea
                if showsResources && !isCompass && !workspace.visibleResources.isEmpty {
                    Rectangle().fill(Theme.line).frame(width: 1)
                    ResourcesPanel(workspace: workspace, checks: model.checksMonitor).frame(width: 230)
                }
            }
        }
        .background(Theme.background)
        .onAppear { model.activeTerminal = terminal }
        .onChange(of: paneID) { model.activeTerminal = terminal }
        .onDisappear {
            // What you typed in Compass's terminal still counts off screen, such as against starting its agent again.
            if isCompass, let input = holder.store.lastInput { model.compass.noteTyping(at: input) }
            if model.activeTerminal === terminal { model.activeTerminal = nil }
        }
        .task(id: id) {
            // Once the terminal is attached: Herdr refuses an attach while a read of the pane runs.
            for _ in 0..<50 where holder.store.status == .connecting || holder.store.status == .disconnected {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await model.harvestResources(for: id)
        }
    }

    private var workArea: some View {
        BrowserSplit(showsBrowser: workspace.browser.isVisible && !isCompass) {
            VStack(spacing: 0) {
                banners
                if context.canConnect {
                    if let split = model.split(of: id) { panes(split) } else { surface(of: id, split: false) }
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

    /// A pane's terminal. Its links open in the session's browser, and what it shows counts toward
    /// the session's resources.
    private func surface(of pane: Agent.ID, split: Bool) -> some View {
        let holder = holder(for: pane)
        let store = holder.store
        return TerminalSurface(holder: holder, palette: Theme.terminal,
                               font: ConsoleFonts.font(family: fontFamily, size: fontSize, ligatures: ligatures),
                               focusRequest: model.terminalFocusRequest, takesFocus: pane == paneID,
                               onFocus: split ? { [model, id] in model.focusPane(pane, in: id) } : nil,
                               onClose: split && pane != id ? { [model] in model.requestCloseSplit(pane) } : nil,
                               resolveFile: { [model] path in model.file(at: path, for: pane) },
                               resolveSession: { [model] row, column in model.sessionLink(in: row, column: column, from: pane) },
                               onResources: { [model, id] found in model.collectResources(found, for: id) },
                               onDropFiles: { [model] files in model.drop(files, into: pane, terminal: store) }
        ) { [model, id] url, external in
            model.openLink(url, from: id, external: external)
        }
        .padding(.leading, split ? 6 : 10).padding(.top, split ? 4 : 6)
        .background(Theme.background)
        .overlay { if store.status == .connecting { connecting } }
        .overlay(alignment: .bottomTrailing) { HistoryBadge(terminal: store) }
    }

    /// The session's tab as Herdr lays it out: each pane in its part of the area, a line between
    /// them, and the one you work in outlined.
    private func panes(_ split: [SplitPane]) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(split) { pane in
                    let paneID = Agent.ID(machineID: id.machineID, terminalID: pane.terminalID)
                    let frame = Self.place(pane.frame, in: geometry.size)
                    surface(of: paneID, split: true)
                        .overlay { Rectangle().strokeBorder(Theme.phosphor.opacity(paneID == self.paneID ? 0.55 : 0), lineWidth: 1) }
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .background(Theme.line)
    }

    /// A pane's part of the area in points, half a point short on each side it shares with another
    /// pane, so a line shows between them.
    static func place(_ part: CGRect, in size: CGSize) -> CGRect {
        let inner = (left: part.minX > 0.001, top: part.minY > 0.001, right: part.maxX < 0.999, bottom: part.maxY < 0.999)
        let minX = part.minX * size.width + (inner.left ? 0.5 : 0), maxX = part.maxX * size.width - (inner.right ? 0.5 : 0)
        let minY = part.minY * size.height + (inner.top ? 0.5 : 0), maxY = part.maxY * size.height - (inner.bottom ? 0.5 : 0)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    @ViewBuilder private var banners: some View {
        ToolsOfferBanner(machineID: context.machine.id, courier: model.courier,
                         machineName: MachineList.name(of: context.machine.machine, among: model.cluster.machines.map(\.machine),
                                                       macName: model.courier.tools.macName))
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
                StateGlyph(status: model.status(of: agent), background: !model.backgroundCommands(of: agent).isEmpty)
            } else {
                StateGlyph(status: model.status(for: id) ?? .shell)
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
                AgentMark(program: agent.agent.program, style: .tag)
                StateTag(status: model.status(of: agent))
            }
            Button { model.showFolder(of: id) } label: { Image(systemName: "folder").font(.system(size: 10.5, weight: .semibold)) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .disabled(model.localFolder(of: id) == nil)
                .help(model.folderHelp(for: id))
                .accessibilityLabel("Show the session's folder in Finder")
            lockButton
            Button { showDetails.toggle() } label: { Text("i") }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .help("Session details")
                .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                    SessionDetails(context: context, cluster: model.cluster).frame(width: 320)
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

    // MARK: Banners and states

    private func banner(_ message: String, dismiss: (() -> Void)? = nil, action: (String, () -> Void)? = nil) -> some View {
        // A connection that drops stays red while it reconnects, even between attempts.
        let failed = terminal.status == .failed || terminal.reconnection != nil
        let reconnection = dismiss == nil && action == nil ? terminal.reconnection : nil
        return HStack(alignment: .top, spacing: 10) {
            Text(failed ? "✗" : "!").font(Theme.mono(12, .bold))
            VStack(alignment: .leading, spacing: 3) {
                Text(message).font(Theme.mono(11.5)).textSelection(.enabled)
                if let detail = terminal.detail {
                    Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(4).textSelection(.enabled)
                }
                if let reconnection { ReconnectionLine(reconnection: reconnection) }
            }
            Spacer(minLength: 8)
            if let dismiss {
                Button("OK", action: dismiss).buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
            } else if let action {
                Button(action.0, action: action.1).buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
                    .disabled(terminal.status == .connecting)
                    .help("Detach the other client's input and control this terminal from Shepherdr")
            } else if terminal.status == .failed || terminal.status == .ended || reconnection != nil {
                Button("RECONNECT") { terminal.open() }.buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
                    .disabled(reconnection?.gaveUp == false)
                    .help(reconnection?.gaveUp == false ? "Shepherdr is reconnecting on its own" : "Reconnect to this terminal")
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
    /// As the column narrows (a small window, the browser open) the hint goes first, then the labels fall back to icons.
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            barContent(compact: false, hint: true)
            barContent(compact: false, hint: false)
            barContent(compact: true, hint: false)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private func barContent(compact: Bool, hint: Bool) -> some View {
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
            if hint {
                Text(isLive ? "⇧⏎ new line · click a link to browse · ⌘-click opens your browser" : "locked · read-only · ⌘E to unlock")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.head)
                    .layoutPriority(-1)
            }
            if !isCompass { panelToggles(compact: compact) }
        }
    }

    @ViewBuilder private func panelToggles(compact: Bool) -> some View {
        HStack(spacing: 6) {
            let links = workspace.visibleResources.count
            barToggle(compact ? (links > 0 ? "≡ \(links)" : "≡") : (links > 0 ? "≡ RESOURCES \(links)" : "≡ RESOURCES"),
                      active: showsResources && links > 0,
                      help: links > 0 ? "Pull requests, issues and Claude artifacts this session linked to"
                                      : "Pull requests, issues and Claude artifacts this session links to gather here") {
                showsResources.toggle()
            }
            .disabled(links == 0)
            let tabs = workspace.browser.tabs.count
            barToggle(compact ? (tabs > 0 ? "◫ \(tabs)" : "◫") : (tabs > 0 ? "◫ BROWSER \(tabs)" : "◫ BROWSER"),
                      active: workspace.browser.isVisible,
                      help: "This session's browser (⌘B). Its tabs stay open while you work elsewhere.") {
                model.toggleBrowser()
            }
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
    let cluster: ClusterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConsoleHeader(title: "Session")
            if let row = context.agent {
                field("Agent", "\(row.agent.program.name) · \(row.agent.program.label)")
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
            if let date = cluster.lastSuccess[context.machine.id] {
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
    @ViewState<Bool> private var picking = false

    var body: some View {
        let awaited = model.relations.waitingFor(id)
        let waiters = model.relations.waiters(of: id)
        if !awaited.isEmpty || !waiters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !awaited.isEmpty {
                    line(model.relations.isHeld(id) ? "ON HOLD · WAITING FOR" : "WAITED FOR, FINISHED",
                         ids: awaited, removable: true) {
                        Button { picking = true } label: { Text("+").font(Theme.mono(11, .bold)).contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.cyan)
                            .help("Find another session for this one to wait for")
                            .popover(isPresented: $picking, arrowEdge: .bottom) {
                                WaitForPicker(id: id, model: model) { picking = false }
                            }
                        Button("RESUME") { model.relations.stopWaiting(id) }
                            .buttonStyle(ConsoleButtonStyle(tint: Theme.cyan))
                            .help("Stop waiting: clear this session's hold")
                    }
                }
                if !waiters.isEmpty {
                    line("WAITED ON BY", ids: waiters, removable: false) { HandoffCloseControl(id: id, model: model) }
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
        let shell = row == nil ? model.shell(for: other) : nil
        let status = model.status(for: other)
        return HStack(spacing: 6) {
            if let row, let status {
                StateGlyph(status: status, background: !model.backgroundCommands(of: row).isEmpty)
                Text(row.workspace).foregroundStyle(Theme.text)
                if model.showsMachineNames { Text("@\(row.machineName)").foregroundStyle(Theme.faint) }
                Text(status.label).foregroundStyle(Theme.dim)
            } else if let shell, let status {
                // Waited for until its command finishes, which ends the wait.
                StateGlyph(status: status)
                Text(shell.pane.workspaceName).foregroundStyle(Theme.text)
                if model.showsMachineNames { Text("@\(shell.machine.name)").foregroundStyle(Theme.faint) }
                Text(status.label).foregroundStyle(Theme.dim)
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
        .onTapGesture { if row != nil || shell != nil { model.open(other) } }
        .help(row.map { "Open \($0.workspace)" } ?? shell.map { "Open \($0.pane.workspaceName). The wait ends when the command it runs finishes." }
              ?? "This session is no longer reported by Herdr. Unless it comes back, Shepherdr stops waiting for it shortly.")
    }
}

/// Hands a session's work back to the sessions waiting for it, then closes it: Shepherdr asks its
/// agent to run `shepherdr handoff` once it is free, and closes the session when the handoff arrives.
struct HandoffCloseControl: View {
    let id: Agent.ID
    let model: AppModel
    @ViewState<Bool> private var confirming = false

    var body: some View {
        let courier = model.courier
        if let close = courier.handoffCloses[id] {
            HStack(spacing: 6) {
                Text(close.stage == .queued ? "HANDS OFF ONCE FREE" : "HANDING OFF")
                    .font(Theme.mono(9.5, .bold)).tracking(1).foregroundStyle(Theme.cyan).fixedSize()
                BlinkingCursor()
                Button("CANCEL") { courier.cancelHandoffClose(id) }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .help("Keep this session open. A request already in its agent's prompt stays there.")
            }
            .help(close.stage == .queued
                  ? "Shepherdr asks its agent to hand off as soon as it is free, then closes this session once the handoff arrives."
                  : "Its agent was asked to hand off. Shepherdr closes this session once the handoff arrives.")
        } else {
            let reason = courier.whyNoHandoffClose(id)
            // Disabled buttons don't show their help, so it goes on what holds them.
            HStack {
                Button("HANDOFF AND CLOSE") { confirming = true }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.cyan))
                    .disabled(reason != nil)
            }
            .contentShape(Rectangle())
            .help(reason ?? "Ask its agent to hand its work back to the sessions waiting for it, then close this session")
            .confirmationDialog("Hand off and close \(model.row(for: id)?.workspace ?? "this session")?", isPresented: $confirming,
                                titleVisibility: .visible) {
                Button("Hand Off and Close", role: .destructive) { courier.handOffAndClose(id) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
        }
    }

    private var message: String {
        let waiters = model.relations.waiters(of: id).compactMap { model.row(for: $0)?.workspace }
        let who = waiters.isEmpty ? "the sessions waiting for it" : waiters.joined(separator: ", ")
        return "Once its agent is free, Shepherdr asks it to hand its work back to \(who) with shepherdr handoff. "
            + "When the handoff reaches Shepherdr, this session closes and its pane ends. "
            + "If none comes within \(Int(HandoffClose.patience / 60)) minutes of asking, the session stays open."
    }
}

/// Finds a session for another one to wait for from a few letters of it: ↑ and ↓ move through the
/// matches, and Return or a click puts the session on hold for the highlighted one, or stops it
/// waiting for one it already waits for (✓). Either closes the picker, as Escape does.
struct WaitForPicker: View {
    let id: Agent.ID
    let model: AppModel
    /// Closes the sheet or popover the picker is in.
    let close: () -> Void
    @ViewState<String> private var query = ""
    @ViewState<Int> private var highlighted = 0

    var body: some View {
        let others = model.rankedRows.filter { $0.id != id }
        let matches = SessionSearch.ranked(others, matching: query)
        let current = matches.isEmpty ? nil : min(highlighted, matches.count - 1)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("WAIT FOR").font(Theme.mono(12, .bold)).tracking(1.5).foregroundStyle(Theme.cyan)
                Text("\(model.row(for: id)?.workspace ?? "This session") goes on hold until they finish")
                    .font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            HStack(spacing: 6) {
                Text("/").font(Theme.mono(12, .bold)).foregroundStyle(Theme.phosphor)
                PickerSearchField(text: $query, placeholder: model.showsMachineNames ? "name, or name@machine" : "session name",
                                  move: { step in
                                      guard !matches.isEmpty else { return }
                                      highlighted = max(0, min(matches.count - 1, (current ?? 0) + step))
                                  },
                                  submit: { if let current { toggle(matches[current]) } },
                                  cancel: close)
                    .frame(height: 18)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.phosphor.opacity(0.6), lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 8)
            Rectangle().fill(Theme.line).frame(height: 1)
            list(matches, current: current, isEmpty: others.isEmpty)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 10) {
                Text("↑↓ choose · ⏎ wait for it · ✓ waited for").font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
                Spacer(minLength: 4)
                Button("CLOSE", action: close).buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 400)
        .background(Theme.panel)
        .onChange(of: query) { highlighted = 0 }
    }

    private func list(_ matches: [AgentRow], current: Int?, isEmpty: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, row in
                        PickerRow(row: row, status: model.status(of: row), isHighlighted: index == current, isWaited: model.relations.isWaiting(id, for: row.id),
                                  showsMachine: model.showsMachineNames,
                                  background: !model.backgroundCommands(of: row).isEmpty) { toggle(row) }
                            .id(row.id)
                    }
                    if matches.isEmpty {
                        Text(isEmpty ? "no other sessions" : "no session matches \"\(query)\"")
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                            .padding(.horizontal, 14).padding(.vertical, 12)
                    }
                }
            }
            .frame(height: 260)
            .onChange(of: current) { _, new in if let new { proxy.scrollTo(matches[new].id) } }
        }
    }

    private func toggle(_ row: AgentRow) {
        model.relations.setWaiting(id, for: row.id, !model.relations.isWaiting(id, for: row.id))
        close()
    }
}

/// One session the picker offers: its state, name, machine and task, and ✓ when it is waited for.
private struct PickerRow: View {
    let row: AgentRow
    let status: SessionStatus
    let isHighlighted: Bool
    let isWaited: Bool
    let showsMachine: Bool
    let background: Bool
    let choose: () -> Void
    @ViewState<Bool> private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 8) {
                StateGlyph(status: status, background: background)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(row.workspace).font(Theme.mono(12, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if showsMachine {
                            Text("@\(row.machineName)").font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                    }
                    Text(row.title).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 4)
                if isWaited { Text("✓").font(Theme.mono(12, .bold)).foregroundStyle(Theme.cyan) }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.phosphor).frame(width: 2).opacity(isHighlighted ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isWaited ? "Stop waiting for \(row.workspace)" : "Wait for \(row.workspace)")
        .accessibilityLabel("\(row.workspace), \(status.label)\(isWaited ? ", waited for" : "")")
        .accessibilityAddTraits(isWaited ? .isSelected : [])
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
                .help("Stop and transcribe into the prompt editor (⇧⌘M)")
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
                .help(dictation.isReady ? "Dictate a prompt (⇧⌘M). It is transcribed on this Mac."
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

/// When the dropped terminal tries again, or how many times it tried before giving up.
private struct ReconnectionLine: View {
    let reconnection: TerminalStore.Reconnection

    var body: some View {
        Group {
            if reconnection.gaveUp {
                Text("Tried to reconnect \(reconnection.attempts) time\(reconnection.attempts == 1 ? "" : "s") over an hour. Please reconnect manually.")
            } else if let next = reconnection.next {
                // The countdown stops while the Mac sleeps, as the wait does.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = SuspendingClock.now.duration(to: next)
                    let seconds = max(1, Int(left.components.seconds) + (left.components.attoseconds > 0 ? 1 : 0))
                    Text("Reconnecting in \(Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) (attempt \(reconnection.attempts + 1))")
                }
            } else {
                Text("Reconnecting… (attempt \(reconnection.attempts))")
            }
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.amber)
    }
}

/// The terminal, or the overview, beside its browser. The browser opens at half the width (an
/// HSplitView would open it at its minimum), and the divider between them can be dragged.
struct BrowserSplit<Terminal: View, Browser: View>: View {
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
