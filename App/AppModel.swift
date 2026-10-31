import AppKit
import Foundation
import Observation
import ShepherdrCore
import ShepherdrDictation
import ShepherdrTerminalUI

enum Destination: Hashable {
    case overview
    /// An agent session or a plain shell pane; both are addressed by machine and terminal ID.
    case session(Agent.ID)

    var sessionID: Agent.ID? { if case .session(let id) = self { id } else { nil } }
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

/// A project's heading in the queue: two or more sessions of one project, in the top level or in
/// one group, in the order they are listed.
struct ProjectRun: Identifiable {
    let id: ProjectRunID
    let rows: [AgentRow]
    /// Collapsed headings hide their sessions, except while filtering.
    let isCollapsed: Bool
}

/// One place at the top level of the queue: a session or group, or a project's heading.
enum QueueSlot: Identifiable {
    case item(QueueItem)
    case project(ProjectRun)

    enum ID: Hashable { case item(QueueItemID), project(ProjectRunID) }

    var id: ID {
        switch self {
        case .item(let item): .item(item.id)
        case .project(let run): .project(run.id)
        }
    }
}

/// One place in an expanded group: a session or shell, or a project's heading.
enum MemberSlot: Identifiable {
    case member(GroupMember)
    case project(ProjectRun)

    enum ID: Hashable { case member(GroupMember.ID), project(ProjectRunID) }

    var id: ID {
        switch self {
        case .member(let member): .member(member.id)
        case .project(let run): .project(run.id)
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

    /// Drops the pull requests, issues and artifacts the session's output no longer mentions, and marks
    /// the rest to be checked again. Links an agent pinned stay.
    func refresh(keeping present: Set<String>) {
        resources = resources.filter { $0.kind == .link || present.contains($0.key) }.map { $0.unchecked() }
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
    /// A session a Compass page asked for: the day and item it came from, and whether Compass's
    /// session waits for it.
    struct FromCompass: Equatable {
        let day: String
        let item: String?
        var compassWaits: Bool
    }

    let id = UUID()
    var directory: String?
    var machineID: String?
    var placement: QueueDrop?
    var name: String?
    /// An agent to start, and the first prompt to send it once it's ready.
    var agentKind: String?
    var prompt: String?
    var compass: FromCompass?
    /// A new worktree's branch, for a session that works apart from the folder's own checkout.
    var worktreeBranch: String?
    /// Links the session starts with in its resources, such as the issue it implements.
    var pins: [URL] = []
}

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
            if let selectedID, selectedID != oldValue.sessionID { courier.sessionOpened(selectedID) }
            if mode == .agents { noteVisit() }
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
    var drafts: [Agent.ID: String] = [:] {
        didSet {
            // Typing to the Compass agent holds back its next run.
            if let id = compass.terminal, drafts[id] != oldValue[id] { compass.noteTyping() }
        }
    }
    /// The queue of sessions, or Compass.
    var mode: AppMode = AppMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .agents {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "mode")
            if mode == .compass { compass.viewed() }
            noteVisit()
        }
    }
    /// The Compass agent, its page and its schedule.
    let compass = CompassController()
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
    /// The overview's browser, for pages that belong to no session, such as the guide. Not saved.
    let overviewBrowser = SessionBrowser()
    /// The terminal shown in the work area, for menu commands.
    var activeTerminal: TerminalStore?

    /// The New Session sheet, while it is open.
    var newSession: NewSessionDraft?
    /// The sheet choosing the repositories the GitHub inbox follows, while it is open.
    var showsGitHubRepositoriesSheet = false
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
    /// The repositories the home screen's GitHub inbox follows, and which items you've seen.
    let githubInbox = GitHubInboxStore()
    /// What GitHub and the machines said about pull requests, issues and repositories, kept so they
    /// aren't asked again; written to disk once a minute and as Shepherdr quits.
    let githubCache = GitHubCache()
    /// The GitHub repository each session's folder is in, as its machine said.
    private(set) var sessionRepositories: [Agent.ID: InboxRepository] = [:]
    @ObservationIgnored private var isLookingUpFolders = false
    /// What GitHub asks of you in those repositories.
    let inboxMonitor = GitHubInboxMonitor()
    /// The overview's choice of states and machines.
    var sessionFilter = SessionFilter()
    /// How busy each machine is, measured while the overview is on screen.
    let usageMonitor = MachineUsageMonitor()
    /// What agents that aren't working left running, such as watchers.
    let background = BackgroundWorkStore()
    /// The agent tools on each machine, and the letters agents send through them.
    let courier = Courier()
    /// New releases of Shepherdr, and updating to them.
    let updates = UpdateController()
    /// When you last looked at each session and at Compass, for ⌘T.
    let visits = VisitStore()
    /// The quick switcher (⌘T), while it is open.
    var isSwitching = false
    /// What the quick switcher opens with typed in, such as a pull request to find its sessions.
    @ObservationIgnored var switcherSeed = ""
    /// Whether Shepherdr can be seen: off screen, other machines are asked less often.
    @ObservationIgnored let presence = ScreenPresence()
    /// Whether this Mac is awake and online enough to start agents with nobody watching.
    @ObservationIgnored let readiness = ReadinessMonitor()
    /// Whether Shepherdr keeps this Mac from sleeping; off every time it opens.
    let keepAwake = KeepAwake()
    let subscriptions = SubscriptionMonitor()

    init(cluster: ClusterStore = ClusterStore(), order: SessionOrderStore = SessionOrderStore(),
         relations: SessionRelationStore = SessionRelationStore(), sessionStates: SessionStateStore = SessionStateStore()) {
        self.cluster = cluster
        self.order = order
        self.relations = relations
        self.sessionStates = sessionStates
        notifier.model = self
        checksMonitor.model = self
        checksMonitor.restore(from: githubCache)
        courier.model = self
        compass.model = self
        relations.onChange = { [weak self] in self?.settleStatuses() }
        presence.onChange { [weak self] onScreen in
            guard let self else { return }
            cluster.isOnScreen = onScreen
            guard onScreen else { return }
            // Back on screen: every machine is asked now, rather than at its next turn.
            if cluster.automaticRefresh { Task { await self.cluster.refresh() } }
            checksMonitor.lookAgain()
        }
        // Awake, or back online: a run that waited for it goes now.
        readiness.onChange { [weak self] in self?.compass.tick() }
        // Commands to each machine share one SSH connection from now on.
        SSHOptions.prepareSharing()
        inboxMonitor.model = self
    }

