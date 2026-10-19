import AppKit
import SwiftUI
import ShepherdrCore

/// Where the user keeps projects on each machine: New Session clones repositories there, a bare
/// folder name means a folder inside it, and on this Mac its folder picker starts there. `~` is
/// each machine's own home.
enum ProjectsFolder {
    static let key = "projectsFolder"
    static let defaultPath = "~/projects"

    /// This Mac keeps the setting it always had; other machines each have their own.
    static func key(for machine: Machine) -> String { machine.isLocal ? key : "\(key):\(machine.id)" }

    static func path(for machine: Machine) -> String {
        UserDefaults.standard.string(forKey: key(for: machine))?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? defaultPath
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}

/// Creates a Herdr workspace with a shell in it: in a folder, in a new worktree of a folder's
/// repository, or from a GitHub link, cloning the repository first when the machine doesn't have
/// it and checking a pull request's branch out in a worktree. Starting an agent there is up to
/// the user; Shepherdr picks it up as soon as Herdr detects it.
struct NewSessionSheet: View {
    @Bindable var model: AppModel
    let draft: NewSessionDraft
    @AppStorage("newSessionMachine") private var lastMachineID = Machine.local.id
    @AppStorage(ProjectsFolder.key) private var localProjectsFolder = ProjectsFolder.defaultPath
    @ViewState<String?> private var machineID: String?
    @ViewState<String> private var directory: String
    @ViewState<String> private var name = ""
    @ViewState<Bool> private var inWorktree = false
    @ViewState<String> private var branch = ""
    @ViewState<HerdrFailure?> private var failure: HerdrFailure? = nil
    /// A folder that doesn't exist yet, waiting for the user to make it a new project.
    @ViewState<String?> private var newProject: String? = nil
    /// What the sheet is doing before Herdr creates the workspace, such as checking the folder.
    @ViewState<String?> private var progress: String? = nil
    /// What GitHub said about the pull request in the folder field.
    @ViewState<PullLookup?> private var pull: PullLookup? = nil
    @FocusState private var focus: Field?
    /// An agent to start and its first prompt, when something asked for them, such as a Compass page.
    @ViewState<String?> private var agentKind: String?
    @ViewState<String> private var prompt: String
    @ViewState<Bool> private var compassWaits: Bool
    @ViewState<QueueDrop?> private var placement: QueueDrop?
    @ViewState<CGFloat> private var promptHeight: CGFloat = 90

    private enum Field { case directory, branch, name }

    private struct PullLookup: Equatable {
        let key: String
        var head: PullRequestHead?
        var isDone = false
    }

    init(model: AppModel, draft: NewSessionDraft) {
        self.model = model
        self.draft = draft
        _machineID = ViewState(initialValue: draft.machineID)
        _directory = ViewState(initialValue: draft.directory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "")
        _name = ViewState(initialValue: draft.name ?? "")
        _agentKind = ViewState(initialValue: draft.agentKind)
        _prompt = ViewState(initialValue: draft.prompt ?? "")
        _compassWaits = ViewState(initialValue: draft.compass?.compassWaits ?? false)
        _placement = ViewState(initialValue: draft.placement)
    }

    /// Asked for with an agent or a prompt: the sheet starts the agent too.
    private var startsAgent: Bool { draft.compass != nil || draft.agentKind != nil || draft.prompt != nil }

