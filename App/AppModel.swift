import AppKit
import Foundation
import Observation
import ShepherdrCore
import ShepherdrDictation

enum Destination: Hashable {
    case overview
    /// An agent session or a plain shell pane; both are addressed by machine and terminal ID.
    case session(Agent.ID)
}

/// A pane without a detected agent. It can be opened, but it is not part of the priority queue.
struct ShellRow: Identifiable, Equatable {
    let pane: TerminalPane
    let machine: Machine
    let isStale: Bool
    var id: Agent.ID { .init(machineID: machine.id, terminalID: pane.terminalID) }

    func matches(_ query: String) -> Bool {
        query.isEmpty || [pane.workspaceName, pane.title, machine.name].contains { $0.localizedStandardContains(query) }
    }
}

/// One entry of an expanded group: a session, or a shell placed in the group.
enum GroupMember: Identifiable {
    case session(AgentRow)
    case shell(ShellRow)

    /// Distinct per kind: a shell and the agent Herdr later detects in it share an `Agent.ID`.
    enum ID: Hashable { case session(Agent.ID), shell(Agent.ID) }

    var id: ID {
        switch self {
        case .session(let row): .session(row.id)
        case .shell(let shell): .shell(shell.id)
        }
    }

    var agentID: Agent.ID {
        switch self {
        case .session(let row): row.id
        case .shell(let shell): shell.id
        }
    }
}

/// A session as the sidebar lists it: in its own place, or nested under a session waiting for it.
struct TreeRow: Identifiable {
    let row: AgentRow
    /// 0 in its own place; an awaited session sits one level below the session waiting for it.
    let depth: Int
    /// The session at the top of this row's tree. Drops on nested rows land relative to it.
    let root: Agent.ID
    /// Sessions nested directly under this one, shown or not.
    let nestedCount: Int
    let isCollapsed: Bool
    /// Hidden nested sessions, at any depth, that need attention.
    let hiddenBlocked: Int
    /// Whether the selected session is among the hidden ones.
    let hidesSelection: Bool
    /// Tree lines: for each level between the top and this row, whether a line passes by.
    let guides: [Bool]
    /// The last session nested under its parent ends the parent's line.
    let isLastSibling: Bool
    /// The sessions whose listed tree ends with this row: a drop after them is drawn below it.
    var closes: [Agent.ID] = []
    var id: Agent.ID { row.id }
}

/// How the sidebar nests sessions on hold: each awaited session under the session waiting for it.
struct WaitForest {
    let parents: [Agent.ID: Agent.ID]
    let children: [Agent.ID: [AgentRow]]
    /// Sessions whose nested sessions are hidden; none while filtering.
    let collapsed: Set<Agent.ID>
    let selected: Agent.ID?

    func isNested(_ id: Agent.ID) -> Bool { parents[id] != nil }

    /// A session in its own place and, unless collapsed, the sessions nested under it, depth first.
    func rows(from row: AgentRow) -> [TreeRow] { rows(from: row, root: row.id, depth: 0, guides: [], isLast: true) }

    private func rows(from row: AgentRow, root: Agent.ID, depth: Int, guides: [Bool], isLast: Bool) -> [TreeRow] {
        let nested = children[row.id] ?? []
        let isCollapsed = !nested.isEmpty && collapsed.contains(row.id)
        let hidden = isCollapsed ? descendants(of: row.id) : []
        var result = [TreeRow(row: row, depth: depth, root: root, nestedCount: nested.count, isCollapsed: isCollapsed,
                              hiddenBlocked: hidden.filter { $0.agent.state == .blocked && !$0.isStale }.count,
                              hidesSelection: hidden.contains { $0.id == selected },
                              guides: guides, isLastSibling: isLast)]
        if !isCollapsed {
            // A nested row's own line continues past its children unless it was the last one.
            let childGuides = depth == 0 ? [] : guides + [!isLast]
            for (index, child) in nested.enumerated() {
                result += rows(from: child, root: root, depth: depth + 1, guides: childGuides, isLast: index == nested.count - 1)
            }
        }
        result[result.count - 1].closes.append(row.id)
        return result
    }

    private func descendants(of id: Agent.ID) -> [AgentRow] {
        (children[id] ?? []).flatMap { [$0] + descendants(of: $0.id) }
    }
}

/// Everything the work area needs to present one session.
struct SessionContext {
    let target: TerminalTarget
    let machine: MachineState
    let agent: AgentRow?
    let paneID: String
    var title: String { agent?.title ?? "shell" }
    var isStale: Bool { machine.isStale }
    var canConnect: Bool { machine.connection == .online }
}