    /// A refresh you asked for: also looks in every outbox for letters whose doorbell was lost.
    func refreshNow() async {
        await cluster.refresh()
        courier.sweep()
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
            // Back where it was, without leaving the mode Shepherdr quit in.
            selection = .session(id)
            if mode == .agents { focusInput(of: id) }
        } else if cluster.machines.first(where: { $0.id == id.machineID })?.snapshot != nil {
            isRestoringSelection = false
        }
    }

    // MARK: The queue, worked out once

    /// Everything the queue is worked out from. Reading these is also what makes views follow them.
    /// Comparing them is cheap: stored arrays compare by their storage first, and are replaced only
    /// when their contents change.
    private struct QueueInputs: Equatable {
        let agents: [AgentRow]
        let machines: [MachineState]
        let compass: Agent.ID?
        let entries: [SessionOrderStore.Entry]
        let gathersProjects: Bool
        let collapsedProjects: Set<ProjectRunID>
        let holds: [Agent.ID: [Hold]]
        let collapsedWaits: Set<Agent.ID>
        let checkouts: [String: WorkspaceCheckout]
        let selected: Agent.ID?
    }

    /// What the sidebar, the menus and moves derive from the queue, filled in as they ask for it.
    /// Views ask many times per update, some once per row.
    private struct QueueDerived {
        var agents: [AgentRow]?
        var rankedRows: [AgentRow]?
        var gatheredProjects: [Agent.ID: String]??
        var queue: [QueueItem]?
        var forest: WaitForest?
        var listedMembers: [GroupMember]?
        var movableItems: Set<QueueItemID>?
        var allShells: [ShellRow]?
        var projectHeadings: [Agent.ID: ProjectRunID]?
        var directory: SessionDirectory?
    }

    @ObservationIgnored private var derivedInputs: QueueInputs?
    @ObservationIgnored private var derived = QueueDerived()

    /// A derived value for the queue as it is now: worked out the first time it is asked for after
    /// any input changed, then kept.
    private func memo<Value>(_ path: WritableKeyPath<QueueDerived, Value?>, _ compute: () -> Value) -> Value {
        let inputs = QueueInputs(agents: cluster.agents, machines: cluster.machines,
                                 compass: compass.isSetUp ? compass.terminal : nil, entries: order.entries,
                                 gathersProjects: order.gathersProjects, collapsedProjects: order.collapsedProjects,
                                 holds: relations.holds, collapsedWaits: relations.collapsed, checkouts: cluster.checkouts,
                                 selected: selectedID)
        if inputs != derivedInputs {
            derivedInputs = inputs
            derived = QueueDerived()
        }
        if let value = derived[keyPath: path] { return value }
        let value = compute()
        derived[keyPath: path] = value
        return value
    }

    /// The sessions in the queue: every agent but Compass's own, which lives in its mode.
    var agents: [AgentRow] { memo(\.agents) { cluster.agents.filter { !compass.isCompass($0.id) } } }
    var rankedRows: [AgentRow] { memo(\.rankedRows) { order.ranked(agents, projects: gatheredProjects) } }
    /// The overview's sessions, in priority order: those in the chosen states and on the chosen machines.
    var overviewRows: [AgentRow] {
        rankedRows.filter { sessionFilter.includes($0, status: status(of: $0)) }
    }

    /// The queue as the sidebar shows it.
    var queue: [QueueItem] { memo(\.queue) { order.layout(agents, projects: gatheredProjects) } }

    /// Sessions shown in the sidebar, in order: ⌘1…⌘9 address these. Collapsed groups, projects
    /// and sessions hide theirs.
    var visibleRows: [AgentRow] {
        listedMembers.compactMap { if case .session(let row) = $0 { row } else { nil } }
    }

    /// The sessions and grouped shells the sidebar lists, in order, with the sessions nested under each.
    private var listedMembers: [GroupMember] { memo(\.listedMembers) { listMembers() } }

    private func listMembers() -> [GroupMember] {
        let forest = waitForest
        func tree(_ row: AgentRow) -> [GroupMember] {
            forest.isNested(row.id) ? [] : forest.rows(from: row).map { .session($0.row) }
        }
        func project(_ run: ProjectRun) -> [GroupMember] { run.isCollapsed ? [] : run.rows.flatMap(tree) }
        return slots(of: queue, forest: forest).flatMap { slot -> [GroupMember] in
            switch slot {
            case .project(let run): return project(run)
            case .item(.session(let row)): return tree(row)
            case .item(.group(let group)):
                if group.group.isCollapsed { return [] }
                return slots(of: group, forest: forest).flatMap { slot -> [GroupMember] in
                    switch slot {
                    case .project(let run): return project(run)
                    case .member(.session(let row)): return tree(row)
                    case .member(let shell): return [shell]
                    }
                }
            }
        }
    }

    /// The sidebar's nesting of sessions on hold, for the queue as listed now.
    var waitForest: WaitForest { memo(\.forest) { plantForest() } }

    private func plantForest() -> WaitForest {
        let listed = queue.flatMap(\.rows)
        let parents = relations.parents(in: listed.map(\.id))
        let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [Agent.ID: [AgentRow]] = [:]
        for (waiter, awaited) in relations.waits {
            let nested = awaited.filter { parents[$0] == waiter }.compactMap { byID[$0] }
            if !nested.isEmpty { children[waiter] = nested }
        }
        return WaitForest(parents: parents, children: children,
                          collapsed: relations.collapsed, selected: selectedID)
    }

    func toggleNestedSessions(of id: Agent.ID) {
        relations.setCollapsed(id, !relations.isCollapsed(id))
    }

    /// Items moves are relative to: filtering hides some, collapsing does not. Nested sessions
    /// keep their slot but move with the session they are nested under.
    private var movableItems: Set<QueueItemID> {
        memo(\.movableItems) {
            let forest = waitForest
            return Set(queue.flatMap { [$0.id] + $0.rows.filter { !forest.isNested($0.id) }.map { QueueItemID.session($0.id) } })
        }
    }

    private var allShells: [ShellRow] { memo(\.allShells) { findShells() } }

    private func findShells() -> [ShellRow] {
        cluster.machines.flatMap { state -> [ShellRow] in
            guard let snapshot = state.snapshot else { return [] }
            let agentTerminals = Set(snapshot.agents.map(\.id.terminalID))
            // A shell split beside a session shows in it, not on its own.
            return snapshot.panes.filter { !agentTerminals.contains($0.terminalID) && !snapshot.showsInside(shell: $0.terminalID) }
                .filter { !compass.isCompass(Agent.ID(machineID: state.id, terminalID: $0.terminalID)) }
                .map { ShellRow(pane: $0, machine: state.machine, isStale: state.isStale) }
        }
    }

    /// Panes without an agent, on every machine.
    var shells: [ShellRow] { allShells }

