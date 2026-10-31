import AppKit
import SwiftUI
import ShepherdrCore
import ShepherdrDictation

/// Sidebar queue on the left, the selected session's live terminal in the work area.
struct MainView: View {
    @Bindable var model: AppModel
    @AppStorage("refreshSeconds") private var refreshSeconds = 5
    @AppStorage("openMode") private var openMode = TerminalMode.control.rawValue
    @Environment(\.openWindow) private var openWindow
    /// Whether this is Shepherdr's one window; unknown until it is placed in a window.
    @ViewState<Bool?> private var isMainWindow: Bool? = nil

    private var cluster: ClusterStore { model.cluster }

    /// Only one window may exist. Another one, however it was opened, shows nothing, closes, and
    /// brings the main window forward.
    var body: some View {
        Group {
            if isMainWindow == true { content } else { Theme.background }
        }
        .background(WindowReader { window in isMainWindow = model.adopt(window) })
        // Notifications and other external events go to this window rather than a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    // In layers: as one expression it takes older compilers too long to type-check.
    private var content: some View { dialogs(on: tracking) }

    private var layout: some View {
        HSplitView {
            VStack(spacing: 0) {
                Group {
                    if model.mode == .compass { CompassSidebar(model: model, compass: model.compass) } else { SessionSidebar(model: model) }
                }
                .frame(maxHeight: .infinity)
                UpdateBanner(updates: model.updates)
            }
            .background(Theme.panel)
            .frame(minWidth: 250, idealWidth: 280, maxWidth: 340)
            Group {
                if model.mode == .compass { CompassWorkArea(model: model, compass: model.compass) } else { workArea }
            }
            .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        }
        // In the strip the hidden title bar leaves beside the window's buttons.
        .overlay(alignment: .topLeading) { ModeTabs(model: model).padding(.leading, 78).padding(.top, 8) }
        // ⌘T, over everything else.
        .overlay { if model.isSwitching { QuickSwitcher(model: model) } }
        .background(Theme.background)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .tint(Theme.phosphor)
    }

    /// Refreshing Herdr and following what each refresh brings.
    private var tracking: some View {
        layout
        .task {
            configureRefresh()
            await cluster.monitor()
        }
        .task { await model.watchBackgroundWork() }
        .task { await model.watchCaches() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.closeTerminals()
            model.saveCaches()
        }
        .onAppear { model.compass.start() }
        .onAppear { model.updates.start() }
        .onAppear { model.subscriptions.start() }
        .onChange(of: refreshSeconds) { configureRefresh() }
        .onChange(of: cluster.agents.map(\.id), initial: true) {
            model.order.synchronize(with: model.agents.map(\.id))
        }
        .onChange(of: cluster.agents, initial: true) { model.notifier.observe(model.agents) }
        .onChange(of: cluster.lastRefresh, initial: true) {
            model.restoreSelection()
            model.keepHolds()
            model.learnRepositories()
            model.courier.observe()
            model.compass.observe()
        }
        .onAppear { model.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            if cluster.automaticRefresh { Task { await cluster.refresh() } }
            // A run the Mac slept through happens now, once.
            model.compass.tick()
        }
    }

    private func dialogs(on view: some View) -> some View {
        view
        .alert("Rename Session", isPresented: Binding { model.renaming != nil } set: { if !$0 { model.renaming = nil } }) {
            TextField("Name", text: Binding { model.renaming?.name ?? "" } set: { model.renaming?.name = $0 })
                // A field of its own for each prompt: the alert otherwise reuses the last one, often
                // still empty from when that prompt was dismissed, and Rename then takes only what you type.
                .id(model.renaming?.id)
            Button("Rename") {
                guard let prompt = model.renaming else { return }
                Task { await model.commitRename(prompt) }
            }
            Button("Cancel", role: .cancel) { model.renaming = nil }
        } message: {
            Text("Other sessions in the same workspace share this name.")
        }
        .sheet(item: $model.newSession) { draft in NewSessionSheet(model: model, draft: draft) }
        .sheet(item: $model.waitPicking) { picking in
            WaitForPicker(id: picking.session, model: model) { model.waitPicking = nil }
        }
        .sheet(isPresented: $model.showsGitHubRepositoriesSheet) { GitHubRepositoriesSheet(model: model) }
        .alert("Download the speech model?", isPresented: $model.asksToDownloadSpeechModel) {
            Button("Download") { model.acceptSpeechModelDownload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Dictation transcribes on this Mac with NVIDIA Parakeet v3, the model scribe uses. It needs a one-time download of \(Dictation.modelDownloadSize) from Hugging Face. Your voice never leaves this Mac.")
        }
        .confirmationDialog(closeTitle, isPresented: Binding { model.closingSession != nil } set: { if !$0 { model.closingSession = nil } },
                            titleVisibility: .visible, presenting: model.closingSession) { id in
            Button("Close Session", role: .destructive) { Task { await model.closeSession(id) } }
            Button("Cancel", role: .cancel) { model.closingSession = nil }
        } message: { id in
            Text(closeMessage(id))
        }
        .confirmationDialog("Close this split?", isPresented: Binding { model.closingSplit != nil } set: { if !$0 { model.closingSplit = nil } },
                            titleVisibility: .visible, presenting: model.closingSplit) { id in
            Button("Close Split", role: .destructive) { Task { await model.closeSplit(id) } }
            Button("Cancel", role: .cancel) { model.closingSplit = nil }
        } message: { id in
            Text(closeSplitMessage(id))
        }
        .alert(model.actionFailure?.message ?? "", isPresented: Binding { model.actionFailure != nil } set: { if !$0 { model.actionFailure = nil } }) {
            Button("OK") { model.actionFailure = nil }
        } message: {
            Text(model.actionFailure?.detail ?? "")
        }
    }

    @ViewBuilder private var workArea: some View {
        switch model.selection {
        case .overview:
            BrowserSplit(showsBrowser: model.overviewBrowser.isVisible) {
                OverviewView(model: model)
            } browser: {
                BrowserPanel(browser: model.overviewBrowser)
            }
        case .session(let id):
            if let context = model.context(for: id) {
                SessionView(context: context, model: model, mode: TerminalMode(rawValue: openMode) ?? .control)
                    .id(context.target)
            } else {
                ended
            }
        }
    }

    private var ended: some View {
        VStack(spacing: 12) {
            Text("This session has ended").font(Theme.mono(14, .bold)).foregroundStyle(Theme.dim)
            Text("It's no longer running.").font(Theme.mono(11)).foregroundStyle(Theme.faint)
            Button("Back to Overview") { model.selection = .overview }.buttonStyle(ConsoleButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private var closeTitle: String {
        guard let id = model.closingSession, let context = model.context(for: id) else { return "Close session?" }
        return "Close \(context.target.workspace)?"
    }

    private func closeMessage(_ id: Agent.ID) -> String {
        guard let context = model.context(for: id) else { return "" }
        let what = context.agent.map { "ends \($0.agent.program.name) and closes" } ?? "closes"
        return "This \(what) the session\(context.machine.machine.isLocal ? "" : " on \(context.machine.machine.name)"). "
            + "This can't be undone."
    }

    private func closeSplitMessage(_ id: Agent.ID) -> String {
        guard let context = model.context(for: id) else { return "" }
        let what = context.agent.map { "\($0.agent.program.name) runs" } ?? "A command may be running"
        return "\(what) in pane \(context.paneID). Closing the split ends it in Herdr. This cannot be undone."
    }

    private func configureRefresh() {
        cluster.automaticRefresh = refreshSeconds > 0
        cluster.refreshInterval = TimeInterval(max(5, refreshSeconds))
    }
}

/// Reports the window a view is placed in.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        var found: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After this layout pass: the answer changes what the view shows.
            DispatchQueue.main.async { [found] in found?(window) }
        }
    }
}