/// What a session keeps while you work elsewhere, and across restarts: its prompt editor, its
/// browser tabs and the links collected from it.
@MainActor @Observable
final class SessionWorkspace {
    /// The prompt editor is optional; the terminal is where you normally type.
    var isEditorOpen = false { didSet { if isEditorOpen != oldValue { save() } } }
    let browser = SessionBrowser()
    /// Pull requests, issues and Claude artifacts the session linked to, newest first.
    private(set) var resources: [SessionResource] = []
    @ObservationIgnored private var persist: ((SessionStateStore.State) -> Void)?

    init(restoring state: SessionStateStore.State = .init(), persist: ((SessionStateStore.State) -> Void)? = nil) {
        isEditorOpen = state.showsEditor
        // Older versions could keep a GitHub number twice, as a pull request and as an issue.
        resources = SessionResources.merge([], into: state.resources)
        browser.restore(state.tabs, selected: state.selectedTab, visible: state.showsBrowser)
        self.persist = persist
        browser.onChange = { [weak self] in self?.save() }
    }

    func collect(_ found: [SessionResource]) {
        let merged = SessionResources.merge(found, into: resources)
        guard merged != resources else { return }
        resources = merged
        save()
    }

    func remove(_ resource: SessionResource) {
        resources.removeAll { $0.key == resource.key }
        save()
    }

    /// Opens a resource in the session's browser and counts the visit.
    func open(_ resource: SessionResource) {
        browser.open(resource.url)
        countOpen(of: resource.url)
    }

    /// Counts a visit to a link if it is one of the session's resources.
    func countOpen(of url: URL) {
        guard let key = SessionResource(url: url)?.key, let index = resources.firstIndex(where: { $0.key == key }) else { return }
        resources[index].opens += 1
        save()
    }

    /// Resources whose pages may exist: the ones the panel lists.
    var visibleResources: [SessionResource] { resources.filter { !$0.isMissing } }

    /// Records what a check found out about a resource.
    func update(_ key: String, _ change: (SessionResource) -> SessionResource) {
        guard let index = resources.firstIndex(where: { $0.key == key }) else { return }
        let updated = change(resources[index])
        guard updated != resources[index] else { return }
        resources[index] = updated
        save()
    }

    private func save() {
        var state = SessionStateStore.State()
        // Blank tabs have nothing to bring back.
        let kept = browser.tabs.filter { $0.url.map { $0.scheme != "about" } ?? false }
        state.tabs = kept.compactMap(\.url)
        state.selectedTab = kept.firstIndex { $0.id == browser.selected?.id }
        state.showsBrowser = browser.isVisible
        state.showsEditor = isEditorOpen
        state.resources = resources
        persist?(state)
    }
}

/// What the New Session sheet starts from: a folder and machine to prefill, and where the
/// session takes its place in the queue once Herdr reports its agent.
struct NewSessionDraft: Identifiable {
    let id = UUID()
    var directory: String?
    var machineID: String?
    var placement: QueueDrop?
}

/// Whether a session on hold can resume: `ready` once none of the sessions it waits for is
/// still working or needs attention.
enum WaitState { case waiting, ready }

/// Window-level navigation and composer state. Drafts and prompt history stay in memory only.
@MainActor @Observable
final class AppModel {
    let cluster: ClusterStore
    let order: SessionOrderStore
    let relations: SessionRelationStore
    let sessionStates: SessionStateStore
    var selection: Destination = .overview {
        didSet {
            sessionStates.lastSelection = selectedID
            checksMonitor.watch(selectedID)
        }
    }
    /// Until the session open at the last quit is back, or known to be gone.
    @ObservationIgnored private var isRestoringSelection = true
    /// Shepherdr's one window, while it is open.
    @ObservationIgnored private weak var mainWindow: NSWindow?
    /// Opens the main window again after it was closed.
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// The session being renamed, presented as a name prompt.
    var renaming: RenamePrompt?
    var search = ""
    var drafts: [Agent.ID: String] = [:]
    private(set) var history: [Agent.ID: [String]] = [:]
    /// Incremented to ask the visible prompt editor to take keyboard focus.
    var promptFocusRequest = 0
    /// Incremented to ask the visible terminal to take keyboard focus.
    var terminalFocusRequest = 0
    /// Records and transcribes prompts on this Mac.
    let dictation = Dictation()
    /// The session a recording is for: its transcript lands in that session's prompt editor.
    private(set) var dictationTarget: Agent.ID?
    /// Asks before the one-time speech model download.
    var asksToDownloadSpeechModel = false
    @ObservationIgnored private var speechModelDownloadAccepted = false
    /// Created on first use and kept for the life of the app, so pages survive switching sessions.
    @ObservationIgnored private var workspaces: [Agent.ID: SessionWorkspace] = [:]
    /// The terminal shown in the work area, for menu commands.
    var activeTerminal: TerminalStore?

