import AppKit
import SwiftUI
import ShepherdrCore

/// Where the user keeps projects on this Mac: New Session's folder picker always starts here,
/// and a bare folder name means a folder inside it.
enum ProjectsFolder {
    static let key = "projectsFolder"
    static let defaultPath = "~/projects"

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// Creates a Herdr workspace in a folder with a shell in it. Starting an agent there is up to
/// the user; Shepherdr picks it up as soon as Herdr detects it.
struct NewSessionSheet: View {
    @Bindable var model: AppModel
    let draft: NewSessionDraft
    @AppStorage("newSessionMachine") private var lastMachineID = Machine.local.id
    @AppStorage(ProjectsFolder.key) private var projectsFolder = ProjectsFolder.defaultPath
    @ViewState<String?> private var machineID: String?
    @ViewState<String> private var directory: String
    @ViewState<String> private var name = ""
    @ViewState<HerdrFailure?> private var failure: HerdrFailure? = nil
    /// A folder that doesn't exist yet, waiting for the user to make it a new project.
    @ViewState<String?> private var newProject: String? = nil
    /// What the sheet is doing before Herdr creates the workspace, such as checking the folder.
    @ViewState<String?> private var progress: String? = nil
    @FocusState private var focus: Field?

    private enum Field { case directory, name }

