import SwiftUI
import ShepherdrCore
import ShepherdrTerminalUI

// Use the public State property wrapper explicitly. This also supports SDKs that
// export a same-named macro unavailable to standalone command-line toolchains.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct ShepherdrApp: App {
    @ViewState<AppModel> private var model = AppModel()

    init() {
        ConsoleFonts.registerBundled()
        // One window, never merged into tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        Window("Shepherdr", id: "main") {
            MainView(model: model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .defaultSize(width: 1_280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session…") { model.startNewSession() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(model.onlineMachines.isEmpty)
                Button("New Session in Same Folder…") {
                    if let id = model.selectedID { model.startNewSession(besides: id) }
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!(model.selectedID.map(model.canStartNewSession(besides:)) ?? false))
                Divider()
                Button("Refresh Sessions") { Task { await model.cluster.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.cluster.isRefreshing)
            }
            CommandMenu("Session") {
                Button("Overview") { model.selection = .overview }
                    .keyboardShortcut("0", modifiers: .command)
                Button("Next Session") { model.step(1) }
                    .keyboardShortcut("]", modifiers: .command)
                Button("Previous Session") { model.step(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button("Prompt Editor") { model.togglePromptEditor() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(model.activeTerminal == nil)
                Button("Browser") { model.toggleBrowser() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(model.selectedID == nil)
                Button(model.dictation.isRecording ? "Stop Dictation" : "Dictate Prompt") { model.toggleDictation() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.selectedID == nil && !model.dictation.isRecording)
                Button(model.activeTerminal?.mode == .observe ? "Unlock Session" : "Lock Session (Read-Only)") { model.toggleLive() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(!model.canToggleLive)
                Button("Send Escape") { model.activeTerminal?.press(.escape) }
                    .keyboardShortcut(.escape, modifiers: .command)
                    .disabled(model.activeTerminal?.status != .interactive)
                Divider()
                ForEach(0..<9, id: \.self) { position in
                    Button(sessionTitle(position)) { model.open(position: position) }
                        .keyboardShortcut(KeyEquivalent(Character("\(position + 1)")), modifiers: .command)
                        .disabled(!model.visibleRows.indices.contains(position))
                }
                Divider()
                Button("Raise Priority") { model.moveSelection(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(!model.canMove(model.selectedID, .up))
                Button("Lower Priority") { model.moveSelection(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(!model.canMove(model.selectedID, .down))
                Button("Move to Top") { model.moveSelection(.first) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option, .shift])
                    .disabled(!model.canMove(model.selectedID, .first))
                Divider()
                Button("New Group…") { model.promptNewGroup(with: model.selectedID) }
            }
            CommandGroup(replacing: .help) {
                Link("Herdr Documentation", destination: URL(string: "https://herdr.dev/docs/")!)
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }

    private func sessionTitle(_ position: Int) -> String {
        guard model.visibleRows.indices.contains(position) else { return "Session \(position + 1)" }
        let row = model.visibleRows[position]
        return "\(row.workspace) — \(row.title)"
    }
}