    /// The New Session sheet, while it is open.
    var newSession: NewSessionDraft?
    private(set) var isCreatingSession = false
    /// The session awaiting close confirmation.
    var closingSession: Agent.ID?
    /// A failed change, presented as an alert.
    var actionFailure: HerdrFailure?
    /// Messages shown on a session after it was created, such as an agent waiting at a startup prompt.
    var sessionNotices: [Agent.ID: String] = [:]
    /// macOS notifications for agents that finish or need you.
    @ObservationIgnored let notifier = SessionNotifier()
    /// CI checks of the pull requests of the session on screen.
    let checksMonitor = ChecksMonitor()
    /// The overview's choice of states and machines.
    var sessionFilter = SessionFilter()
    /// How busy each machine is, measured while the overview is on screen.
    let usageMonitor = MachineUsageMonitor()
    /// What agents that aren't working left running, such as watchers.
    let background = BackgroundWorkStore()

    init(cluster: ClusterStore = ClusterStore(), order: SessionOrderStore = SessionOrderStore(),
         relations: SessionRelationStore = SessionRelationStore(), sessionStates: SessionStateStore = SessionStateStore()) {
        self.cluster = cluster
        self.order = order
        self.relations = relations
        self.sessionStates = sessionStates
        notifier.model = self
        checksMonitor.model = self
    }

    /// Whether `window` is Shepherdr's one window. Any other window closes in favor of it.
    func adopt(_ window: NSWindow) -> Bool {
        if let main = mainWindow, main !== window, main.isVisible || main.isMiniaturized {
            window.orderOut(nil)
            window.close()
            showMainWindow()
            return false
        }
        mainWindow = window
        window.tabbingMode = .disallowed
        return true
    }

    /// Brings the main window forward, reopening it if it was closed.
    func showMainWindow() {
        guard let main = mainWindow, main.isVisible || main.isMiniaturized else {
            openMainWindow?()
            return
        }
        if main.isMiniaturized { main.deminiaturize(nil) }
        main.makeKeyAndOrderFront(nil)
    }

    func workspace(for id: Agent.ID) -> SessionWorkspace {
        if let workspace = workspaces[id] { return workspace }
        let workspace = SessionWorkspace(restoring: sessionStates.state(for: id)) { [weak self] state in
            self?.sessionStates.set(state, for: id)
        }
        workspaces[id] = workspace
        return workspace
    }

    /// Opens the session that was open when Shepherdr quit, once Herdr reports it; gives up once its
    /// machine answered without it.
    func restoreSelection() {
        guard isRestoringSelection else { return }
        guard let id = sessionStates.lastSelection, selection == .overview else {
            isRestoringSelection = false
            return
        }
        if context(for: id) != nil {
            isRestoringSelection = false
            open(id)
        } else if cluster.machines.first(where: { $0.id == id.machineID })?.snapshot != nil {
            isRestoringSelection = false
        }
    }

    var rankedRows: [AgentRow] { order.ranked(cluster.agents) }
    /// Sessions matching the filter, in priority order, whether or not their group is collapsed.
    var matchingRows: [AgentRow] { rankedRows.filter { $0.matches(search) } }
    /// The overview's sessions: those matching the search, in the chosen states and on the chosen machines.
    var overviewRows: [AgentRow] { matchingRows.filter(sessionFilter.includes) }

    /// The queue as the sidebar shows it. While filtering, groups list only their matching
    /// sessions, unless the group's own name matches.
    var queue: [QueueItem] {
        let items = order.layout(cluster.agents)
        guard !search.isEmpty else { return items }
        return items.compactMap { item in
            switch item {
            case .session(let row):
                return row.matches(search) ? item : nil
            case .group(var group):
                if group.group.name.localizedStandardContains(search) { return item }
                group.rows = group.rows.filter { $0.matches(search) }
                return group.rows.isEmpty && shells(in: group.group).isEmpty ? nil : .group(group)
            }
        }
    }

    /// Sessions shown in the sidebar, in order: ⌘1…⌘9 address these. Collapsed groups and
    /// sessions hide theirs, except while filtering.
    var visibleRows: [AgentRow] {
        let forest = waitForest
        return queue.flatMap { item -> [AgentRow] in
            if case .group(let group) = item, group.group.isCollapsed, search.isEmpty { return [] }
            return item.rows.filter { !forest.isNested($0.id) }.flatMap { forest.rows(from: $0).map(\.row) }
        }
    }

