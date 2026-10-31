import AppKit
import SwiftUI
import ShepherdrCore
import ShepherdrTerminalUI

/// Machines change rarely, so they live here rather than in the main window.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView {
            GeneralSettings(updates: model.updates)
                .tabItem { Label("General", systemImage: "slider.horizontal.3") }
            MachineSettings(model: model)
                .tabItem { Label("Machines", systemImage: "server.rack") }
            AgentSettings(model: model)
                .tabItem { Label("Agents", systemImage: "envelope") }
            CompassSettings(model: model, compass: model.compass)
                .tabItem { Label("Compass", systemImage: "safari") }
        }
        .frame(width: 580, height: 520)
        .preferredColorScheme(.dark)
        .tint(Theme.phosphor)
    }
}

private struct GeneralSettings: View {
    let updates: UpdateController
    @AppStorage("refreshSeconds") private var refreshSeconds = 5
    @AppStorage("openMode") private var openMode = TerminalMode.control.rawValue
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("terminalFontFamily") private var fontFamily = ConsoleFonts.defaultFamily
    @AppStorage(ConsoleFonts.ligaturesKey) private var ligatures = false
    @AppStorage(ProjectsFolder.key) private var projectsFolder = ProjectsFolder.defaultPath
    @AppStorage(SessionNotifier.enabledKey) private var notifies = true
    @ViewState<[String]> private var families: [String] = [ConsoleFonts.defaultFamily]