    private var machine: MachineState? {
        let id = machineID ?? lastMachineID
        return model.onlineMachines.first { $0.id == id } ?? model.onlineMachines.first
    }
    private var isLocal: Bool { machine?.machine.isLocal ?? true }
    private var projectsFolder: String {
        guard let machine, !machine.machine.isLocal else { return localProjectsFolder }
        return ProjectsFolder.path(for: machine.machine)
    }
    /// A GitHub repository or pull request in the folder field.
    private var reference: GitHubReference? { GitHubReference(directory) }
    private var pullKey: String {
        guard case .pullRequest(let repository, let number)? = reference else { return "" }
        return "\(repository.fullName)#\(number)"
    }
    /// The folder the session opens in, or for a GitHub link the folder its clone goes into.
    private var resolvedDirectory: String {
        if let reference { return inProjects(reference.repository.name) }
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocal else { return trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.hasPrefix("~") ? trimmed : inProjects(trimmed) }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard !expanded.isEmpty, !expanded.hasPrefix("/") else { return expanded }
        return inProjects(expanded)
    }
    private var trimmedBranch: String { branch.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// The branch the session's worktree checks out, if it gets one.
    private var worktreeBranch: String? {
        if case .pullRequest(_, let number)? = reference { return PullRequestHead.localBranch(for: number, head: pull?.head) }
        return inWorktree ? trimmedBranch : nil
    }
    private var resolvedName: String {
        let base = suggestedName
        // Herdr names agents with lowercase letters, digits, - and _.
        return startsAgent && agentKind != nil && !base.isEmpty ? Self.agentName(from: base, kind: agentKind ?? "agent") : base
    }

    /// The name typed, or one made from the link, the branch or the folder.
    private var suggestedName: String {
        if let typed = name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty { return typed }
        switch reference {
        case .pullRequest(let repository, let number)?: return "\(repository.name)#\(number)"
        case .repository(let repository)? where !inWorktree: return repository.name
        default: break
        }
        if inWorktree, let branch = trimmedBranch.nonEmpty { return branch }
        return reference == nil ? URL(fileURLWithPath: resolvedDirectory).lastPathComponent : ""
    }

    /// `My App` becomes `my-app`: a name Herdr takes for an agent.
    static func agentName(from text: String, kind: String) -> String {
        guard !CompassAction.isAgentName(text) else { return text }
        let cleaned = text.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "-" }
        let name = String(String(cleaned.drop { !($0.isASCII && $0.isLetter) }).prefix(32))
        return name.isEmpty ? kind : name
    }
    private var canCreate: Bool {
        guard machine != nil, !resolvedDirectory.isEmpty, !resolvedName.isEmpty, !model.isCreatingSession, progress == nil else {
            return false
        }
        if case .pullRequest? = reference { return pull?.isDone == true }
        return !inWorktree || !trimmedBranch.isEmpty
    }
    private var isPullRequest: Bool { if case .pullRequest? = reference { true } else { false } }
    private var whereabouts: String { isLocal ? "on this Mac" : "on \(machine?.machine.name ?? "that machine")" }
    private var subtitle: String {
        if draft.compass != nil { return "asked for by your Compass page" }
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

            field(isLocal ? "Folder or GitHub link" : "Folder on \(machine?.machine.name ?? "machine") or GitHub link") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        consoleTextField("\(projectsFolder)/my-app, or a repository or pull request URL", text: $directory)
                            .focused($focus, equals: .directory)
                        if isLocal {
                            Button("CHOOSE…") { chooseFolder() }.buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                        }
                    }
                    if reference == nil { folderShortcuts } else { referenceNote }
                }
            }

            worktreeField

            field("Name") {
                consoleTextField(resolvedName.isEmpty ? "defaults to the folder name" : resolvedName, text: $name)
                    .focused($focus, equals: .name)
            }

            if startsAgent {
                agentFields
            } else {
                Text("Start an agent in its terminal when you need one; the session joins the queue as soon as Herdr detects it.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }

            if let newProject {
                VStack(alignment: .leading, spacing: 3) {
                    Text("? \(display(newProject)) doesn't exist \(whereabouts).")
                        .font(Theme.mono(11)).foregroundStyle(Theme.amber)
                    Text("Start a new project there? Shepherdr makes the folder, runs git init in it and opens the session.")
                        .font(Theme.mono(10)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
            }

            if let failure {
                VStack(alignment: .leading, spacing: 3) {
                    Text("✗ \(failure.message)").font(Theme.mono(11)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
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
        .frame(width: 500)
        .background(Theme.panel)
        // A prefilled folder usually only needs a name.
        .onAppear { focus = directory.isEmpty ? .directory : .name }
        // The question and any failure were about the folder as it was.
        .onChange(of: resolvedDirectory) { newProject = nil; failure = nil }
        .onChange(of: worktreeBranch) { failure = nil }
        .task(id: pullKey) { await lookUpPullRequest() }
    }

    /// The agent, its first prompt, where the session goes and whether it reports back: for a
    /// session something asked for, so you see all of it before it starts.
    @ViewBuilder private var agentFields: some View {
        field("Agent") {
            Picker("", selection: $agentKind) {
                Text("None — a shell").tag(String?.none)
                ForEach(NewSessionRequest.agentKinds, id: \.self) { kind in Text(AgentProgram(label: kind).name).tag(String?.some(kind)) }
            }
            .labelsHidden()
        }
        if agentKind != nil {
            field("First prompt") {
                PromptEditor(text: $prompt, height: $promptHeight, isEnabled: true,
                             font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                             focusRequest: 0, history: [], onSubmit: { newProject == nil ? create() : createProject() })
                    .frame(height: min(max(promptHeight, 90), 220))
                    .padding(6)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
            }
            Text("Sent once the agent is ready. Read it before you start: it came from a page built with what others wrote.")
                .font(Theme.mono(10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
        }
        if draft.compass != nil {
            field("Place") {
                Picker("", selection: $placement) {
                    Text("At the end of the queue").tag(QueueDrop?.none)
                    if let first = model.queue.first?.id { Text("At the top of the queue").tag(QueueDrop?.some(.before(first))) }
                    ForEach(model.groups) { group in Text("In \(group.name)").tag(QueueDrop?.some(.into(group: group.id))) }
                }
                .labelsHidden()
            }
            if agentKind != nil {
                Toggle("Compass waits for it", isOn: $compassWaits)
                    .font(Theme.mono(11)).toggleStyle(.checkbox)
                    .help("Compass's session goes on hold for it and lists it under itself. When you ask it for a handoff, the result goes to Compass's agent, which updates the page.")
            }
        }
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

    /// What a GitHub link in the folder field leads to.
    @ViewBuilder private var referenceNote: some View {
        let destination = display(resolvedDirectory)
        VStack(alignment: .leading, spacing: 3) {
            switch reference {
            case .repository(let repository)?:
                Text("⇣ \(repository.fullName)").foregroundStyle(Theme.cyan)
                Text("Opens your clone \(whereabouts), or clones it into \(destination) first.").foregroundStyle(Theme.dim)
            case .pullRequest(let repository, let number)?:
                let title = pull?.head.map { " · \($0.title)" } ?? ""
                Text("⇄ \(repository.fullName)#\(number)\(title)").foregroundStyle(Theme.lilac).lineLimit(2)
                Text(pullDetail(number: number, destination: destination)).foregroundStyle(Theme.dim)
            case nil:
                EmptyView()
            }
        }
        .font(Theme.mono(10.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pullDetail(number: Int, destination: String) -> String {
        guard let pull, pull.isDone else { return "Asking GitHub for its branch…" }
        let branch = PullRequestHead.localBranch(for: number, head: pull.head)
        let clone = "your clone \(whereabouts), cloned into \(destination) first if needed"
        guard let head = pull.head else {
            return "GitHub didn't say which branch it comes from: its commits go to branch \(branch), in a worktree of \(clone)."
        }
        let state = head.state == "open" ? "" : " It's \(head.state)."
        guard head.isSameRepository else {
            return "From a fork's \(head.branch): its commits go to branch \(branch), in a worktree of \(clone).\(state)"
        }
        return "Branch \(branch), in a worktree of \(clone).\(state)"
    }

    /// The worktree option: off by default for a folder or a repository, always on for a pull request.
    @ViewBuilder private var worktreeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { inWorktree.toggle(); if inWorktree { focus = .branch } } label: {
                HStack(spacing: 6) {
                    Text(inWorktree || isPullRequest ? "[x]" : "[ ]").foregroundStyle(Theme.phosphor)
                    Text("IN A NEW WORKTREE").tracking(1.2).foregroundStyle(Theme.dim)
                }
                .font(Theme.mono(10.5, .semibold))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isPullRequest)
            .help(isPullRequest ? "A pull request always opens in a worktree of its branch"
                                : "Work on a branch in a separate checkout, beside the folder's own")
            if inWorktree && !isPullRequest {
                field("Branch") {
                    consoleTextField("fix-login", text: $branch).focused($focus, equals: .branch)
                }
                Text("Herdr checks the branch out in a worktree of its own, in its worktrees folder, or opens the one it already has. A new branch starts at the folder's current commit.")
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
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

    /// A path inside the machine's projects folder: absolute on this Mac, under `~` elsewhere when the
    /// setting is.
    private func inProjects(_ path: String) -> String {
        isLocal ? ProjectsFolder.url(projectsFolder).appendingPathComponent(path).path
                : (projectsFolder as NSString).appendingPathComponent(path)
    }

    /// Paths on this Mac under its home are shown with `~`.
    private func display(_ path: String) -> String {
        isLocal ? (path as NSString).abbreviatingWithTildeInPath : path
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

    /// Asks GitHub which branch the pull request in the folder field comes from, once per pull request.
    private func lookUpPullRequest() async {
        guard case .pullRequest(let repository, let number)? = reference else { return }
        let key = pullKey
        guard pull?.key != key else { return }
        pull = PullLookup(key: key)
        // Typing the number digit by digit shouldn't ask GitHub about every prefix.
        do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
        let head = await GitHubLookup().pullRequest(repository, number: number)
        guard !Task.isCancelled, pullKey == key else { return }
        pull = PullLookup(key: key, head: head, isDone: true)
    }

    private func create() {
        guard canCreate, let machine else { return }
        failure = nil
        lastMachineID = machine.id
        switch reference {
        case .repository(let repository)?: openClone(of: repository, pullRequest: nil, on: machine)
        case .pullRequest(let repository, let number)?: openClone(of: repository, pullRequest: number, on: machine)
        case nil: openFolder(on: machine)
        }
    }

    /// Checks the folder on its machine first: Herdr would open a missing one's workspace in the home folder.
    private func openFolder(on machine: MachineState) {
        let typed = resolvedDirectory
        let worktree = worktreeBranch.map { NewSessionRequest.Worktree(branch: $0) }
        Task {
            progress = "checking folder…"
            let state = await ProjectFolder.check(typed, on: machine.machine)
            progress = nil
            guard typed == resolvedDirectory else { return }
            switch state {
            case .folder(let path): open(path, worktree: worktree, on: machine)
            // A new project has no commit for a worktree to start from.
            case .missing(let path) where worktree != nil:
                failure = HerdrFailure(.unreachable, "\(display(path)) doesn't exist \(whereabouts).")
            case .missing(let path): newProject = path
            case .notAFolder: failure = HerdrFailure(.unreachable, "That is a file, not a folder.")
            // Another machine may answer Herdr although it doesn't answer SSH.
            case nil where !isLocal: open(typed, worktree: worktree, on: machine)
            case nil: failure = HerdrFailure(.unreachable, "Could not check that folder.")
            }
        }
    }

    /// Finds the repository's clone on the machine, or clones it into the projects folder, then opens
    /// the session there; for a pull request, in a worktree of its branch.
    private func openClone(of repository: GitHubRepository, pullRequest number: Int?, on machine: MachineState) {
        let typed = directory
        let destination = resolvedDirectory
        let head = pull?.head
        let candidates = model.clones(named: repository.name, on: machine.id)
        Task {
            defer { progress = nil }
            progress = "looking for \(repository.fullName)…"
            guard let location = await ProjectClone.locate(repository, in: destination, orAmong: candidates, on: machine.machine) else {
                failure = HerdrFailure(.unreachable, "Could not look for \(repository.fullName) \(whereabouts).",
                                       detail: isLocal ? nil : "Shepherdr reaches \(machine.machine.name) over SSH, as for its terminals.")
                return
            }
            guard typed == directory else { return }
            let path: String, remote: String
            switch location {
            case .cloned(let found, let name):
                (path, remote) = (found, name)
            case .free(let free):
                progress = "cloning \(repository.fullName)…"
                do { try await ProjectClone.clone(repository, into: free, on: machine.machine) }
                catch { failure = AppModel.failure(error); return }
                (path, remote) = (free, "origin")
            case .taken(let taken):
                failure = HerdrFailure(.unreachable, "\(display(taken)) holds something else.",
                                       detail: "Shepherdr clones \(repository.fullName) there. Move that folder, or choose another projects folder in Settings.")
                return
            }
            var worktree = worktreeBranch.map { NewSessionRequest.Worktree(branch: $0) }
            var pins: [URL] = []
            if let number {
                progress = "fetching pull request #\(number)…"
                do {
                    let base = try await ProjectClone.fetch(pullRequest: number, branch: head?.isSameRepository == true ? head?.branch : nil,
                                                            from: remote, in: path, on: machine.machine)
                    worktree = NewSessionRequest.Worktree(branch: PullRequestHead.localBranch(for: number, head: head), base: base)
                } catch {
                    failure = AppModel.failure(error)
                    return
                }
                pins = [repository.pullRequestURL(number)]
            }
            open(path, worktree: worktree, pins: pins, on: machine)
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
            open(path, worktree: nil, on: machine)
        }
    }

    private func open(_ path: String, worktree: NewSessionRequest.Worktree?, pins: [URL] = [], on machine: MachineState) {
        let kind = startsAgent ? agentKind : nil
        let request = NewSessionRequest(directory: path, name: resolvedName, agentKind: kind, worktree: worktree)
        let first = kind == nil ? nil : prompt.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var from = draft.compass
        from?.compassWaits = compassWaits && kind != nil
        Task {
            failure = await model.createSession(request, onMachine: machine.id, placement: startsAgent ? placement : draft.placement,
                                                pins: pins, prompt: first, compass: from)
        }
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