    /// The sidebar's nesting of sessions on hold, for the queue as listed now.
    var waitForest: WaitForest {
        let listed = queue.flatMap(\.rows)
        let parents = relations.parents(in: listed.map(\.id))
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Agent.ID: [AgentRow]] = [:]
        for (waiter, awaited) in relations.waits {
            let nested = awaited.filter { parents[$0] == waiter }.compactMap { byID[$0] }
            if !nested.isEmpty { children[waiter] = nested }
        }
        return WaitForest(parents: parents, children: children,
                          collapsed: search.isEmpty ? relations.collapsed : [], selected: selectedID)
    }

    func toggleNestedSessions(of id: Agent.ID) {
        relations.setCollapsed(id, !relations.isCollapsed(id))
    }

    /// Items moves are relative to: filtering hides some, collapsing does not. Nested sessions
    /// keep their slot but move with the session they are nested under.
    private var movableItems: Set<QueueItemID> {
        let forest = waitForest
        return Set(queue.flatMap { [$0.id] + $0.rows.filter { !forest.isNested($0.id) }.map { QueueItemID.session($0.id) } })
    }

    private var allShells: [ShellRow] {
        cluster.machines.flatMap { state -> [ShellRow] in
            guard let snapshot = state.snapshot else { return [] }
            let agentTerminals = Set(snapshot.agents.map(\.id.terminalID))
            return snapshot.panes.filter { !agentTerminals.contains($0.terminalID) }
                .map { ShellRow(pane: $0, machine: state.machine, isStale: state.isStale) }
        }
    }

    /// Shells matching the filter.
    var shells: [ShellRow] { allShells.filter { $0.matches(search) } }

    /// Shells placed in a group, such as a session created there whose agent has not started.
    /// Like the group's sessions, all of them show while the filter matches the group's name.
    func shells(in group: SessionGroup) -> [ShellRow] {
        let pool = group.name.localizedStandardContains(search) ? allShells : shells
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return group.members.compactMap { byID[$0] }
    }

    /// A group's sessions and shells, in the group's own order.
    func members(of group: QueueGroupRow) -> [GroupMember] {
        let rows = Dictionary(group.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let shells = Dictionary(shells(in: group.group).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return group.group.members.compactMap { id in
            rows[id].map(GroupMember.session) ?? shells[id].map(GroupMember.shell)
        }
    }

    /// Shells in no group, listed under Shells.
    var ungroupedShells: [ShellRow] {
        let grouped = Set(groups.flatMap(\.members))
        return shells.filter { !grouped.contains($0.id) }
    }

    var showsMachineNames: Bool { cluster.machines.count > 1 }
    var selectedID: Agent.ID? { if case .session(let id) = selection { id } else { nil } }
    /// Sessions and shells in sidebar order, for stepping through them.
    private var navigableIDs: [Agent.ID] {
        let forest = waitForest
        let tree = { (row: AgentRow) -> [Agent.ID] in forest.isNested(row.id) ? [] : forest.rows(from: row).map(\.id) }
        return queue.flatMap { item -> [Agent.ID] in
            guard case .group(let group) = item else { return item.rows.flatMap(tree) }
            if group.group.isCollapsed, search.isEmpty { return [] }
            return members(of: group).flatMap { member -> [Agent.ID] in
                if case .session(let row) = member { return tree(row) }
                return [member.agentID]
            }
        } + ungroupedShells.map(\.id)
    }

    func context(for id: Agent.ID) -> SessionContext? {
        guard let machine = cluster.machines.first(where: { $0.id == id.machineID }) else { return nil }
        if let row = cluster.agents.first(where: { $0.id == id }) {
            return SessionContext(target: TerminalTarget(machine: machine.machine, terminalID: id.terminalID,
                                                         title: row.title, workspace: row.workspace),
                                  machine: machine, agent: row, paneID: row.agent.paneID)
        }
        guard let pane = machine.snapshot?.panes.first(where: { $0.terminalID == id.terminalID }) else { return nil }
        return SessionContext(target: TerminalTarget(machine: machine.machine, terminalID: id.terminalID,
                                                     title: pane.title, workspace: pane.workspaceName),
                              machine: machine, agent: nil, paneID: pane.paneID)
    }

    // MARK: Navigation

    func open(_ id: Agent.ID) {
        selection = .session(id)
        focusInput(of: id)
    }

    /// Keyboard focus goes to the terminal, or to the prompt editor when it is open.
    private func focusInput(of id: Agent.ID) {
        if workspace(for: id).isEditorOpen { promptFocusRequest += 1 } else { terminalFocusRequest += 1 }
    }

    func togglePromptEditor() {
        guard let id = selectedID else { return }
        workspace(for: id).isEditorOpen.toggle()
        focusInput(of: id)
    }

    func toggleBrowser() {
        guard let id = selectedID else { return }
        let browser = workspace(for: id).browser
        browser.isVisible.toggle()
        if browser.isVisible && browser.tabs.isEmpty { browser.newTab() }
    }

    /// Links clicked in a session's terminal open in its browser, or in the default browser. Local
    /// Markdown and HTML files open in its browser too; other files in their default app.
    func openLink(_ url: URL, from id: Agent.ID, external: Bool) {
        if external || (url.isFileURL && LocalPage(url) == nil) { NSWorkspace.shared.open(url) }
        else { workspace(for: id).browser.open(url) }
        workspace(for: id).countOpen(of: url)
    }

    /// The local file a path printed in a session names, if it exists: absolute, under ~, or relative
    /// to the session's folder. Files on other machines are not on this Mac.
    func file(at path: String, for id: Agent.ID) -> URL? {
        guard let context = context(for: id), context.machine.machine.isLocal else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        let base = context.agent?.agent.directory
            ?? context.machine.snapshot?.panes.first { $0.terminalID == id.terminalID }?.directory
        let full: String
        if expanded.hasPrefix("/") { full = expanded }
        else if let base { full = (base as NSString).appendingPathComponent(expanded) }
        else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: full).standardizedFileURL
    }

    // MARK: Dropped files

    /// Files dropped on a session's terminal: their paths are typed into its prompt, so agents such as
    /// Claude Code and Codex attach dropped images. On another machine each file is copied there first.
    func drop(_ files: [URL], into id: Agent.ID, terminal: TerminalStore) {
        guard terminal.status == .interactive else {
            sessionNotices[id] = "Unlock the session (⌘E) to drop files into it."
            return
        }
        guard let machine = context(for: id)?.machine.machine else { return }
        guard !machine.isLocal else {
            terminal.send(.bytes(FileDrop.paste(files.map(\.path))))
            return
        }
        let names = files.map(\.lastPathComponent).joined(separator: ", ")
        sessionNotices[id] = "Copying \(names) to \(machine.name)…"
        Task {
            do {
                var paths: [String] = []
                for file in files { paths.append(try await FileDrop.upload(file, to: machine)) }
                if sessionNotices[id]?.hasPrefix("Copying") == true { sessionNotices[id] = nil }
                terminal.send(.bytes(FileDrop.paste(paths)))
            } catch {
                let failure = Self.failure(error)
                sessionNotices[id] = [failure.message, failure.detail].compactMap { $0 }.joined(separator: " ")
            }
        }
    }

    // MARK: Resources

    /// A session's resources, without opening its workspace: the queue shows them for every session.
    func resources(for id: Agent.ID) -> [SessionResource] {
        workspaces[id]?.resources ?? SessionResources.merge([], into: sessionStates.state(for: id).resources)
    }

    /// The session's pull requests, most relevant first.
    func pullRequests(of id: Agent.ID) -> [SessionResource] {
        SessionResources.ranked(resources(for: id), kind: .pullRequest)
    }

    /// The session's issues, most relevant first.
    func issues(of id: Agent.ID) -> [SessionResource] {
        SessionResources.ranked(resources(for: id), kind: .issue)
    }

    /// Opens the session with one of its links in its browser, such as a pull request a notification is about.
    func openLink(_ url: URL, in id: Agent.ID) {
        open(id)
        openLink(url, from: id, external: false)
    }

    /// Opens the session with its pull request in its browser, or the ten most relevant, each in a tab.
    func openPullRequests(of id: Agent.ID) {
        let pulls = pullRequests(of: id)
        open(id)
        if pulls.count == 1 { workspace(for: id).open(pulls[0]) }
        else { workspace(for: id).browser.open(all: pulls.prefix(10).map(\.url)) }
    }

    func collectResources(_ found: [SessionResource], for id: Agent.ID) {
        guard !found.isEmpty else { return }
        workspace(for: id).collect(found)
        checkResources(for: id)
    }

    @ObservationIgnored private let gitHub = GitHubLookup()
    @ObservationIgnored private lazy var pageProbe = PageProbe()
    /// Resources checked this launch: each is checked once, even when the answer was unclear.
    @ObservationIgnored private var checkedThisLaunch = Set<String>()
    @ObservationIgnored private var checkQueue: Task<Void, Never>?

    /// Checks, one at a time, that the session's resources exist and fetches their titles: a link an
    /// agent wrote as an example points nowhere. Settled answers are saved; unclear ones, such as a
    /// sign-in page, are asked again next launch.
    private func checkResources(for id: Agent.ID) {
        let pending = workspace(for: id).resources.filter { !$0.isChecked && checkedThisLaunch.insert($0.key).inserted }
        guard !pending.isEmpty else { return }
        let previous = checkQueue
        checkQueue = Task { [weak self] in
            await previous?.value
            for resource in pending { await self?.check(resource, for: id) }
        }
    }

    private func check(_ resource: SessionResource, for id: Agent.ID) async {
        let workspace = workspace(for: id)
        // GitHub's CLI answers for private repositories too, and says whether it's a pull request.
        if let github = resource.github, gitHub.isAvailable {
            switch await gitHub.look(owner: github.owner, repository: github.repository, number: github.number) {
            case .found(let isPullRequest, let title):
                workspace.update(resource.key) { $0.verified(isPullRequest: isPullRequest).found(title: title) }
                return
            case .missing:
                workspace.update(resource.key) { $0.missing() }
                return
            case .unknown:
                break
            }
        }
        let page = await pageProbe.load(resource.url)
        if page.hostMissing || page.status == 404 || page.status == 410 || page.title.map(ResourceTitles.isNotFoundPage) == true {
            // GitHub answers 404 for private repositories to visitors who aren't signed in.
            if resource.github != nil, !(await PageProbe.isSignedIntoGitHub()) { return }
            workspace.update(resource.key) { $0.missing() }
            return
        }
        // A sign-in page or an error is no answer.
        guard let status = page.status, (200..<400).contains(status), let landed = page.url.flatMap(SessionResource.init(url:)),
              landed.key == resource.key else { return }
        let title = page.title.flatMap { ResourceTitles.clean($0, for: resource) }
        workspace.update(resource.key) { current in
            // Following GitHub's redirect tells a pull request from an issue.
            let settled = current.github != nil ? current.verified(isPullRequest: landed.kind == .pullRequest) : current
            return settled.found(title: title)
        }
    }

    /// Gathers the links a session printed before Shepherdr was watching it.
    func harvestResources(for id: Agent.ID) async {
        // Resources saved earlier are checked too, even when nothing new turns up.
        defer { checkResources(for: id) }
        guard let context = context(for: id), context.canConnect,
              let text = await cluster.recentOutput(paneID: context.paneID, onMachine: id.machineID, lines: 3_000) else { return }
        collectResources(SessionResources.find(in: text), for: id)
    }

    // MARK: Renaming

    struct RenamePrompt: Identifiable {
        let id = UUID()
        let session: Agent.ID
        let workspaceID: String
        var name: String
    }

    func promptRename(_ id: Agent.ID) {
        guard let context = context(for: id) else { return }
        let workspaceID = context.agent?.agent.workspaceID
            ?? context.machine.snapshot?.panes.first { $0.terminalID == id.terminalID }?.workspaceID
        guard let workspaceID else { return }
        renaming = RenamePrompt(session: id, workspaceID: workspaceID, name: context.target.workspace)
    }

    /// Takes the prompt as it was when the button was tapped: dismissing the alert clears
    /// `renaming` right away, before an awaited `Task` would get a chance to read it.
    func commitRename(_ prompt: RenamePrompt) async {
        let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != context(for: prompt.session)?.target.workspace else { return }
        do { try await cluster.renameWorkspace(prompt.workspaceID, to: name, onMachine: prompt.session.machineID) }
        catch { actionFailure = Self.failure(error) }
    }

    // MARK: Dictation

    /// Starts recording for the selected session, or stops and transcribes into its prompt editor.
    func toggleDictation() {
        if dictation.isRecording {
            Task { await finishDictation() }
            return
        }
        guard let id = selectedID, dictation.isReady else { return }
        if !Dictation.isModelInstalled && !speechModelDownloadAccepted {
            asksToDownloadSpeechModel = true
            return
        }
        dictationTarget = id
        workspace(for: id).isEditorOpen = true
        Task { await dictation.start() }
    }

    func acceptSpeechModelDownload() {
        speechModelDownloadAccepted = true
        toggleDictation()
    }

    func cancelDictation() {
        dictation.cancel()
        dictationTarget = nil
    }

    /// Stops dictating into a session that is going away. A transcript still in progress is dropped.
    private func abandonDictation(for id: Agent.ID) {
        guard dictationTarget == id else { return }
        if dictation.isRecording { dictation.cancel() }
        dictationTarget = nil
    }

    private func finishDictation() async {
        let target = dictationTarget
        let text = await dictation.stop()
        // Its session closed while transcribing: the text has nowhere to go.
        guard let target, dictationTarget == target else { return }
        dictationTarget = nil
        guard let text else { return }
        let current = drafts[target] ?? ""
        let separator = current.isEmpty || current.hasSuffix("\n") || current.hasSuffix(" ") ? "" : " "
        drafts[target] = current + separator + text
        workspace(for: target).isEditorOpen = true
        if selectedID == target { promptFocusRequest += 1 }
    }

    // MARK: Sessions on hold

    func waitState(for id: Agent.ID) -> WaitState? {
        let awaited = relations.waitingFor(id)
        guard !awaited.isEmpty else { return nil }
        let busy = awaited.contains { other in
            guard let row = cluster.agents.first(where: { $0.id == other }), !row.isStale else { return false }
            return row.agent.state == .working || row.agent.state == .blocked
        }
        return busy ? .waiting : .ready
    }

    func row(for id: Agent.ID) -> AgentRow? { cluster.agents.first { $0.id == id } }

    func machine(for id: Agent.ID) -> Machine {
        cluster.machines.first { $0.id == id.machineID }?.machine ?? .local
    }

    /// ⌘1…⌘9 address the visible queue by position.
    func open(position: Int) {
        guard visibleRows.indices.contains(position) else { return }
        open(visibleRows[position].id)
    }

    func step(_ delta: Int) {
        let ids = navigableIDs
        guard !ids.isEmpty else { return }
        guard let current = selectedID, let index = ids.firstIndex(of: current) else {
            open(delta > 0 ? ids[0] : ids[ids.count - 1])
            return
        }
        open(ids[(index + delta + ids.count) % ids.count])
    }

    // MARK: Creating and closing sessions

    var onlineMachines: [MachineState] { cluster.machines.filter { $0.connection == .online } }

    /// What a session's agent left running, while it isn't working.
    func backgroundCommands(of row: AgentRow) -> [BackgroundCommand] {
        row.isStale || row.agent.state == .working ? [] : background.commands[row.id] ?? []
    }

    /// Looks for commands agents left running every 10 seconds while the window shows, and as soon
    /// as it shows again.
    func watchBackgroundWork() async {
        while !Task.isCancelled {
            let looks = cluster.lastRefresh != nil && NSApp.occlusionState.contains(.visible)
            if looks { await background.refresh(cluster.agents, machines: onlineMachines.map(\.machine)) }
            do { try await Task.sleep(for: .seconds(looks ? 10 : 1)) } catch { return }
        }
    }

    /// The folders agents on a machine work in, the most used first, then those of shells still
    /// waiting for an agent. Worktrees are left out: they belong to the session that made them.
    func folders(on machineID: String) -> [FolderUse] {
        func isWorktree(_ workspaceID: String) -> Bool {
            cluster.checkout(machineID: machineID, workspaceID: workspaceID)?.isLinkedWorktree == true
        }
        let shells = allShells.filter { $0.machine.id == machineID && !isWorktree($0.pane.workspaceID) }
        return FolderUse.ranked(cluster.agents.filter { $0.id.machineID == machineID }, shells: shells.map(\.pane.directory)) { row in
            isWorktree(row.agent.workspaceID)
        }
    }

    func startNewSession() {
        newSession = NewSessionDraft()
    }

    /// A new session that joins this group.
    func startNewSession(in group: SessionGroup) {
        newSession = NewSessionDraft(placement: .into(group: group.id))
    }

    /// A new session in the same folder and machine as this one, placed right after it.
    func startNewSession(besides id: Agent.ID) {
        guard let directory = directory(of: id) else { return }
        newSession = NewSessionDraft(directory: directory, machineID: id.machineID, placement: .after(.session(id)))
    }

    func canStartNewSession(besides id: Agent.ID) -> Bool {
        directory(of: id) != nil && onlineMachines.contains { $0.id == id.machineID }
    }

    /// Where a session or shell is working, as Herdr reports it.
    func directory(of id: Agent.ID) -> String? {
        if let row = row(for: id) { return row.agent.directory }
        return cluster.machines.first { $0.id == id.machineID }?.snapshot?.panes
            .first { $0.terminalID == id.terminalID }?.directory
    }

    /// Creates a workspace with a shell in Herdr, then opens it. Returns the failure for the sheet to show.
    func createSession(_ request: NewSessionRequest, onMachine machineID: String,
                       placement: QueueDrop? = nil) async -> HerdrFailure? {
        isCreatingSession = true
        defer { isCreatingSession = false }
        do {
            let created = try await cluster.createSession(request, onMachine: machineID)
            let id = Agent.ID(machineID: machineID, terminalID: created.terminalID)
            if let notice = created.notice { sessionNotices[id] = notice }
            if let placement { order.insert(id, placement) }
            newSession = nil
            open(id)
            return nil
        } catch {
            return Self.failure(error)
        }
    }

    func requestClose(_ id: Agent.ID?) {
        if let id, context(for: id) != nil { closingSession = id }
    }

    /// Ends the pane in Herdr after the user confirmed. Leaving the view first detaches this client.
    func closeSession(_ id: Agent.ID) async {
        closingSession = nil
        guard let context = context(for: id) else { return }
        if selectedID == id { selection = .overview }
        do {
            try await cluster.closeSession(paneID: context.paneID, onMachine: id.machineID)
            abandonDictation(for: id)
            drafts[id] = nil
            sessionNotices[id] = nil
            workspaces.removeValue(forKey: id)?.browser.closeAll()
            sessionStates.forget(id)
            relations.forget(id)
        } catch {
            actionFailure = Self.failure(error)
        }
    }

    // MARK: Machines

    func perform(_ change: () async throws -> Void) async -> HerdrFailure? {
        do { try await change(); return nil }
        catch { return Self.failure(error) }
    }

    static func failure(_ error: Error) -> HerdrFailure {
        error as? HerdrFailure ?? HerdrFailure(.unreachable, error.localizedDescription)
    }

    // MARK: Active session

    var canToggleLive: Bool {
        guard let terminal = activeTerminal, terminal.status != .connecting else { return false }
        return selectedID.flatMap(context(for:))?.canConnect == true
    }

    func toggleLive() {
        guard canToggleLive, let terminal = activeTerminal else { return }
        terminal.open(mode: terminal.mode == .observe ? .control : .observe)
    }

    // MARK: Priorities

    func canMove(_ item: QueueItemID?, _ direction: SessionOrderStore.Move) -> Bool {
        order.canMove(item, direction, visible: movableItems)
    }

    func move(_ item: QueueItemID, _ direction: SessionOrderStore.Move) {
        order.move(item, direction, visible: movableItems)
    }

    func canMove(_ id: Agent.ID?, _ direction: SessionOrderStore.Move) -> Bool {
        canMove(id.map(QueueItemID.session), direction)
    }

    func moveSelection(_ direction: SessionOrderStore.Move) {
        if let selectedID { move(.session(selectedID), direction) }
    }

    /// The session or group being dragged in the queue, and the token its drag carries. A drag
    /// that ends outside the queue leaves both behind, so a drop moves the item only when it
    /// carries this token: a later, unrelated text drag can never move it.
    var dragging: QueueItemID?
    @ObservationIgnored var dragToken = ""

    func place(_ item: QueueItemID, _ drop: QueueDrop) {
        order.place(item, drop)
    }

    // MARK: Groups

    struct GroupPrompt: Identifiable {
        enum Kind { case create(with: Agent.ID?), rename(String) }
        let id = UUID()
        let kind: Kind
        var name: String
    }

    /// The group being created or renamed, presented as a name prompt.
    var groupPrompt: GroupPrompt?

    var groups: [SessionGroup] { order.groups }

    func promptNewGroup(with session: Agent.ID? = nil) {
        groupPrompt = GroupPrompt(kind: .create(with: session), name: "")
    }

    func promptRename(_ group: SessionGroup) {
        groupPrompt = GroupPrompt(kind: .rename(group.id), name: group.name)
    }

    func commitGroupPrompt() {
        guard let prompt = groupPrompt else { return }
        groupPrompt = nil
        let name = prompt.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        switch prompt.kind {
        case .create(let session): order.createGroup(named: name, with: session)
        case .rename(let id): order.renameGroup(id, to: name)
        }
    }

    func moveToGroup(_ id: Agent.ID, _ groupID: String?) {
        order.moveToGroup(id, groupID)
    }

    func toggleCollapsed(_ group: SessionGroup) {
        order.setCollapsed(group.id, !group.isCollapsed)
    }

    func ungroup(_ group: SessionGroup) {
        order.ungroup(group.id)
    }

    // MARK: Composer

    func remember(_ prompt: String, for id: Agent.ID) {
        var entries = history[id, default: []]
        if entries.last != prompt { entries.append(prompt) }
        history[id] = Array(entries.suffix(50))
    }

    func prompts(for id: Agent.ID) -> [String] { history[id] ?? [] }
}