    /// Shells placed in a group, such as a session created there whose agent has not started.
    func shells(in group: SessionGroup) -> [ShellRow] {
        let byID = Dictionary(allShells.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
    /// The session the window's commands act on: the one open in Agents, or Compass's agent.
    var focusedID: Agent.ID? { mode == .compass ? compass.agentID : selectedID }
    /// Sessions and shells in sidebar order, for stepping through them.
    private var navigableIDs: [Agent.ID] {
        listedMembers.map(\.agentID) + ungroupedShells.map(\.id)
    }

    func context(for id: Agent.ID) -> SessionContext? {
        guard let machine = cluster.machines.first(where: { $0.id == id.machineID }) else { return nil }
        if let row = cluster.agentsByID[id] {
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
        // Compass's agent lives in its own mode, such as when its notification is clicked.
        if compass.isCompass(id) {
            mode = .compass
            compass.showsAgent = true
            focusInput(of: id)
            return
        }
        // The session first: switching modes notes a visit to whatever is selected then.
        selection = .session(id)
        mode = .agents
        focusInput(of: id)
    }

    /// Puts text in a session's prompt editor for you to send, after any draft already there.
    func fill(_ text: String, into id: Agent.ID) {
        let current = drafts[id] ?? ""
        drafts[id] = current.isEmpty ? text : current + (current.hasSuffix("\n") ? "\n" : "\n\n") + text
        workspace(for: id).isEditorOpen = true
        promptFocusRequest += 1
    }

    /// Keyboard focus goes to the terminal, or to the prompt editor when it is open.
    private func focusInput(of id: Agent.ID) {
        if workspace(for: id).isEditorOpen { promptFocusRequest += 1 } else { terminalFocusRequest += 1 }
    }

    func togglePromptEditor() {
        guard let id = focusedID else { return }
        workspace(for: id).isEditorOpen.toggle()
        focusInput(of: id)
    }

    func toggleBrowser() {
        if mode == .compass {
            compass.showsAgent.toggle()
            return
        }
        let browser = selectedID.map { workspace(for: $0).browser } ?? overviewBrowser
        browser.isVisible.toggle()
        if browser.isVisible && browser.tabs.isEmpty { browser.newTab() }
    }

    /// The bilingual guide bundled with the app.
    static let guide = Bundle.main.url(forResource: "visual-guide", withExtension: "html")
    static let herdrDocumentation = URL(string: "https://herdr.dev/docs/")!

    /// Opens help beside what you are looking at: in the selected session's browser, or the overview's.
    func openHelp(_ url: URL) {
        if let id = selectedID, context(for: id) != nil {
            workspace(for: id).browser.open(url)
        } else {
            selection = .overview
            overviewBrowser.open(url)
        }
    }

    /// Links clicked in a session's terminal open in its browser, or in the default browser. Local
    /// Markdown and HTML files open in its browser too; other files in their default app. A session
    /// named in the terminal opens in Shepherdr, with or without ⌘.
    func openLink(_ url: URL, from id: Agent.ID, external: Bool) {
        if let session = SessionLink.session(in: url) {
            if context(for: session) != nil { open(session) }
            return
        }
        if compass.isCompass(id), !external, !url.isFileURL || LocalPage(url) != nil {
            compass.open(url)
            return
        }
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

    /// A link to the other session or pane that the text at a column of a session's terminal names:
    /// its pane or terminal ID, or its name, as `shepherdr` prints them.
    func sessionLink(in row: [Character], column: Int, from id: Agent.ID) -> URL? {
        // Asked as the pointer moves over a terminal: the sessions it can name are gathered once per change.
        let directory = memo(\.directory) {
            let entries = cluster.machines.flatMap { state -> [SessionDirectory.Entry] in
                guard let snapshot = state.snapshot else { return [] }
                let agents = snapshot.agents.map(SessionDirectory.Entry.init(agent:))
                let agentTerminals = Set(snapshot.agents.map(\.id.terminalID))
                return agents + snapshot.panes.filter { !agentTerminals.contains($0.terminalID) }
                    .map { SessionDirectory.Entry(pane: $0, machineID: state.id) }
            }
            return SessionDirectory(entries: entries, machines: cluster.machines.map(\.machine))
        }
        return directory.session(in: row, column: column, from: id).map(SessionLink.url(for:))
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

    /// Which sessions work on which repositories, pull requests and issues, from the links each one
    /// collected and the repository its folder is in.
    var sessionLinks: SessionLinks {
        SessionLinks(rankedRows.map { ($0.id, resources(for: $0.id)) }, repositories: sessionRepositories)
    }

    /// The repositories the GitHub inbox asks about: those you follow, and those sessions work in,
    /// unless you paused them.
    var followedRepositories: [InboxRepository] {
        githubInbox.activeRepositories(including: sessionLinks.repositories)
    }

    /// Does what an inbox item's button offers: a new session that implements or reviews it, in a
    /// worktree of its own, the one session working on it, or ⌘T to choose among several.
    func perform(_ action: InboxAction, for item: GitHubInboxItem) {
        let name = "\(item.repository.displayName)#\(item.number)"
        switch action {
        case .implement:
            newSession = NewSessionDraft(directory: "https://github.com/\(item.repository.displayName)", agentKind: usualAgentKind,
                                         prompt: "Implement the issue \(name): \(item.title)\n\(item.url.absoluteString)",
                                         worktreeBranch: "issue-\(item.number)", pins: [item.url])
        case .review:
            // A pull request's link gets a worktree of its branch.
            let task = item.kind == .myPullRequest
                ? "Pick up my pull request \(name): \(item.title). Address its review comments and failing checks."
                : "Review the pull request \(name): \(item.title)"
            newSession = NewSessionDraft(directory: item.url.absoluteString, agentKind: usualAgentKind,
                                         prompt: "\(task)\n\(item.url.absoluteString)", pins: [item.url])
        case .open(let id):
            open(id)
        case .choose:
            openSwitcher(query: name)
        }
    }

    /// The agent most sessions run, for sessions Shepherdr suggests.
    private var usualAgentKind: String {
        let kinds = rankedRows.map(\.agent.kind).filter(NewSessionRequest.agentKinds.contains)
        let counts = Dictionary(kinds.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key ?? "claude"
    }

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
        openResources(pullRequests(of: id), of: id)
    }

    /// Opens the session with one of its resources in its browser, or the first ten, each in a tab.
    func openResources(_ resources: [SessionResource], of id: Agent.ID) {
        open(id)
        if resources.count == 1 { workspace(for: id).open(resources[0]) }
        else { workspace(for: id).browser.open(all: resources.prefix(10).map(\.url)) }
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
        if resource.github != nil, let known = githubCache.item(resource.key, since: Date().addingTimeInterval(-7 * 24 * 3600)) {
            if let isPullRequest = known.isPullRequest {
                workspace.update(resource.key) { $0.verified(isPullRequest: isPullRequest).found(title: known.title) }
            } else {
                workspace.update(resource.key) { $0.missing() }
            }
            return
        }
        if let github = resource.github, gitHub.isAvailable {
            switch await gitHub.look(owner: github.owner, repository: github.repository, number: github.number) {
            case .found(let isPullRequest, let title):
                githubCache.remember(GitHubCache.Item(isPullRequest: isPullRequest, title: title), for: resource.key)
                workspace.update(resource.key) { $0.verified(isPullRequest: isPullRequest).found(title: title) }
                return
            case .missing:
                githubCache.remember(.missing, for: resource.key)
                workspace.update(resource.key) { $0.missing() }
                return
            case .unknown:
                break
            }
        }
        let page = await pageProbe.load(resource.url)
        // A page an agent pinned stays whatever it answers: its server may be down, or the page private.
        if resource.kind == .link {
            let loaded = page.status.map { (200..<400).contains($0) } ?? false
            let title = loaded ? page.title.flatMap { ResourceTitles.clean($0, for: resource) } : nil
            workspace.update(resource.key) { $0.found(title: title) }
            return
        }
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

    /// Reads the session's output again: what it no longer mentions is dropped, and what it does is
    /// checked again, along with the state of its pull requests and issues.
    func refreshResources(for id: Agent.ID) async {
        guard let context = context(for: id), context.canConnect,
              let text = await cluster.recentOutput(paneID: context.paneID, onMachine: id.machineID, lines: 3_000) else { return }
        let found = SessionResources.find(in: text)
        let workspace = workspace(for: id)
        workspace.refresh(keeping: Set(found.map(\.key)))
        checkedThisLaunch.subtract(workspace.resources.map(\.key))
        collectResources(found, for: id)
        checkResources(for: id)
        checksMonitor.refresh(id, includingDone: true)
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
        guard let id = focusedID, dictation.isReady else { return }
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
        if focusedID == target { promptFocusRequest += 1 }
    }

    // MARK: Sessions on hold

    /// A session whose awaited sessions are being picked, in a sheet.
    struct WaitPicking: Identifiable {
        let session: Agent.ID
        var id: Agent.ID { session }
    }

    var waitPicking: WaitPicking?

    func pickWaits(for id: Agent.ID) {
        waitPicking = WaitPicking(session: id)
    }

    func row(for id: Agent.ID) -> AgentRow? { cluster.agentsByID[id] }

    /// A pane without an agent, by its ID.
    func shell(for id: Agent.ID) -> ShellRow? { allShells.first { $0.id == id } }

    // MARK: Statuses

    /// Every session's status, as `settleStatuses` last worked it out: views read it, and never work
    /// it out themselves.
    private(set) var statuses: [Agent.ID: SessionStatus] = [:]
    @ObservationIgnored private var engine = StatusEngine()
    @ObservationIgnored private var isSettling = false

    /// A session's status; one not worked out yet, such as one that just appeared, by its own state.
    func status(of row: AgentRow) -> SessionStatus {
        statuses[row.id] ?? SessionStatus.of(OwnStatus(row), isHeld: relations.isHeld(row.id))
    }

    /// A session's or a shell's status; nil when Herdr doesn't show it.
    func status(for id: Agent.ID) -> SessionStatus? {
        if let status = statuses[id] { return status }
        if let row = row(for: id) { return status(of: row) }
        return shell(for: id).map { $0.isStale ? .stale : .shell }
    }

    /// Works statuses out again, from what Herdr shows and the holds as recorded, and moves holds
    /// along. Only sessions whose own state changed, and the sessions waiting for them, are worked
    /// out again. Runs after each refresh, each look at a shell and each change to holds.
    func settleStatuses() {
        guard !isSettling else { return }
        isSettling = true
        defer { isSettling = false }
        let tokens = paneTokens
        restoreHolds(tokens)
        var own: [Agent.ID: OwnStatus] = [:]
        for row in cluster.agents { own[row.id] = OwnStatus(row) }
        for shell in allShells {
            let activity = shellRuns[shell.id]?.activity ?? .atPrompt
            own[shell.id] = OwnStatus(.shell(activity), isStale: shell.isStale)
        }
        let before = relations.holds
        let after = engine.settle(own: own, holds: before)
        for (waiter, holds) in after where holds != before[waiter] {
            for hold in holds where hold.phase == .finished && before[waiter]?.first(where: { $0.awaited == hold.awaited })?.phase != .finished {
                guard let shell = shell(for: hold.awaited) else { continue }
                sessionNotices[waiter] = "\(shell.pane.workspaceName) finished its command."
            }
            relations.setHolds(holds, for: waiter)
        }
        if engine.statuses != statuses { statuses = engine.statuses }
        mirrorHolds(tokens)
    }

    /// Shepherdr's tokens on each pane, by session.
    private var paneTokens: [Agent.ID: [String: String]] {
        var tokens: [Agent.ID: [String: String]] = [:]
        for state in cluster.machines {
            for (terminal, list) in state.snapshot?.tokens ?? [:] { tokens[Agent.ID(machineID: state.id, terminalID: terminal)] = list }
        }
        return tokens
    }

    private func paneID(of id: Agent.ID) -> String? { row(for: id)?.agent.paneID ?? shell(for: id)?.pane.paneID }

    /// Holds this Mac has no record of, such as on a new Mac or after losing its settings, come back
    /// from the tokens on their waiting sessions' panes. Holds dropped here and not yet cleared there
    /// don't.
    private func restoreHolds(_ tokens: [Agent.ID: [String: String]]) {
        let online = Set(cluster.machines.filter { $0.connection == .online }.map(\.id))
        let known = Set(cluster.machines.map(\.id))
        for (waiter, list) in tokens where online.contains(waiter.machineID) && relations.holds[waiter] == nil
            && !relations.unsynced.contains(waiter) && tokenWrites[waiter] == nil {
            let holds = (HoldTokens.decode(list, waiter: waiter) ?? []).filter { known.contains($0.awaited.machineID) }
            if !holds.isEmpty { relations.setHolds(holds, for: waiter, fromHerdr: true) }
        }
    }

    /// What this Mac last asked Herdr to keep for each waiting session, until a refresh shows it there.
    @ObservationIgnored private var tokenWrites: [Agent.ID: [String]] = [:]

    /// Keeps each waiting session's holds as tokens on its pane, rewriting them from here whenever
    /// they differ, and trying again after a refresh when Herdr didn't take them.
    private func mirrorHolds(_ tokens: [Agent.ID: [String: String]]) {
        let shown = tokens.filter { !HoldTokens.values(in: $0.value).isEmpty }.keys
        for waiter in Set(relations.holds.keys).union(relations.unsynced).union(shown) {
            guard cluster.machines.first(where: { $0.id == waiter.machineID })?.connection == .online,
                  let paneID = paneID(of: waiter) else { continue }
            let wanted = HoldTokens.encode(relations.holds[waiter] ?? [], waiter: waiter)
            if HoldTokens.values(in: tokens[waiter] ?? [:]) == wanted {
                tokenWrites[waiter] = nil
                relations.markSynced(waiter)
                continue
            }
            guard tokenWrites[waiter] != wanted else { continue }
            tokenWrites[waiter] = wanted
            var set: [String: String] = [:]
            for (index, value) in wanted.enumerated() { set[HoldTokens.key(index)] = value }
            let clear = Array(HoldTokens.keys.dropFirst(wanted.count))
            Task {
                let written = await cluster.reportTokens(paneID: paneID, set: set, clear: clear, onMachine: waiter.machineID)
                if !written, tokenWrites[waiter] == wanted { tokenWrites[waiter] = nil }
            }
        }
    }

    /// Shells sessions wait for, as Shepherdr last saw them.
    @ObservationIgnored private var shellRuns: [Agent.ID: ShellRun] = [:]
    /// When each session in a hold was first missing from its machine's snapshots.
    @ObservationIgnored private var missingSince: [Agent.ID: Date] = [:]
    @ObservationIgnored private var isCheckingShells = false

    /// After each refresh: holds forget sessions that closed, wherever they were closed, statuses
    /// are worked out again, and shells sessions wait for are looked at.
    /// After each refresh: which GitHub repository each session's folder is in, from what machines
    /// said before, and asking those that answer about folders they haven't been asked about lately,
    /// one machine at a time.
    func learnRepositories(now: Date = Date()) {
        // A folder's repository hardly ever changes; one in none is asked about again sooner.
        let found = now.addingTimeInterval(-7 * 24 * 3600), none = now.addingTimeInterval(-24 * 3600)
        var known: [Agent.ID: InboxRepository] = [:]
        var unknown: [String: Set<String>] = [:]
        for row in cluster.agents where !row.isStale {
            guard let folder = row.agent.directory, !folder.isEmpty else { continue }
            let machine = row.id.machineID
            // Nil: never asked lately. A nil inside: a folder in no repository on GitHub.
            guard let answer = githubCache.repository(ofFolder: folder, onMachine: machine, since: none) else {
                unknown[machine, default: []].insert(folder)
                continue
            }
            guard let name = answer else { continue }
            if let repository = InboxRepository(parsing: name) { known[row.id] = repository }
            if githubCache.repository(ofFolder: folder, onMachine: machine, since: found) == nil {
                unknown[machine, default: []].insert(folder)
            }
        }
        if known != sessionRepositories { sessionRepositories = known }
        guard !unknown.isEmpty, !isLookingUpFolders else { return }
        isLookingUpFolders = true
        Task {
            defer { isLookingUpFolders = false }
            for (machineID, folders) in unknown.sorted(by: { $0.key < $1.key }) {
                guard let machine = cluster.machines.first(where: { $0.id == machineID && $0.connection == .online })?.machine,
                      let answer = await FolderRepositories.lookUp(folders.sorted(), on: machine) else { continue }
                for (folder, repository) in answer {
                    githubCache.remember(repository: repository?.fullName, ofFolder: folder, onMachine: machineID)
                }
            }
            learnRepositories()
        }
    }

    func keepHolds() {
        let held = Set(relations.holds.keys).union(relations.holds.values.joined().map(\.awaited)).union(relations.unsynced)
        let gone = HoldUpkeep.gone(held, machines: cluster.machines, missingSince: &missingSince)
        for id in gone {
            for waiter in relations.waiters(of: id) where !gone.contains(waiter) {
                sessionNotices[waiter] = "A session this one waited for closed, so it no longer waits for it."
            }
            relations.forget(id)
        }
        settleStatuses()
        checkShells()
    }

    /// The shells Shepherdr looks at: those a session waits for, until that hold finishes. Nothing
    /// else is asked about.
    private func watchedShells() -> [ShellRow] {
        let awaited = Set(relations.holds.values.joined().filter { $0.phase != .finished }.map(\.awaited))
        guard !awaited.isEmpty else { return [] }
        return allShells.filter { awaited.contains($0.id) && !$0.isStale }
    }

    /// Looks at each watched shell, one at a time, unless the last look is still going.
    private func checkShells() {
        let shells = watchedShells()
        let watched = Set(shells.map(\.id))
        shellRuns = shellRuns.filter { watched.contains($0.key) }
        guard !shells.isEmpty, !isCheckingShells else { return }
        isCheckingShells = true
        Task {
            defer { isCheckingShells = false }
            for shell in shells.sorted(by: { ($0.id.machineID, $0.id.terminalID) < ($1.id.machineID, $1.id.terminalID) }) {
                guard let running = await cluster.runsCommand(paneID: shell.pane.paneID, onMachine: shell.id.machineID) else { continue }
                let output = running ? nil : await cluster.recentOutput(paneID: shell.pane.paneID, onMachine: shell.id.machineID, lines: 40)
                guard watchedShells().contains(where: { $0.id == shell.id }) else { continue }
                var run = shellRuns[shell.id] ?? ShellRun()
                run.see(running: running, output: output)
                guard run != shellRuns[shell.id] else { continue }
                shellRuns[shell.id] = run
                settleStatuses()
            }
        }
    }

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

    // MARK: What stays of sessions out of sight

    /// Somewhere you go back to, for how much what it keeps is worth keeping.
    private enum CachePlace: Hashable {
        case session(Agent.ID), compass, overview
    }

    /// Terminals kept while their sessions are out of sight, with what they last showed.
    @ObservationIgnored private var terminals: [Agent.ID: TerminalHolder] = [:]
    @ObservationIgnored private var interest: [CachePlace: SessionCache.Interest] = [:]
    @ObservationIgnored private var memoryPressure = SessionCache.Pressure.normal
    @ObservationIgnored private var pressureSource: DispatchSourceMemoryPressure?

    /// The session's terminal: the one kept since it was last shown, or a new one, which connects
    /// once it is.
    func terminal(for context: SessionContext, mode: TerminalMode) -> TerminalHolder {
        let id = Agent.ID(machineID: context.machine.id, terminalID: context.target.terminalID)
        if let holder = terminals[id], holder.store.target == context.target { return holder }
        terminals.removeValue(forKey: id)?.close()
        let defaults = UserDefaults.standard
        let size = defaults.double(forKey: "terminalFontSize")
        let font = ConsoleFonts.font(family: defaults.string(forKey: "terminalFontFamily") ?? ConsoleFonts.defaultFamily,
                                     size: size > 0 ? size : 13, ligatures: defaults.bool(forKey: ConsoleFonts.ligaturesKey))
        let holder = TerminalHolder(store: TerminalStore(target: context.target, mode: mode), palette: Theme.terminal, font: font)
        let paneID = context.paneID
        holder.store.onGone = { [weak self] in self?.paneEnded(id, paneID: paneID) }
        terminals[id] = holder
        return holder
    }

    /// A pane whose terminal ended in Herdr, such as a shell you typed `exit` in, leaves at once, as
    /// when you close it here. Its terminal goes with the next trim, once nothing shows it.
    private func paneEnded(_ pane: Agent.ID, paneID: String) {
        guard context(for: pane) != nil else { return }
        let wasFocused = selectedID.map { $0 != pane && focusedPane(in: $0) == pane } ?? false
        Task {
            await cluster.paneClosed(paneID, onMachine: pane.machineID)
            // The session's own pane takes the keyboard again.
            if wasFocused { terminalFocusRequest += 1 }
        }
    }

    /// Detaches every terminal, as Shepherdr quits.
    /// Writes what is kept in memory and belongs on disk, as Shepherdr quits.
    func saveCaches() {
        githubCache.save()
    }

    func closeTerminals() {
        for holder in terminals.values { holder.close() }
        terminals = [:]
    }

    /// Where you are counts as a visit: what it keeps is worth keeping a little longer.
    private func noteInterest(now: Date = Date()) {
        let place: CachePlace = switch (mode, selection) {
        case (.compass, _): .compass
        case (_, .overview): .overview
        case (_, .session(let id)): .session(id)
        }
        interest[place, default: .init()].visit(at: now)
        // A session's splits are part of it.
        if case .session(let id) = place {
            for pane in split(of: id) ?? [] where pane.terminalID != id.terminalID {
                interest[.session(Agent.ID(machineID: id.machineID, terminalID: pane.terminalID)), default: .init()].visit(at: now)
            }
        }
        trimCaches(now: now)
    }

    /// Lets go of what is least worth keeping, when there is more than its limit for how short of
    /// memory macOS is: terminals of the sessions you go back to least, then their pages, which
    /// load again when shown. What is on screen, Compass's and the sessions that need you stay.
    /// Terminals of sessions Herdr no longer shows go at once.
    func trimCaches(now: Date = Date()) {
        func score(_ place: CachePlace) -> Double { interest[place]?.score(at: now) ?? 0 }
        var kept = Set(cluster.agents.filter { !$0.isStale && $0.agent.state == .blocked }.map(\.id))
        if let id = compass.terminal { kept.insert(id) }
        for (id, holder) in terminals where context(for: id) == nil && !holder.isShown {
            terminals.removeValue(forKey: id)?.close()
        }
        let terminalItems = terminals.map { id, holder in
            SessionCache.Item(id: id, isLoaded: true, isKept: holder.isShown || kept.contains(id),
                              interest: score(.session(id)), lastShown: holder.lastShown)
        }
        for id in SessionCache.toRelease(terminalItems, limit: SessionCache.terminalLimit(memoryPressure)) {
            terminals.removeValue(forKey: id)?.close()
        }

        let browsers = workspaces.map { ($0.value.browser, CachePlace.session($0.key)) }
            + [(overviewBrowser, .overview), (compass.browser, .compass)]
        let tabs = browsers.flatMap { browser, place in browser.tabs.map { ($0, score(place)) } }
        let pageItems = tabs.map { tab, interest in
            SessionCache.Item(id: tab.id, isLoaded: tab.holdsPage, isKept: tab.isShown || !tab.canUnload,
                              interest: interest, lastShown: tab.lastShown)
        }
        let unloading = Set(SessionCache.toRelease(pageItems, limit: SessionCache.pageLimit(memoryPressure)))
        for (tab, _) in tabs where unloading.contains(tab.id) { tab.unload() }
    }

    /// Keeps what stays of sessions within bounds: when macOS says it is short of memory, and once
    /// a minute, as sessions come to need you or close.
    func watchCaches() async {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        pressureSource = source
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.memoryPressureChanged() }
        }
        source.activate()
        defer {
            source.cancel()
            pressureSource = nil
        }
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            trimCaches()
            githubCache.save()
        }
    }

    private func memoryPressureChanged() {
        guard let event = pressureSource?.data else { return }
        memoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
        trimCaches()
    }

    /// Looks for commands agents left running every 10 seconds while the window shows, and as soon
    /// as it shows again.
    func watchBackgroundWork() async {
        while !Task.isCancelled {
            // Nothing to look at while Shepherdr can't be seen: wait, rather than check every second.
            await presence.untilOnScreen()
            let looks = cluster.lastRefresh != nil
            if looks { await background.refresh(agents, machines: onlineMachines.map(\.machine)) }
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
        return FolderUse.ranked(agents.filter { $0.id.machineID == machineID }, shells: shells.map(\.pane.directory)) { row in
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

    /// The folder a session works in, when it is on this Mac and still there: Finder can open it.
    func localFolder(of id: Agent.ID) -> URL? {
        guard id.machineID == Machine.local.id, let directory = directory(of: id) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    /// Opens a session's folder in a Finder window.
    func showFolder(of id: Agent.ID) {
        guard let folder = localFolder(of: id) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(folder)
    }

    /// What the Finder button says: where the folder is, or why Finder can't open it.
    func folderHelp(for id: Agent.ID) -> String {
        guard let directory = directory(of: id) else { return "Herdr doesn't say which folder this session works in" }
        guard id.machineID == Machine.local.id else {
            return "\(directory) is on \(machine(for: id).name). Finder only opens folders on this Mac."
        }
        return localFolder(of: id) == nil ? "\(directory) isn't there anymore" : "Open \((directory as NSString).abbreviatingWithTildeInPath) in Finder (⇧⌘O)"
    }

    /// The main checkouts sessions on a machine work in whose repository has this name, where a
    /// clone of it may already be.
    func clones(named name: String, on machineID: String) -> [String] {
        let prefix = machineID + "/"
        let paths = cluster.checkouts.filter { key, checkout in
            key.hasPrefix(prefix) && !checkout.isLinkedWorktree && checkout.repository.lowercased() == name.lowercased()
        }.map(\.value.path)
        return Array(Set(paths)).sorted()
    }

    /// Creates a workspace with a shell, or an agent, in Herdr, then opens it. A first prompt
    /// waits for the agent to be ready. A session a Compass page asked for stays out of sight,
    /// and the page shows it. Returns the failure for the sheet to show.
    /// - Parameter pins: links the session starts with in its resources, such as its pull request.
    func createSession(_ request: NewSessionRequest, onMachine machineID: String,
                       placement: QueueDrop? = nil, pins: [URL] = [], prompt: String? = nil,
                       compass from: NewSessionDraft.FromCompass? = nil) async -> HerdrFailure? {
        isCreatingSession = true
        defer { isCreatingSession = false }
        do {
            let created = try await cluster.createSession(request, onMachine: machineID)
            let id = Agent.ID(machineID: machineID, terminalID: created.terminalID)
            if let notice = created.notice { sessionNotices[id] = notice }
            // A worktree Herdr already had open keeps its place in the queue.
            if let placement, !created.isExisting { order.insert(id, placement, projects: gatheredProjects) }
            collectResources(pins.compactMap(SessionResource.init(url:)), for: id)
            if let prompt { courier.queuePrompt(prompt, for: id, name: request.name) }
            newSession = nil
            if let from { compass.started(id, named: request.name, for: from) } else { open(id) }
            return nil
        } catch {
            return Self.failure(error)
        }
    }

    /// Lets go of everything Shepherdr kept for a session that closed.
    func forgetSession(_ id: Agent.ID) {
        abandonDictation(for: id)
        drafts[id] = nil
        sessionNotices[id] = nil
        focusedPanes[id] = nil
        workspaces.removeValue(forKey: id)?.browser.closeAll()
        sessionStates.forget(id)
        relations.forget(id)
    }

    func requestClose(_ id: Agent.ID?) {
        if let id, context(for: id) != nil { closingSession = id }
    }

    /// Ends the pane in Herdr after the user confirmed. Leaving the view first detaches this client.
    /// Returns whether Herdr closed it.
    @discardableResult
    func closeSession(_ id: Agent.ID) async -> Bool {
        closingSession = nil
        guard let context = context(for: id) else { return false }
        if selectedID == id { selection = .overview }
        do {
            try await cluster.closeSession(paneID: context.paneID, onMachine: id.machineID)
            forgetSession(id)
            return true
        } catch {
            actionFailure = Self.failure(error)
            return false
        }
    }

    // MARK: Splits

    /// The pane of each session you work in, when it's one of its splits rather than its own.
    var focusedPanes: [Agent.ID: Agent.ID] = [:]
    /// A split ⌘W asked to close while something runs in it, waiting for you to confirm.
    var closingSplit: Agent.ID?

    /// The panes a session shows side by side or stacked, when its Herdr tab has more than one.
    func split(of id: Agent.ID) -> [SplitPane]? {
        cluster.machines.first { $0.id == id.machineID }?.snapshot?.split(of: id.terminalID)
    }

    /// The pane of a session you work in: the split you last clicked, else the session's own.
    func focusedPane(in session: Agent.ID) -> Agent.ID {
        guard let pane = focusedPanes[session],
              split(of: session)?.contains(where: { $0.terminalID == pane.terminalID }) == true else { return session }
        return pane
    }

    func focusPane(_ pane: Agent.ID, in session: Agent.ID) {
        let chosen = pane == session ? nil : pane
        if focusedPanes[session] != chosen { focusedPanes[session] = chosen }
    }

    /// Whether ⌘D can split the pane you work in: in Agents, on a machine that answers.
    var canSplit: Bool {
        guard mode == .agents, let id = selectedID, let context = context(for: focusedPane(in: id)) else { return false }
        return context.canConnect && !context.isStale
    }

    /// Splits the pane you work in, beside it or under it, with a shell in its folder, and moves
    /// you to the new pane once Herdr shows it.
    func split(_ direction: SplitDirection) {
        guard canSplit, let session = selectedID else { return }
        let pane = focusedPane(in: session)
        guard let context = context(for: pane) else { return }
        let directory = context.agent?.agent.directory
            ?? context.machine.snapshot?.panes.first { $0.terminalID == pane.terminalID }?.directory
        Task {
            do {
                let terminal = try await cluster.splitPane(context.paneID, direction, directory: directory, onMachine: pane.machineID)
                focusPane(Agent.ID(machineID: pane.machineID, terminalID: terminal), in: session)
                terminalFocusRequest += 1
            } catch {
                actionFailure = Self.failure(error)
            }
        }
    }

    /// ⌘W in a split: a shell at its prompt closes at once; an agent, a running command or a pane
    /// Herdr can't tell about waits for you to confirm.
    func requestCloseSplit(_ pane: Agent.ID) {
        guard let context = context(for: pane) else { return }
        guard context.agent == nil else {
            closingSplit = pane
            return
        }
        Task {
            if await cluster.runsCommand(paneID: context.paneID, onMachine: pane.machineID) == false { await closeSplit(pane) }
            else { closingSplit = pane }
        }
    }

    /// Ends a split's pane in Herdr; the session's own pane takes the keyboard again.
    func closeSplit(_ pane: Agent.ID) async {
        closingSplit = nil
        guard let context = context(for: pane) else { return }
        do {
            try await cluster.closeSession(paneID: context.paneID, onMachine: pane.machineID)
            forgetSession(pane)
            // Its terminal ended with the pane; nothing would show it again.
            terminals.removeValue(forKey: pane)?.close()
            terminalFocusRequest += 1
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
        order.canMove(item, direction, visible: movableItems, projects: gatheredProjects)
    }

    func move(_ item: QueueItemID, _ direction: SessionOrderStore.Move) {
        order.move(item, direction, visible: movableItems, projects: gatheredProjects)
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
        order.place(item, drop, projects: gatheredProjects)
    }

    /// Within one list, a project's sessions stay under its heading: one dropped elsewhere in
    /// that list would only come back to it. Into another list, it can go anywhere.
    func allowsDrop(_ item: QueueItemID, _ drop: QueueDrop) -> Bool {
        guard case .session(let id) = item else { return true }
        let headings = projectHeadings
        guard let run = headings[id] else { return true }
        let list: String?
        switch drop {
        case .into: return true
        case .end, .before(.group), .after(.group): list = nil
        case .before(.session(let target)), .after(.session(let target)):
            if headings[target] == run { return true }
            list = order.group(containing: target)?.id
        }
        return list != run.group
    }

    // MARK: Projects

    /// The project a session works on: its repository, which its main checkout and its worktrees
    /// share on any machine, or outside Git its folder's name.
    func project(of row: AgentRow) -> String? {
        if let repository = cluster.checkout(machineID: row.id.machineID, workspaceID: row.agent.workspaceID)?.repository,
           !repository.isEmpty {
            return repository
        }
        return row.agent.project
    }

    /// Each session's project while the queue gathers projects. Sessions a session waits for are
    /// listed under it instead, so they never pull their project's heading to their own place.
    var gatheredProjects: [Agent.ID: String]? { memo(\.gatheredProjects) { gatherProjects() } }

    private func gatherProjects() -> [Agent.ID: String]? {
        guard order.gathersProjects else { return nil }
        let nested = relations.parents(in: agents.map(\.id))
        var projects: [Agent.ID: String] = [:]
        for row in agents where nested[row.id] == nil {
            if let project = project(of: row) { projects[row.id] = project }
        }
        return projects
    }

    /// The top level of the queue as the sidebar lists it: with projects gathered, a project with
    /// two or more sessions there shows them under its heading, where its first one is.
    func slots(of items: [QueueItem], forest: WaitForest) -> [QueueSlot] {
        guard order.gathersProjects else { return items.map(QueueSlot.item) }
        return ProjectRuns.segments(items) { item in
            guard case .session(let row) = item, !forest.isNested(row.id) else { return nil }
            return project(of: row)
        }.map { segment in
            switch segment {
            case .single(let item): .item(item)
            case .project(let name, let items): .project(projectRun(ProjectRunID(group: nil, project: name), items.flatMap(\.rows)))
            }
        }
    }

    /// An expanded group's sessions and shells, with its projects gathered the same way.
    func slots(of group: QueueGroupRow, forest: WaitForest) -> [MemberSlot] {
        let members = members(of: group)
        guard order.gathersProjects else { return members.map(MemberSlot.member) }
        return ProjectRuns.segments(members) { member in
            guard case .session(let row) = member, !forest.isNested(row.id) else { return nil }
            return project(of: row)
        }.map { segment in
            switch segment {
            case .single(let member): .member(member)
            case .project(let name, let members):
                .project(projectRun(ProjectRunID(group: group.id, project: name),
                                    members.compactMap { if case .session(let row) = $0 { row } else { nil } }))
            }
        }
    }

    private func projectRun(_ id: ProjectRunID, _ rows: [AgentRow]) -> ProjectRun {
        ProjectRun(id: id, rows: rows, isCollapsed: order.isCollapsed(id))
    }

    /// The heading each session is listed under.
    private var projectHeadings: [Agent.ID: ProjectRunID] { memo(\.projectHeadings) { headProjects() } }

    private func headProjects() -> [Agent.ID: ProjectRunID] {
        guard order.gathersProjects else { return [:] }
        let forest = waitForest
        var headings: [Agent.ID: ProjectRunID] = [:]
        func note(_ run: ProjectRun) { for row in run.rows { headings[row.id] = run.id } }
        for slot in slots(of: queue, forest: forest) {
            switch slot {
            case .project(let run): note(run)
            case .item(.group(let group)):
                for case .project(let run) in slots(of: group, forest: forest) { note(run) }
            case .item(.session): break
            }
        }
        return headings
    }

    func canMove(_ project: ProjectRunID, _ direction: SessionOrderStore.Move) -> Bool {
        guard let projects = gatheredProjects else { return false }
        return order.canMove(project, direction, visible: movableItems, projects: projects)
    }

    func move(_ project: ProjectRunID, _ direction: SessionOrderStore.Move) {
        guard let projects = gatheredProjects else { return }
        order.move(project, direction, visible: movableItems, projects: projects)
    }

    func toggleCollapsed(_ project: ProjectRunID) {
        order.setCollapsed(project, !order.isCollapsed(project))
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

    // MARK: Quick switcher

    /// Where you are: Compass, or the session open in Agents.
    private var currentPlace: VisitStore.Place? {
        mode == .compass ? .compass : selectedID.map(VisitStore.Place.session)
    }

    private func noteVisit() {
        if let currentPlace { visits.record(currentPlace) }
        noteInterest()
    }

    /// What ⌘T offers for what was typed: Compass, every session and every shell, the one visited
    /// most recently first and never the one on screen. Every word must match somewhere, and
    /// `name@machine` narrows to a machine, as in Wait For.
    func switchTargets(matching query: String) -> [SwitchTarget] {
        let (words, machine) = SessionSearch.terms(of: query)
        func onMachine(_ name: String) -> Bool { machine.map { name.localizedStandardContains($0) } ?? true }
        var targets: [SwitchTarget] = []
        if machine == nil, words.allSatisfy({ "compass".localizedStandardContains($0) }) { targets.append(.compass) }
        // A session matches by its own names, or by the pull requests and issues it links to.
        targets += rankedRows.filter { row in
            onMachine(row.machineName) && words.allSatisfy { word in
                row.matches(word) || resources(for: row.id).contains { SessionSearch.matches($0, word: word) }
                    || sessionRepositories[row.id]?.id.localizedStandardContains(word) == true
            }
        }.map(SwitchTarget.session)
        targets += allShells.filter { onMachine($0.machine.name) && words.allSatisfy($0.matches) }.map(SwitchTarget.shell)
        return visits.recentFirst(targets, place: \.place, excluding: currentPlace)
    }

    func toggleSwitcher() {
        if isSwitching { closeSwitcher() } else { isSwitching = true }
    }

    /// Opens the quick switcher with something typed in, such as `theam/shepherdr#12` to choose
    /// among the sessions working on it.
    func openSwitcher(query: String) {
        switcherSeed = query
        isSwitching = true
    }

    /// Closes the switcher without going anywhere: the keyboard goes back where it was.
    func closeSwitcher() {
        isSwitching = false
        if let focusedID { focusInput(of: focusedID) }
    }

    func switchTo(_ target: SwitchTarget) {
        isSwitching = false
        switch target {
        case .compass: mode = .compass
        case .session(let row): open(row.id)
        case .shell(let shell): open(shell.id)
        }
    }

    // MARK: Composer

    func remember(_ prompt: String, for id: Agent.ID) {
        var entries = history[id, default: []]
        if entries.last != prompt { entries.append(prompt) }
        history[id] = Array(entries.suffix(50))
    }

    func prompts(for id: Agent.ID) -> [String] { history[id] ?? [] }
}

/// Somewhere the quick switcher (⌘T) can take you.
enum SwitchTarget: Identifiable {
    case compass
    case session(AgentRow)
    case shell(ShellRow)

    var place: VisitStore.Place {
        switch self {
        case .compass: .compass
        case .session(let row): .session(row.id)
        case .shell(let shell): .session(shell.id)
        }
    }

    var id: VisitStore.Place { place }
}