    var body: some View {
        Form {
            Section("Sessions") {
                Picker("Open sessions", selection: $openMode) {
                    Text("Unlocked — type and send prompts").tag(TerminalMode.control.rawValue)
                    Text("Locked — read-only").tag(TerminalMode.observe.rawValue)
                }
                Text("If someone else is already using a session, Shepherdr only watches it and offers Take Over.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Refresh sessions", selection: $refreshSeconds) {
                    Text("Every 5 seconds").tag(5)
                    Text("Every 15 seconds").tag(15)
                    Text("Every 30 seconds").tag(30)
                    Text("Every minute").tag(60)
                    Text("Paused").tag(0)
                }
                LabeledContent("Projects folder") {
                    HStack(spacing: 8) {
                        Text(projectsFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseProjectsFolder() }
                    }
                }
                Text("New Session starts here, and GitHub projects are copied here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("A folder name alone means a folder inside it. Other machines have their own projects folder in Machines.")
            }
            UpdateSettings(updates: updates)
            Section("Notifications") {
                Toggle("Notify when an agent finishes or needs you", isOn: $notifies)
                Text("Click a notification to open its session.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("A notification shows the session, its state and what the agent last said. The session you are looking at never notifies.")
            }
            Section("Terminal font") {
                Picker("Font", selection: $fontFamily) {
                    ForEach(families, id: \.self) { family in
                        Text(family == ConsoleFonts.defaultFamily ? "\(family) (default)" : family).tag(family)
                    }
                }
                Stepper(value: $fontSize, in: 10...22, step: 1) {
                    Text("Size: \(Int(fontSize)) pt")
                }
                Toggle("Ligatures", isOn: $ligatures)
                    .help("Join characters such as -> and != into single symbols, in fonts that have them")
                Text("❯ claude --resume  # -> != === 0x1F")
                    .font(Font(ConsoleFonts.font(family: fontFamily, size: fontSize, ligatures: ligatures)))
                    .foregroundStyle(Theme.phosphor)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
                Text("Used by the terminal and the prompt editor. Only fixed-width fonts are listed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            families = ConsoleFonts.monospacedFamilies()
            if !families.contains(fontFamily) { fontFamily = ConsoleFonts.defaultFamily }
        }
    }

    private func chooseProjectsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = ProjectsFolder.url(projectsFolder)
        if panel.runModal() == .OK, let url = panel.url {
            projectsFolder = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

/// Looking for new releases once a day, and checking now.
private struct UpdateSettings: View {
    let updates: UpdateController
    @AppStorage(UpdateController.automaticKey) private var automatic = true

    var body: some View {
        Section("Updates") {
            Toggle("Look for a new version once a day", isOn: $automatic)
                .disabled(!updates.canUpdate)
            LabeledContent("Shepherdr \(updates.version?.description ?? "(local build)")") {
                HStack(spacing: 8) {
                    if updates.state == .checking { ProgressView().controlSize(.small) }
                    Button("Check Now") { Task { await updates.check(asked: true) } }
                        .disabled(!updates.canUpdate || updates.state == .checking)
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
                .help("Before replacing itself, Shepherdr checks the download against the release's checksums, and that the new app is signed by The Agile Monkeys and notarized by Apple. Then it restarts in the new version.")
        }
    }

    private var caption: String {
        guard updates.canUpdate else { return "This build isn't a signed release, so it can't update itself." }
        let checked = updates.lastCheck.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened)). " } ?? ""
        return checked + "Updates come from GitHub and are checked before installing."
    }
}

private struct MachineSettings: View {
    @Bindable var model: AppModel
    @ViewState<Bool> private var addingMachine = false
    @ViewState<MachineState?> private var removing: MachineState? = nil
    @ViewState<HerdrFailure?> private var failure: HerdrFailure? = nil
    @ViewState<String?> private var busyMachine: String? = nil

    private var cluster: ClusterStore { model.cluster }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let failure = cluster.discoveryFailure, failure.state != .notInstalled {
                NoticeView(title: "Saved machines could not be refreshed", message: failure.message, detail: failure.detail)
                    .padding([.horizontal, .top], 16)
            }
            if let failure {
                NoticeView(title: failure.message, message: failure.detail ?? "", detail: nil)
                    .padding([.horizontal, .top], 16)
            }
            List(cluster.machines) { state in
                MachineRow(state: state, lastSuccess: cluster.lastSuccess[state.id], isBusy: busyMachine == state.id) {
                    change(state) { try await cluster.setMachine(state.id, enabled: !state.machine.isEnabled) }
                } remove: {
                    removing = state
                }
            }
            .listStyle(.inset)
            HStack(alignment: .center, spacing: 12) {
                Button {
                    addingMachine = true
                } label: {
                    Label("Add Machine…", systemImage: "plus")
                }
                Text("Disable a machine to stop checking it without removing it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await cluster.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(cluster.isRefreshing)
            }
            .padding(16)
        }
        .sheet(isPresented: $addingMachine) { AddMachineSheet(model: model, isPresented: $addingMachine) }
        .confirmationDialog("Remove \(removing?.machine.name ?? "machine")?",
                            isPresented: Binding { removing != nil } set: { if !$0 { removing = nil } },
                            titleVisibility: .visible, presenting: removing) { state in
            Button("Remove Machine", role: .destructive) {
                change(state) { try await cluster.removeMachine(state.id) }
            }
        } message: { _ in
            Text("Shepherdr forgets this machine. Its sessions keep running there; you can add it again any time.")
        }
    }

    private func change(_ state: MachineState, _ action: @escaping () async throws -> Void) {
        busyMachine = state.id
        failure = nil
        Task {
            failure = await model.perform(action)
            busyMachine = nil
        }
    }
}

private struct MachineRow: View {
    let state: MachineState
    let lastSuccess: Date?
    let isBusy: Bool
    let toggle: () -> Void
    let remove: () -> Void
    @ViewState<Bool> private var expanded = false

    /// The Herdr details kept out of sight.
    private var rowHelp: String {
        var parts = ["Herdr session: \(state.machine.session)"]
        if let snapshot = state.snapshot {
            parts.append("Herdr \(snapshot.version)")
            parts.append("\(snapshot.workspaces.count) workspaces")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: state.machine.isLocal ? "laptopcomputer" : "server.rack").frame(width: 18)
                        .foregroundStyle(.secondary)
                    Text(state.machine.name).fontWeight(.medium)
                    ConnectionDot(state: state.connection)
                    Text(state.connection.title).foregroundStyle(.secondary).font(.callout)
                }
                HStack(spacing: 6) {
                    Text(state.machine.target ?? "This Mac")
                    if let snapshot = state.snapshot {
                        Text("· \(snapshot.agents.count) \(snapshot.agents.count == 1 ? "session" : "sessions")")
                    }
                }
                .font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                .help(rowHelp)
                if !state.machine.isLocal { ProjectsFolderField(machine: state.machine) }
                if let failure = state.failure {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(failure.message)
                        if let detail = failure.detail {
                            Text(detail).foregroundStyle(.secondary).lineLimit(expanded ? nil : 2)
                                .onTapGesture { expanded.toggle() }
                        }
                        if state.isStale, let date = lastSuccess {
                            Text("Last received \(date.formatted(date: .abbreviated, time: .standard))").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption).foregroundStyle(.orange).padding(.leading, 26).textSelection(.enabled)
                }
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if !state.machine.isLocal {
                Button(state.machine.isEnabled ? "Disable" : "Enable", action: toggle)
                    .help(state.machine.isEnabled ? "Stop checking this machine without removing it" : "Start checking this machine again")
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
                    .help("Remove this machine…")
            }
        }
        .padding(.vertical, 4)
    }
}

/// Another machine's projects folder: where New Session clones GitHub repositories there, and where
/// a folder name alone points. `~` is that machine's home.
private struct ProjectsFolderField: View {
    @AppStorage private var folder: String

    init(machine: Machine) {
        _folder = AppStorage(wrappedValue: ProjectsFolder.defaultPath, ProjectsFolder.key(for: machine))
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("Projects folder").font(.caption).foregroundStyle(.secondary)
            TextField(ProjectsFolder.defaultPath, text: $folder)
                .textFieldStyle(.roundedBorder).controlSize(.small).font(.caption)
                .frame(maxWidth: 220)
        }
        .padding(.leading, 26)
        .help("On this machine, New Session clones GitHub repositories here, and a folder name alone means a folder inside it. ~ is its home.")
    }
}

/// The agent tools on each machine: the `shepherdr` command and its skill, which let agents start
/// sessions and hand work back through Shepherdr.
private struct AgentSettings: View {
    @Bindable var model: AppModel
    @ViewState<String> private var macName = ""

    private var courier: Courier { model.courier }
    private var tools: AgentToolsStore { courier.tools }

    var body: some View {
        Form {
            Section {
                Text("Lets agents open sessions on your machines and hand their work back.")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Agents use the shepherdr command and its skill for Claude Code and Codex. Shepherdr installs them over SSH, in ~/.shepherdr and the agents' skill folders. Machines never connect to this Mac: agents leave letters in ~/.shepherdr there, and Shepherdr collects them.")
            }
            Section("Machines") {
                ForEach(model.cluster.machines.filter(\.machine.isEnabled)) { state in
                    AgentMachineRow(state: state, courier: courier, name: name(of: state.machine))
                }
            }
            Section("Updates") {
                Picker("When Shepherdr brings newer tools", selection: Binding { tools.updatePolicy } set: { tools.updatePolicy = $0 }) {
                    Text("Ask in the machine's sessions").tag(AgentToolsStore.UpdatePolicy.ask)
                    Text("Update them").tag(AgentToolsStore.UpdatePolicy.always)
                    Text("Leave them as they are").tag(AgentToolsStore.UpdatePolicy.never)
                }
            }
            Section("This Mac") {
                TextField("Name in the machine lists", text: $macName, prompt: Text(MachineList.defaultMacName))
                    .onSubmit { tools.setMacName(macName) }
                Text("Agents on other machines use this name to ask for a session here. Press Return to save.")
                    .help("Leave it empty to use the computer's name.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { macName = tools.macName == MachineList.defaultMacName ? "" : tools.macName }
    }

    private func name(of machine: Machine) -> String {
        MachineList.name(of: machine, among: model.cluster.machines.map(\.machine), macName: tools.macName)
    }
}

private struct AgentMachineRow: View {
    let state: MachineState
    let courier: Courier
    let name: String

    private var tools: AgentToolsStore { courier.tools }
    private var id: String { state.id }
    private var status: AgentToolsStore.Status { tools.status(on: id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: state.machine.isLocal ? "laptopcomputer" : "server.rack").frame(width: 18).foregroundStyle(.secondary)
                Text(name).fontWeight(.medium)
                Text(statusText).font(.callout).foregroundStyle(.secondary)
                Spacer()
                actions
            }
            if let check = tools.tools(on: id).check, check.version != nil {
                Text(details(check)).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
            if let failure = courier.installFailures[id] {
                Text(failure).font(.caption).foregroundStyle(.orange).padding(.leading, 26).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                if !state.machine.isLocal {
                    Toggle("Trust its letters", isOn: Binding { tools.trusted.contains(id) } set: { tools.setTrusted(id, $0) })
                        .help("Its handoffs to sessions on other machines, its requests for sessions and the pages it suggests go through without asking you")
                    Toggle("Share the machine list", isOn: Binding { tools.shares(id) } set: { tools.setShares(id, $0) })
                        .help("Off: it only learns its own name, not your other machines'")
                }
                if tools.declined.contains(id) {
                    Button("Offer Again") { tools.setDeclined(id, false) }
                        .help("Offer the tools in this machine's sessions again")
                }
            }
            .toggleStyle(.checkbox).font(.caption).padding(.leading, 26)
        }
        .padding(.vertical, 2)
    }

    private var statusText: String {
        guard state.connection == .online || status.isInstalled else { return state.connection.title }
        switch status {
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .missing: return tools.declined.contains(id) ? "Not installed · not offered" : "Not installed"
        case .outdated(let version): return "Version \(version) · update to \(courier.kit?.version ?? version)"
        case .current: return "Installed"
        case .newer(let version): return "Version \(version), from a newer Shepherdr"
        case .installing: return "Installing…"
        case .removing: return "Removing…"
        case .failed(let message): return message
        }
    }

    private func details(_ check: AgentTools.Check) -> String {
        let agents = check.agents.filter(\.isPresent).map { "\($0.name == "claude" ? "Claude Code" : "Codex") \($0.hasSkill ? "✓" : "without the skill")" }
        return ([check.system].compactMap { $0 } + agents + (check.waitingLetters > 0 ? ["\(check.waitingLetters) letters waiting"] : []))
            .joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        let online = state.connection == .online
        switch status {
        case .installing, .removing, .checking:
            ProgressView().controlSize(.small)
        case .missing, .failed:
            Button("Install") { courier.install(id) }.disabled(!online)
        case .outdated:
            Button("Update") { courier.install(id) }.disabled(!online)
            Button("Remove") { courier.uninstall(id) }.disabled(!online)
        case .current, .newer:
            Button("Remove") { courier.uninstall(id) }.disabled(!online)
                .help("Removes the command and its skills; letters stay in ~/.shepherdr")
        case .unknown:
            Button("Check") { courier.check(id) }.disabled(!online)
        }
    }
}

private struct AddMachineSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool
    @ViewState<String> private var target = ""
    @ViewState<String> private var label = ""
    @ViewState<String> private var session = ""
    @ViewState<Bool> private var working = false
    @ViewState<HerdrFailure?> private var failure: HerdrFailure? = nil

    private var command: String {
        var parts = ["herdr machine add", target.isEmpty ? "user@host" : target]
        if !label.isEmpty { parts.append("--label \(Self.quote(label))") }
        if !session.isEmpty { parts.append("--remote-session \(Self.quote(session))") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Machine").font(.title3).fontWeight(.semibold)
            Form {
                TextField("SSH target", text: $target, prompt: Text("user@host or an ~/.ssh/config alias"))
                TextField("Label", text: $label, prompt: Text("optional"))
                TextField("Remote session", text: $session, prompt: Text("default"))
            }
            .formStyle(.grouped)
            Text("Connects over SSH, which must work without a password prompt (load your key into ssh-agent first). This may install Herdr there. If it needs your input, run this in Terminal instead:")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
            if let failure {
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.message).foregroundStyle(.orange)
                    if let detail = failure.detail { Text(detail).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled) }
                }
                .font(.caption)
            }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Preparing \(target)… this can take a minute.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Add Machine") { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 500)
        .preferredColorScheme(.dark)
    }

    private func add() {
        working = true
        failure = nil
        let request = NewMachineRequest(sshTarget: target, label: label, remoteSession: session)
        Task {
            failure = await model.perform { try await model.cluster.addMachine(request) }
            working = false
            if failure == nil { isPresented = false }
        }
    }

    /// Shell quoting for the copyable command shown to the user.
    private static func quote(_ value: String) -> String {
        value.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) } ? value
            : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
