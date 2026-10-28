import AppKit
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
    /// Kept by the model while the session is out of sight, with what it last showed.
    private let holder: TerminalHolder
    private var terminal: TerminalStore { holder.store }
    @ViewState<Bool> private var showDetails = false
    /// The model and effort its agent runs with, read from the agent's own files.
    @ViewState<AgentRunInfo?> private var runInfo: AgentRunInfo? = nil
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
    }

    private var id: Agent.ID { .init(machineID: context.machine.id, terminalID: context.target.terminalID) }
    private var isLive: Bool { terminal.status == .interactive }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            if !isCompass { RelationsPanel(id: id, model: model) }
            MailPanel(session: id, model: model)
            // The content sits in cards on the panel's shade rather than on the bare background.
            HStack(spacing: 8) {
                workArea.card()
                if showsResources && !isCompass && !workspace.visibleResources.isEmpty {
                    ResourcesPanel(workspace: workspace, checks: model.checksMonitor, close: { showsResources = false },
                                   refresh: { [model, id] in await model.refreshResources(for: id) })
                        .frame(width: 230)
                        .card()
                }
            }
            .padding(8)
            .background(Theme.panel)
            statusBar
        }
        .background(Theme.background)
        .onAppear { model.activeTerminal = terminal }
        .onDisappear {
            // What you typed in Compass's terminal still counts off screen, such as against starting its agent again.
            if isCompass, let input = terminal.lastInput { model.compass.noteTyping(at: input) }
            if model.activeTerminal === terminal { model.activeTerminal = nil }
        }
        .task(id: id) {
            // Once the terminal is attached: Herdr refuses an attach while a read of the pane runs.
            for _ in 0..<50 where terminal.status == .connecting || terminal.status == .disconnected {
                try? await Task.sleep(for: .milliseconds(100))
            }
            await model.harvestResources(for: id)
        }
        .task(id: id) { await followRunInfo() }
    }

    private var workArea: some View {
        BrowserSplit(showsBrowser: workspace.browser.isVisible && !isCompass) {
            VStack(spacing: 0) {
                banners
                if context.canConnect {
                    TerminalSurface(holder: holder, palette: Theme.terminal,
                                    font: ConsoleFonts.font(family: fontFamily, size: fontSize, ligatures: ligatures),
                                    focusRequest: model.terminalFocusRequest,
                                    resolveFile: { [model, id] path in model.file(at: path, for: id) },
                                    resolveSession: { [model, id] row, column in model.sessionLink(in: row, column: column, from: id) },
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
            }
        } browser: {
            BrowserPanel(browser: workspace.browser)
        }
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
            banner("This session is being typed in from somewhere else, so it's read-only here.",
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
            HStack(spacing: 8) {
                Text(context.target.workspace).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
                    .lineLimit(1).layoutPriority(1)
                Text("›").font(Theme.mono(13)).foregroundStyle(Theme.faint)
                Text(context.title).font(Theme.mono(13)).foregroundStyle(Theme.text.opacity(0.75)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let agent = context.agent {
                StateTag(status: model.status(of: agent))
            }
            Button { model.showFolder(of: id) } label: { Image(systemName: "folder").font(.system(size: 10.5, weight: .semibold)) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .disabled(model.localFolder(of: id) == nil)
                .help(model.folderHelp(for: id))
                .accessibilityLabel("Show the session's folder in Finder")
            lockButton
            divider
            if !isCompass {
                tools
                divider
            }
            detailsButton
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.panel)
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 16)
    }

    private var detailsButton: some View {
        Button { showDetails.toggle() } label: { iconLabel("info.circle") }
            .buttonStyle(ConsoleButtonStyle(tint: showDetails ? Theme.phosphor : Theme.dim))
            .help("Session details")
            .accessibilityLabel("Session details")
            .popover(isPresented: $showDetails, arrowEdge: .bottom) {
                SessionDetails(context: context, cluster: model.cluster,
                               checkout: context.agent.flatMap {
                                   model.cluster.checkout(machineID: $0.id.machineID, workspaceID: $0.agent.workspaceID)
                               },
                               background: context.agent.map { model.backgroundCommands(of: $0) } ?? [])
                    .frame(width: 320)
            }
    }

    // MARK: Session tools

    /// The session's resources and its browser, as icons.
    private var tools: some View {
        HStack(spacing: 4) {
            resourcesButton
            browserButton
        }
    }

    private func iconLabel(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 16, height: 14)
    }

    private var promptButton: some View {
        let hasDraft = !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button { model.togglePromptEditor() } label: { iconLabel("square.and.pencil") }
            .buttonStyle(ConsoleButtonStyle(tint: workspace.isEditorOpen ? Theme.phosphor : Theme.dim))
            .overlay(alignment: .topTrailing) {
                // A draft waits in the closed editor.
                if hasDraft && !workspace.isEditorOpen {
                    Circle().fill(Theme.phosphor).frame(width: 6, height: 6).offset(x: 2, y: -2)
                }
            }
            .help(hasDraft && !workspace.isEditorOpen ? "Prompt editor, with a draft waiting (⌘L)" : "Prompt editor (⌘L)")
            .accessibilityLabel(hasDraft && !workspace.isEditorOpen ? "Prompt editor, draft waiting" : "Prompt editor")
    }

    private var resourcesButton: some View {
        let links = workspace.visibleResources.count
        return Button { showsResources.toggle() } label: {
            HStack(spacing: 4) {
                iconLabel("list.bullet.rectangle")
                if links > 0 { Text("\(links)").font(Theme.mono(10, .semibold)) }
            }
        }
        .buttonStyle(ConsoleButtonStyle(tint: showsResources && links > 0 ? Theme.phosphor : Theme.dim))
        .disabled(links == 0)
        .help(links > 0 ? "Pull requests, issues and Claude artifacts this session linked to"
                        : "Pull requests, issues and Claude artifacts this session links to will gather here")
        .accessibilityLabel(links > 0 ? "Resources, \(links)" : "Resources")
    }

    private var browserButton: some View {
        Button { model.toggleBrowser() } label: { iconLabel("globe") }
            .buttonStyle(ConsoleButtonStyle(tint: workspace.browser.isVisible ? Theme.phosphor : Theme.dim))
            .help("This session's browser (⌘B). Its tabs stay open while you work elsewhere.")
            .accessibilityLabel("Browser")
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

    // MARK: Status bar

    /// Under the whole work area, whatever is beside the terminal: the prompt editor and dictation on the left, followed by
    /// where we are (agent, model, effort); the subscription's consumption on the right.
    private var statusBar: some View {
        HStack(spacing: 10) {
            promptButton
            DictationButton(model: model, id: id, compact: true)
            place.padding(.leading, 6)
            Spacer(minLength: 8)
            if let usage = subscriptionUsage { subscription(usage) }
        }
        .padding(.horizontal, 16).padding(.vertical, 5)
        .background(Theme.panel)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    /// The Claude subscription's limits, each with two thin lines: what is used, and how much of the
    /// window has passed. The used line running ahead of the time line means burning faster than time.
    private func subscription(_ usage: SubscriptionUsage) -> some View {
        HStack(spacing: 14) {
            if let window = usage.session { limit("5h", window, length: SubscriptionUsage.sessionLength) }
            if let window = usage.week { limit("week", window, length: SubscriptionUsage.weekLength) }
        }
        .font(Theme.mono(10.5))
        .padding(.trailing, 6)
    }

    private func limit(_ name: String, _ window: SubscriptionUsage.Window, length: TimeInterval) -> some View {
        let tint: Color = window.percent >= 95 ? Theme.red : window.percent >= 80 ? Theme.amber : Theme.phosphor
        let exact = window.resetsAt.map { "Starts again " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "No reset time reported"
        return TimelineView(.everyMinute) { context in
            let passed = window.elapsed(of: length, now: context.date)
            HStack(spacing: 6) {
                Text(name).foregroundStyle(Theme.faint)
                VStack(spacing: 2) {
                    UsageLine(fraction: window.utilization / 100, tint: tint)
                    UsageLine(fraction: passed ?? 0, tint: Theme.cyan.opacity(0.7)).opacity(passed == nil ? 0.3 : 1)
                }
                .frame(width: 64)
                Text("\(window.percent)%").foregroundStyle(tint).fontWeight(.semibold)
                if let reset = window.resetsAt {
                    Text(SubscriptionUsage.untilReset(reset, now: context.date)).foregroundStyle(Theme.faint)
                }
            }
        }
        .help("Claude subscription, \(name == "5h" ? "five-hour" : "weekly") limit: \(window.percent)% used"
              + (window.elapsed(of: length).map { ", \(Int(($0 * 100).rounded()))% of the time gone" } ?? "") + ". \(exact).")
        .accessibilityElement(children: .combine)
    }

    /// The subscription of the session's agent, when this Mac knows its usage.
    private var subscriptionUsage: SubscriptionUsage? {
        switch context.agent?.agent.program.label {
        case "claude": model.subscriptions.claude
        case "codex": model.subscriptions.codex
        default: nil
        }
    }

    /// Reads the agent's model and effort again every few seconds: `/model` changes them mid-session.
    /// Only sessions on this Mac have their files here.
    private func followRunInfo() async {
        guard context.machine.machine.isLocal, let agent = context.agent?.agent, let directory = agent.directory,
              ["claude", "codex"].contains(agent.program.label) else { runInfo = nil; return }
        let isClaude = agent.program.label == "claude"
        while !Task.isCancelled {
            let info = await Task.detached {
                isClaude ? AgentTranscripts().claude(directory: directory) : AgentTranscripts().codex(directory: directory)
            }.value
            if info != runInfo { runInfo = info }
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// The agent the session runs with its model and effort, or Terminal when it is a plain shell.
    private var place: some View {
        HStack(spacing: 6) {
            if let program = context.agent?.agent.program {
                AgentMark(program: program, style: .glyph)
                Text(program.name)
                if let model = runInfo?.modelTitle { Text("·").foregroundStyle(Theme.faint); Text(model).foregroundStyle(Theme.text.opacity(0.85)) }
                if let effort = runInfo?.effort { Text("·").foregroundStyle(Theme.faint); Text(effort).foregroundStyle(Theme.phosphor) }
            } else {
                Text("$").foregroundStyle(Theme.phosphor)
                Text("Terminal")
            }
        }
        .font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
        .help(runInfo.map { "Model: \($0.model ?? "unknown"). Effort: \($0.effort ?? "unknown"). Read from this session's own files." }
              ?? "Where this session runs")
        .accessibilityElement(children: .combine)
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
                    .help("Stop the other input and control this session from here")
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
            Text(context.machine.connection.title).font(Theme.mono(13, .semibold)).foregroundStyle(Theme.amber)
            Text(context.machine.failure?.message ?? "This machine is not reachable right now.")
                .font(Theme.mono(11)).foregroundStyle(Theme.dim).multilineTextAlignment(.center)
            if context.isStale { Text("Showing the last known state").font(Theme.mono(10)).foregroundStyle(Theme.faint) }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Composer

    private var draft: Binding<String> {
        Binding { model.drafts[id] ?? "" } set: { model.drafts[id] = $0 }
    }

    /// The optional editor for long prompts, opened from the header or with ⌘L.
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

    private var placeholder: String {
        switch terminal.status {
        case .interactive: "Message \(context.target.workspace)…"
        case .connecting: "Connecting…"
        default: terminal.isControlledElsewhere ? "Typed in elsewhere. Take over to send."
                                                 : "Read-only. Write a draft here and unlock to send."
        }
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

/// The selected session in plain terms first, then the Herdr details behind it.
struct SessionDetails: View {
    let context: SessionContext
    let cluster: ClusterStore
    /// Its repository checkout, when it has one.
    let checkout: WorkspaceCheckout?
    /// What its agent left running.
    let background: [BackgroundCommand]

    var body: some View {
        let machine = context.machine.machine
        VStack(alignment: .leading, spacing: 12) {
            ConsoleHeader(title: "Session")
            if let row = context.agent {
                field("Agent", row.agent.program.name)
                field("State", row.agent.state == .unknown ? "Unknown (\(row.agent.reportedState))" : row.agent.state.title)
            }
            field("Machine", machine.isLocal ? "This Mac" : machine.name)
            if let row = context.agent {
                field("Folder", row.agent.directory ?? row.agent.project ?? "Not reported")
            }
            if let branch = checkout?.branch {
                field("Branch", branch + (checkout?.isLinkedWorktree == true ? " (worktree)" : ""))
            }
            if !background.isEmpty {
                field("Still running", background
                    .map { "\($0.command) (\(BackgroundLabel.duration(Int(-$0.started.timeIntervalSinceNow))))" }
                    .joined(separator: "\n"))
            }
            VStack(alignment: .leading, spacing: 2) {
                label("For other agents")
                PaneIDButton(paneID: context.paneID, workspace: context.target.workspace, machine: machine)
                Text("Copy this ID into another agent's prompt so it can message this session.")
                    .font(Theme.mono(9.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            Text("Herdr").font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.faint)
            if let row = context.agent {
                field("Tab", "\(row.agent.tabName) · \(row.agent.tabID)")
                field("Pane", row.agent.paneID)
            } else {
                field("Pane", context.target.title)
            }
            field("Herdr session", machine.session)
            field("Terminal ID", context.target.terminalID)
            if let date = cluster.lastSuccess[context.machine.id] {
                field("Last received", date.formatted(date: .abbreviated, time: .standard))
            }
            if context.agent?.agent.isLaunchPending == true { field("Launch pending", "Waiting for Herdr") }
            Text("Leaving a session keeps it running.")
                .font(Theme.mono(9.5)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .textSelection(.enabled)
        .background(Theme.panel)
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.faint)
    }

    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            label(title)
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
                .help("Stop and transcribe into the prompt editor (⇧⌘D)")
                .accessibilityLabel("Stop dictation")
                Button { model.cancelDictation() } label: { Text("×") }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .help("Discard this recording")
                    .accessibilityLabel("Discard recording")
                modelStatus(dictation.model)
            } else if case .transcribing = dictation.state, mine {
                Text(compact ? "…" : dictation.model == .ready ? "TRANSCRIBING…" : "LOADING MODEL…")
                    .font(Theme.mono(11, .semibold)).foregroundStyle(Theme.phosphor).fixedSize()
                    .frame(minWidth: 16, minHeight: 14)
                    .help(dictation.model == .ready ? "Transcribing your recording…" : "Loading the speech model…")
                    .accessibilityLabel(dictation.model == .ready ? "Transcribing" : "Loading the speech model")
                modelStatus(dictation.model)
            } else {
                Button { model.toggleDictation() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "mic.fill").font(.system(size: compact ? 11 : 10, weight: .semibold))
                            .frame(width: compact ? 16 : nil, height: compact ? 14 : nil)
                        if !compact { Text("DICTATE") }
                    }
                }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .fixedSize()
                .disabled(!dictation.isReady)
                .help(dictation.isReady ? "Dictate a prompt (⇧⌘D). It is transcribed on this Mac."
                                        : "Dictation is busy with another session")
                .accessibilityLabel("Dictate a prompt")
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

/// A thin line filled to `fraction`, in the console's line color behind it.
private struct UsageLine: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        Theme.line.overlay(alignment: .leading) {
            GeometryReader { proxy in tint.frame(width: proxy.size.width * min(1, max(0, fraction))) }
        }
        .frame(height: 3).clipShape(Capsule())
    }
}