    init(model: AppModel, draft: NewSessionDraft) {
        self.model = model
        self.draft = draft
        _machineID = ViewState(initialValue: draft.machineID)
        _directory = ViewState(initialValue: draft.directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
    }

    private var machine: MachineState? {
        let id = machineID ?? lastMachineID
        return model.onlineMachines.first { $0.id == id } ?? model.onlineMachines.first
    }
    private var isLocal: Bool { machine?.machine.isLocal ?? true }
    private var resolvedDirectory: String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocal else { return trimmed }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.hasPrefix("/") else { return expanded }
        return ProjectsFolder.url(projectsFolder).appendingPathComponent(expanded).path
    }
    private var resolvedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? URL(fileURLWithPath: resolvedDirectory).lastPathComponent
    }
    private var canCreate: Bool {
        machine != nil && !resolvedDirectory.isEmpty && !resolvedName.isEmpty && !model.isCreatingSession && progress == nil
    }
    private var whereabouts: String { isLocal ? "on this Mac" : "on \(machine?.machine.name ?? "that machine")" }
    private var subtitle: String {
        guard case .into(let groupID) = draft.placement,
              let group = model.groups.first(where: { $0.id == groupID }) else { return "a new herdr workspace with a shell in it" }
        return "a new herdr workspace with a shell, in \(group.name)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PixelFlock(pixel: 1.5)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NEW SESSION").font(Theme.mono(15, .bold)).tracking(2).foregroundStyle(Theme.text)
                    Text(subtitle).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
            }

            if model.onlineMachines.count > 1 {
                field("Machine") {
                    Picker("", selection: Binding { machine?.id ?? Machine.local.id } set: { machineID = $0 }) {
                        ForEach(model.onlineMachines) { state in
                            Text(state.machine.isLocal ? "Local" : "\(state.machine.name) · \(state.machine.target ?? "")").tag(state.id)
                        }
                    }
                    .labelsHidden()
                }
            }

            field(isLocal ? "Folder" : "Folder on \(machine?.machine.name ?? "machine")") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        consoleTextField(isLocal ? "\(projectsFolder)/my-app" : "/home/me/projects/my-app", text: $directory)
                            .focused($focus, equals: .directory)
                        if isLocal {
                            Button("CHOOSE…") { chooseFolder() }.buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                        }
                    }
                    folderShortcuts
                }
            }

            field("Name") {
                consoleTextField(resolvedDirectory.isEmpty ? "defaults to the folder name" : resolvedName, text: $name)
                    .focused($focus, equals: .name)
            }

            Text("Start an agent in its terminal when you need one; the session joins the queue as soon as Herdr detects it.")
                .font(Theme.mono(10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)

            if let newProject {
                VStack(alignment: .leading, spacing: 3) {
                    Text("? \(isLocal ? (newProject as NSString).abbreviatingWithTildeInPath : newProject) doesn't exist \(whereabouts).")
                        .font(Theme.mono(11)).foregroundStyle(Theme.amber)
                    Text("Start a new project there? Shepherdr makes the folder, runs git init in it and opens the session.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let failure {
                VStack(alignment: .leading, spacing: 3) {
                    Text("✗ \(failure.message)").font(Theme.mono(11)).foregroundStyle(Theme.red)
                    if let detail = failure.detail {
                        Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(4).textSelection(.enabled)
                    }
                }
            }

            HStack {
                if model.isCreatingSession || progress != nil {
                    Text(progress ?? "creating workspace…").font(Theme.mono(10.5)).foregroundStyle(Theme.phosphor)
                    BlinkingCursor()
                }
                Spacer()
                Button("CANCEL") { model.newSession = nil }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreatingSession || progress != nil)
                Button(newProject == nil ? "CREATE ⏎" : "NEW PROJECT ⏎") { newProject == nil ? create() : createProject() }
                    .buttonStyle(ConsoleButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.panel)
        // A prefilled folder usually only needs a name.
        .onAppear { focus = directory.isEmpty ? .directory : .name }
        // The question and any failure were about the folder as it was.
        .onChange(of: resolvedDirectory) { newProject = nil; failure = nil }
    }

    /// The folders agents on this machine work in, the most used first, one click away.
    @ViewBuilder private var folderShortcuts: some View {
        let folders = machine.map { model.folders(on: $0.id) } ?? []
        if !folders.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(folders, id: \.path) { folder in
                    folderButton(folder, label: Self.label(for: folder.path, among: folders.map(\.path)))
                }
            }
        }
    }

    private func folderButton(_ folder: FolderUse, label: String) -> some View {
        let isChosen = resolvedDirectory == folder.path
        return Button {
            directory = isLocal ? (folder.path as NSString).abbreviatingWithTildeInPath : folder.path
        } label: {
            HStack(spacing: 4) {
                Text(label).lineLimit(1)
                if folder.agents > 1 { Text("×\(folder.agents)").foregroundStyle(Theme.faint) }
            }
        }
        .buttonStyle(ConsoleButtonStyle(tint: isChosen ? Theme.phosphor : Theme.dim))
        .help(([folder.path] + Self.uses(of: folder)).joined(separator: "\n"))
    }

    /// `2 agents work here`, `1 shell without an agent is open here`.
    static func uses(of folder: FolderUse) -> [String] {
        var uses: [String] = []
        if folder.agents > 0 { uses.append(folder.agents == 1 ? "1 agent works here" : "\(folder.agents) agents work here") }
        if folder.shells > 0 {
            uses.append(folder.shells == 1 ? "1 shell without an agent is open here" : "\(folder.shells) shells without an agent are open here")
        }
        return uses
    }

    /// A folder's name, with its parent's when another folder has the same name.
    static func label(for path: String, among paths: [String]) -> String {
        let name = (path as NSString).lastPathComponent
        guard paths.contains(where: { $0 != path && ($0 as NSString).lastPathComponent == name }) else { return name }
        return ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent + "/" + name
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.faint)
            content()
        }
    }

    private func consoleTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.directoryURL = ProjectsFolder.url(projectsFolder)
        if panel.runModal() == .OK, let url = panel.url {
            directory = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Checks the folder on its machine first: Herdr would open a missing one's workspace in the home folder.
    private func create() {
        guard canCreate, let machine else { return }
        failure = nil
        lastMachineID = machine.id
        let typed = resolvedDirectory
        Task {
            progress = "checking folder…"
            let state = await ProjectFolder.check(typed, on: machine.machine)
            progress = nil
            guard typed == resolvedDirectory else { return }
            switch state {
            case .folder(let path): open(path, on: machine)
            case .missing(let path): newProject = path
            case .notAFolder: failure = HerdrFailure(.unreachable, "That is a file, not a folder.")
            // Another machine may answer Herdr although it doesn't answer SSH.
            case nil where !isLocal: open(typed, on: machine)
            case nil: failure = HerdrFailure(.unreachable, "Could not check that folder.")
            }
        }
    }

    /// Makes the missing folder a new project, a folder with an empty Git repository, and opens it.
    private func createProject() {
        guard let path = newProject, canCreate, let machine else { return }
        failure = nil
        Task {
            progress = "creating project…"
            defer { progress = nil }
            do {
                try await ProjectFolder.create(path, on: machine.machine)
            } catch {
                failure = AppModel.failure(error)
                return
            }
            newProject = nil
            open(path, on: machine)
        }
    }

    private func open(_ path: String, on machine: MachineState) {
        let request = NewSessionRequest(directory: path, name: resolvedName, agentKind: nil)
        Task { failure = await model.createSession(request, onMachine: machine.id, placement: draft.placement) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// Lays its views out in rows, starting a new row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = place(subviews, within: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, within: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, within width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            frames.append(CGRect(origin: origin, size: size))
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
