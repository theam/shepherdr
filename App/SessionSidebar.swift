import SwiftUI
import ShepherdrCore

/// The priority queue: every agent session in the user's order, with reordering controls.
struct SessionSidebar: View {
    @Bindable var model: AppModel
    @AppStorage("refreshSeconds") private var refreshSeconds = 5
    @ViewState<Bool> private var showShells = true
    /// Where a drag in progress would land, drawn as a line or a highlighted group.
    @ViewState<QueueDrop?> private var dropHint: QueueDrop?
    @FocusState private var searchFocused: Bool

    private var cluster: ClusterStore { model.cluster }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField.padding(.horizontal, 12).padding(.bottom, 10)
            Rectangle().fill(Theme.line).frame(height: 1)
            queue
            Rectangle().fill(Theme.line).frame(height: 1)
            footer
        }
        .background(Theme.panel)
        .alert(groupPromptTitle, isPresented: Binding { model.groupPrompt != nil } set: { if !$0 { model.groupPrompt = nil } }) {
            TextField("Group name", text: Binding { model.groupPrompt?.name ?? "" } set: { model.groupPrompt?.name = $0 })
            Button(isRenaming ? "Rename" : "Create") { model.commitGroupPrompt() }
            Button("Cancel", role: .cancel) { model.groupPrompt = nil }
        } message: {
            Text("Group sessions however you like: a project, a client, personal work… Groups move like a session, and their sessions keep their own order.")
        }
    }

    private var isRenaming: Bool {
        if case .rename = model.groupPrompt?.kind { true } else { false }
    }

    private var groupPromptTitle: String { isRenaming ? "Rename Group" : "New Group" }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.selection = .overview } label: {
                HStack(alignment: .center, spacing: 10) {
                    PixelFlock(pixel: 1.5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("SHEPHERDR").font(Theme.mono(13, .heavy)).tracking(2.5).foregroundStyle(Theme.text)
                        Text(summaryLine).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Overview (⌘0)")
            Button { model.startNewSession() } label: { Text("+").font(Theme.mono(14, .bold)) }
                .buttonStyle(ConsoleButtonStyle())
                .disabled(model.onlineMachines.isEmpty)
                .help("New session (⌘N)")
        }
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 12)
    }

    private var summaryLine: String {
        let live = cluster.agents.filter { !$0.isStale }
        let working = live.filter { $0.agent.state == .working }.count
        let blocked = live.filter { $0.agent.state == .blocked }.count
        return blocked > 0 ? "\(blocked) need you · \(working) working" : "\(live.count) agent\(live.count == 1 ? "" : "s") · \(working) working"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Text("/").font(Theme.mono(12, .bold)).foregroundStyle(Theme.phosphor)
            TextField("filter sessions", text: $model.search)
                .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.text)
                .focused($searchFocused)
                .onExitCommand { model.search = ""; searchFocused = false }
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Text("×").font(Theme.mono(13)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.dim).help("Clear filter")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .strokeBorder(searchFocused ? Theme.phosphor.opacity(0.6) : Theme.line, lineWidth: 1))
        .background { Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0) }
    }

    private var queue: some View {
        let filtering = !model.search.isEmpty
        // Sessions on hold list the sessions they wait for under them, instead of in their own place.
        let forest = model.waitForest
        return ScrollView {
            // A plain stack: the queue is short, and a lazy stack whose rows measure themselves
            // could loop on layout and freeze the window.
            VStack(alignment: .leading, spacing: 0) {
                queueHeader
                ForEach(model.queue) { item in
                    switch item {
                    case .session(let row):
                        if !forest.isNested(row.id) {
                            ForEach(forest.rows(from: row)) { tree in sessionRow(tree, in: nil, isFirst: false, isLast: false) }
                        }
                    case .group(let group):
                        let expanded = !group.group.isCollapsed || filtering
                        GroupHeaderView(group: group, isExpanded: expanded,
                                        containsSelection: model.selectedID.map(group.group.members.contains) == true,
                                        model: model, hint: $dropHint)
                        if expanded {
                            let members = model.members(of: group)
                            let listed = members.flatMap { member -> [TreeRow] in
                                guard case .session(let row) = member, !forest.isNested(row.id) else { return [] }
                                return forest.rows(from: row)
                            }
                            ForEach(members) { member in
                                switch member {
                                case .session(let row):
                                    if !forest.isNested(row.id) {
                                        ForEach(forest.rows(from: row)) { tree in
                                            sessionRow(tree, in: group, isFirst: tree.id == listed.first?.id,
                                                       isLast: tree.id == listed.last?.id)
                                        }
                                    }
                                case .shell(let shell): shellRow(shell, grouped: true)
                                }
                            }
                            if members.isEmpty {
                                EmptyGroupView(group: group.group, model: model, hint: $dropHint)
                            }
                        }
                    }
                }
                if model.queue.isEmpty { emptyQueue }
                QueueEndView(model: model, hint: $dropHint)
                shellsSection
            }
        }
    }

    private var queueHeader: some View {
        HStack(spacing: 10) {
            ConsoleHeader(title: "Queue", trailing: model.search.isEmpty ? "\(model.matchingRows.count)"
                                                                          : "\(model.matchingRows.count) match")
            Button { model.promptNewGroup() } label: { Text("+ group").font(Theme.mono(9.5, .semibold)) }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.phosphor.opacity(0.8))
                .help("New group. Drag sessions into it, or use a session's context menu.")
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    private func sessionRow(_ tree: TreeRow, in group: QueueGroupRow?, isFirst: Bool, isLast: Bool) -> some View {
        SessionRowView(tree: tree, group: group?.group, isFirst: isFirst, isLast: isLast,
                       isSelected: model.selectedID == tree.id, showsMachine: model.showsMachineNames,
                       model: model, hint: $dropHint)
    }

    @ViewBuilder private var shellsSection: some View {
        let shells = model.ungroupedShells
        if !shells.isEmpty {
            Button { showShells.toggle() } label: {
                ConsoleHeader(title: "\(showShells ? "▾" : "▸") Shells", trailing: "\(shells.count)")
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 4)
            .help("Panes without a detected agent")
            if showShells {
                ForEach(shells, id: \.listID) { shell in shellRow(shell, grouped: false) }
            }
        }
    }

    private func shellRow(_ shell: ShellRow, grouped: Bool) -> some View {
        ShellRowView(shell: shell, isGrouped: grouped, isSelected: model.selectedID == shell.id,
                     showsMachine: model.showsMachineNames) { model.open(shell.id) }
            .contextMenu {
                Button("Open") { model.open(shell.id) }
                Button("Rename…") { model.promptRename(shell.id) }.disabled(shell.isStale)
                Button("New Session in Same Folder…") { model.startNewSession(besides: shell.id) }
                    .disabled(!model.canStartNewSession(besides: shell.id))
                if grouped {
                    Divider()
                    Button("Remove from Group") { model.moveToGroup(shell.id, nil) }
                }
                Divider()
                Button("Close Shell…") { model.requestClose(shell.id) }.disabled(shell.isStale)
            }
    }

    @ViewBuilder private var emptyQueue: some View {
        let text: String = if !model.search.isEmpty { "no match for \"\(model.search)\"" }
            else if cluster.isRefreshing && cluster.lastRefresh == nil { "connecting to herdr…" }
            else if cluster.onlineCount == 0 { "herdr is not reachable.\nopen settings (⌘,) for details." }
            else { "no agents running.\nstart one in herdr." }
        Text(text).font(Theme.mono(11)).foregroundStyle(Theme.faint)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            LidStatus(cluster: cluster)
            connectionStatus
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var connectionStatus: some View {
        HStack(spacing: 8) {
            let enabled = cluster.machines.filter(\.machine.isEnabled)
            ConnectionDot(state: cluster.onlineCount == enabled.count && !enabled.isEmpty ? .online
                          : cluster.onlineCount == 0 ? .unreachable : .loading)
            Text(enabled.count == 1 ? (cluster.onlineCount == 1 ? "local online" : "local offline")
                                    : "\(cluster.onlineCount)/\(enabled.count) online")
            Spacer(minLength: 4)
            if cluster.isRefreshing {
                Text("sync…").foregroundStyle(Theme.phosphor.opacity(0.7))
            } else {
                Text(refreshSeconds == 0 ? "paused" : "↻ \(refreshSeconds)s")
                    .help(cluster.lastRefresh.map { "Checked \($0.formatted(date: .omitted, time: .standard))" } ?? "")
            }
            SettingsLink { Text("⚙").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                .help("Machines and preferences (⌘,)")
        }
    }
}

/// Whether this Mac can sleep: closing the lid pauses agents working here, never remote ones.
/// Unknown, and hidden, while the local Herdr does not answer.
private struct LidStatus: View {
    let cluster: ClusterStore

    var body: some View {
        if cluster.machines.first(where: { $0.machine.isLocal })?.connection == .online {
            let working = cluster.agents.filter {
                $0.id.machineID == Machine.local.id && !$0.isStale && $0.agent.state == .working
            }.count
            HStack(spacing: 7) {
                PixelFace(mood: working > 0 ? .working : .happy)
                Text(working > 0 ? "\(working) local session\(working == 1 ? "" : "s") running · don't close the lid"
                                 : "it's safe to close the lid")
                    .foregroundStyle(working > 0 ? Theme.amber : Theme.phosphor.opacity(0.85))
                    .lineLimit(1).truncationMode(.tail)
            }
            .help(working > 0 ? "Closing the lid puts this Mac to sleep and pauses the agents working on it. Remote sessions keep going."
                              : "No agent is working on this Mac. Remote sessions keep going while it sleeps.")
            .accessibilityElement(children: .combine)
        }
    }
}

private struct SessionRowView: View {
    /// How far each level of sessions on hold is indented.
    static let indent: CGFloat = 16

    let tree: TreeRow
    /// The group this row is listed in, if any; grouped rows are indented under its header.
    let group: SessionGroup?
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    let showsMachine: Bool
    let model: AppModel
    @Binding var hint: QueueDrop?
    @ViewState<Bool> private var hovering = false
    @ViewState private var height = RowHeight(44)

    private var row: AgentRow { tree.row }
    private var item: QueueItemID { .session(row.id) }
    /// Listed under the session waiting for it: it moves with that session, never on its own.
    private var isNested: Bool { tree.depth > 0 }
    private var leading: CGFloat { group == nil ? 12 : 26 }

    private var accent: Color { row.agent.state == .blocked && !row.isStale ? Theme.amber : Theme.phosphor }

    // Split into parts: one expression this size takes older compilers too long to type-check.
    var body: some View {
        decorated
            .opacity(row.isStale ? 0.6 : 1)
            .measuringHeight(height)
            .contentShape(Rectangle())
            .onTapGesture { model.open(row.id) }
            .onHover { hovering = $0 }
            .help("\(row.agent.program.name) · \(row.project)")
            .queueDraggable(item, model: model, enabled: !isNested)
            .onDrop(of: [.plainText], delegate: QueueDropDelegate(model: model, hint: $hint) { dragged, y in
                drop(of: dragged, at: y)
            })
            .contextMenu { menu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            // Nested sessions move with the session waiting for them, so their own priority is not shown.
            if !isNested {
                Text(String(format: "%02d", row.manualPriority))
                    .font(Theme.mono(10, .semibold))
                    .foregroundStyle(isSelected ? accent : Theme.faint)
                    .padding(.top, 1)
            }
            stateMark
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.workspace).font(Theme.mono(12, .semibold)).lineLimit(1)
                        .foregroundStyle(isSelected ? Theme.text : Theme.text.opacity(0.85))
                    if showsMachine {
                        Text("@\(row.machineName)").font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                }
                Text(row.title).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                whereabouts
            }
            Spacer(minLength: 0)
            if tree.nestedCount > 0 { nestedToggle }
            if (hovering || isSelected) && !isNested { ReorderArrows(item: item, model: model, shortcuts: true) }
        }
    }

    @ViewBuilder private var stateMark: some View {
        if let wait = model.waitState(for: row.id) {
            // On hold: an hourglass replaces the agent's state until the session resumes.
            Image(systemName: wait == .ready ? "hourglass.bottomhalf.filled" : "hourglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(wait == .ready ? Theme.phosphor : Theme.cyan)
                .frame(width: 14)
                .help(wait == .ready ? "On hold; the sessions it waits for have finished" : "On hold, waiting for other sessions")
        } else {
            StateGlyph(state: row.agent.state, stale: row.isStale, background: !model.backgroundCommands(of: row).isEmpty)
        }
    }

    private var decorated: some View {
        let selectionOpacity: Double = isSelected ? 1 : row.agent.state == .blocked && !row.isStale ? 0.6 : 0
        let background: Color = isSelected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear
        return content
            .padding(.leading, leading + CGFloat(tree.depth) * Self.indent).padding(.trailing, 8).padding(.vertical, 7)
            .background(background)
            .overlay(alignment: .leading) {
                if group != nil { Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 18) }
            }
            .overlay {
                if isNested || (tree.nestedCount > 0 && !tree.isCollapsed) { TreeLines(tree: tree, leading: leading) }
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(accent).frame(width: 2).opacity(selectionOpacity)
                    .shadow(color: accent, radius: isSelected ? 4 : 0)
            }
            .dropLine(.top, hint == .before(item))
            // A drop after a session with nested ones lands after all of them, so its line is drawn there.
            .dropLine(.bottom, closesDropLine)
    }

    private var closesDropLine: Bool {
        if tree.closes.contains(where: { hint == .after(.session($0)) }) { return true }
        guard isLast, let group else { return false }
        return hint == .after(.group(group.id))
    }

    private func drop(of dragged: QueueItemID, at y: CGFloat) -> QueueDrop? {
        let upper = y < height.value / 2
        let root = QueueItemID.session(tree.root)
        switch dragged {
        case .session(let id):
            guard id != row.id else { return nil }
            // Over a nested session, anything lands after the whole tree.
            if isNested { return dragged == root ? nil : .after(root) }
            return upper ? .before(item) : .after(item)
        case .group(let draggedGroup):
            // Groups never nest: over a grouped session, a group lands next to that group.
            guard let group else { return isNested ? .after(root) : upper ? .before(item) : .after(item) }
            guard group.id != draggedGroup else { return nil }
            return upper && isFirst ? .before(.group(group.id)) : .after(.group(group.id))
        }
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { model.open(row.id) }
        Button("Rename…") { model.promptRename(row.id) }.disabled(row.isStale)
        Button("New Session in Same Folder…") { model.startNewSession(besides: row.id) }
            .disabled(!model.canStartNewSession(besides: row.id))
        Divider()
        PriorityMenu(item: item, model: model)
        Divider()
        groupMenu
        Divider()
        waitMenu
        Divider()
        CopyPaneMenu(paneID: row.agent.paneID, workspace: row.workspace, machine: model.machine(for: row.id))
        Divider()
        Button("Close Session…") { model.requestClose(row.id) }.disabled(row.isStale)
    }

    @ViewBuilder private var groupMenu: some View {
        Menu("Move to Group") {
            let others = model.groups.filter { $0.id != row.groupID }
            ForEach(others) { other in
                Button(other.name) { model.moveToGroup(row.id, other.id) }
            }
            if !others.isEmpty { Divider() }
            Button("New Group…") { model.promptNewGroup(with: row.id) }
        }
        if row.groupID != nil {
            Button("Remove from Group") { model.moveToGroup(row.id, nil) }
        }
    }

    @ViewBuilder private var waitMenu: some View {
        Menu("Wait For") {
            ForEach(model.rankedRows.filter { $0.id != row.id }) { other in
                Toggle(showsMachine ? "\(other.workspace) @\(other.machineName)" : other.workspace,
                       isOn: Binding { model.relations.isWaiting(row.id, for: other.id) }
                                 set: { model.relations.setWaiting(row.id, for: other.id, $0) })
            }
        }
        if !model.relations.waitingFor(row.id).isEmpty {
            Button("Resume (Stop Waiting)") { model.relations.stopWaiting(row.id) }
        }
        if tree.nestedCount > 0 {
            Button(tree.isCollapsed ? "Show Awaited Sessions" : "Hide Awaited Sessions") {
                model.toggleNestedSessions(of: row.id)
            }
        }
        if isNested, let parent = model.waitForest.parents[row.id], let waiter = model.row(for: parent) {
            Button("Stop \(waiter.workspace) Waiting for This") { model.relations.setWaiting(parent, for: row.id, false) }
        }
    }

    private var accessibilityText: String {
        var text = isNested ? "" : "Priority \(row.manualPriority), "
        text += "\(row.workspace), \(row.title), \(row.agent.state.title)"
        if tree.nestedCount > 0 { text += ", waits for \(tree.nestedCount)" + (tree.isCollapsed ? ", hidden" : "") }
        let background = model.backgroundCommands(of: row)
        if !background.isEmpty { text += ", left running: " + background.map(\.command).joined(separator: ", ") }
        return text
    }

    /// The session's agent, its pull request when it has one, where it works: its folder, or for a
    /// worktree its project, and what its agent left running.
    private var whereabouts: some View {
        let pulls = model.pullRequests(of: row.id)
        let checkout = model.cluster.checkout(machineID: row.id.machineID, workspaceID: row.agent.workspaceID)
        let folder: String? = checkout?.name ?? row.agent.directory.map { ($0 as NSString).lastPathComponent }
        let background = model.backgroundCommands(of: row)
        return HStack(spacing: 9) {
            AgentMark(program: row.agent.program).foregroundStyle(Theme.dim)
            if !pulls.isEmpty { pullsButton(pulls) }
            if let folder { folderLabel(folder, checkout: checkout) }
            BackgroundLabel(commands: background).foregroundStyle(Theme.dim).layoutPriority(-1)
        }
        .font(Theme.mono(9.5))
        .foregroundStyle(Theme.faint)
        .padding(.top, 1)
    }

    private func pullsButton(_ pulls: [SessionResource]) -> some View {
        let label = pulls.count == 1 ? Self.number(of: pulls[0]) : "\(pulls.count) PRs"
        // Lilac once its pull requests landed, as in Resources: the session's work is in.
        let tint = switch model.checksMonitor.outcome(of: pulls) {
        case .landed: Theme.lilac
        case .dropped: Theme.dim
        case nil: Theme.phosphor
        }
        return Button { model.openPullRequests(of: row.id) } label: {
            HStack(spacing: 4) {
                Text("⇄ " + label).foregroundStyle(tint.opacity(0.85))
                ChecksMark(state: model.checksMonitor.state(of: pulls))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(pullsHelp(pulls))
    }

    private func pullsHelp(_ pulls: [SessionResource]) -> String {
        let checks = model.checksMonitor.checks
        func line(_ pull: SessionResource) -> String {
            var text = pull.name
            if let title = pull.title { text += "  " + title }
            if let summary = checks[pull.key]?.summary, !summary.isEmpty { text += "  [" + summary + "]" }
            return text
        }
        let heading = pulls.count == 1 ? "Open in this session's browser:" : "Open these pull requests in this session's browser:"
        return ([heading] + pulls.prefix(10).map(line)).joined(separator: "\n")
    }

    /// Worktrees in their own color: work that lives apart from the main checkout.
    private func folderLabel(_ folder: String, checkout: WorkspaceCheckout?) -> some View {
        let isWorktree = checkout?.isLinkedWorktree == true
        return HStack(spacing: 4) {
            Image(systemName: isWorktree ? "arrow.triangle.branch" : "folder").font(.system(size: 8, weight: .semibold))
            Text(folder).lineLimit(1).truncationMode(.middle)
            if isWorktree { Text("worktree").opacity(0.7) }
        }
        .foregroundStyle(isWorktree ? Theme.cyan.opacity(0.8) : Theme.faint)
        .help(folderHelp(checkout))
    }

    private func folderHelp(_ checkout: WorkspaceCheckout?) -> String {
        guard let checkout else { return row.agent.directory ?? "" }
        let branch = checkout.branch.map { " on branch \($0)" } ?? ""
        return (checkout.isLinkedWorktree ? "A worktree of \(checkout.repository)\(branch)" : "\(checkout.repository)\(branch)")
            + "\n" + checkout.path
    }

    /// `#2175` from `theam/tam-os#2175`, `!31` from a GitLab merge request.
    private static func number(of resource: SessionResource) -> String {
        guard let mark = resource.name.lastIndex(where: { $0 == "#" || $0 == "!" }) else { return resource.name }
        return String(resource.name[mark...])
    }

    /// Shows or hides the sessions nested under this one. Amber while a hidden one needs you.
    private var nestedToggle: some View {
        Button { withAnimation(.snappy(duration: 0.18)) { model.toggleNestedSessions(of: row.id) } } label: {
            Text("\(tree.isCollapsed ? "▸" : "▾")\(tree.nestedCount)")
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(tree.hiddenBlocked > 0 ? Theme.amber : tree.hidesSelection ? Theme.phosphor : Theme.dim)
                .padding(.top, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tree.isCollapsed ? "Show the sessions this one waits for" : "Hide the sessions this one waits for")
    }
}

/// The lines tying sessions on hold to the sessions they wait for: ├ and └ in the console's line color.
private struct TreeLines: View {
    let tree: TreeRow
    /// Where the row's level-0 content starts.
    let leading: CGFloat
    /// Below the middle of the first line of text, and below the parent's number or state glyph.
    private let elbow: CGFloat = 14, parentBottom: CGFloat = 22

    var body: some View {
        // Read on the main actor: Canvas draws from a nonisolated closure.
        let indent = SessionRowView.indent
        return Canvas { context, size in
            // Each level's line runs under the middle of its parent's first column: the priority
            // number at the top of the tree, the state glyph below it.
            func x(_ level: Int) -> CGFloat {
                leading + CGFloat(level - 1) * indent + (level == 1 ? 6 : 7)
            }
            var path = Path()
            for (index, passes) in tree.guides.enumerated() where passes {
                path.addRect(CGRect(x: x(index + 1), y: 0, width: 1, height: size.height))
            }
            if tree.depth > 0 {
                let own = x(tree.depth)
                path.addRect(CGRect(x: own, y: 0, width: 1, height: tree.isLastSibling ? elbow + 1 : size.height))
                path.addRect(CGRect(x: own, y: elbow, width: 7, height: 1))
            }
            if tree.nestedCount > 0 && !tree.isCollapsed {
                path.addRect(CGRect(x: x(tree.depth + 1), y: parentBottom, width: 1, height: max(0, size.height - parentBottom)))
            }
            context.fill(path, with: .color(Theme.faint.opacity(0.6)))
        }
        .allowsHitTesting(false)
    }
}

/// A group's header: click to collapse or expand, drag to reorder, drop sessions on it to add them.
private struct GroupHeaderView: View {
    /// Fixed, so the controls shown on hover never change the row's height.
    private static let contentHeight: CGFloat = 26

    let group: QueueGroupRow
    let isExpanded: Bool
    let containsSelection: Bool
    let model: AppModel
    @Binding var hint: QueueDrop?
    @ViewState<Bool> private var hovering = false
    @ViewState private var height = RowHeight(32)

    private var item: QueueItemID { .group(group.id) }

    var body: some View {
        let live = group.rows.filter { !$0.isStale }
        let blocked = live.filter { $0.agent.state == .blocked }.count
        let working = live.filter { $0.agent.state == .working }.count
        let receiving = hint == .into(group: group.id)
        let count = group.rows.count + model.shells(in: group.group).count
        HStack(spacing: 7) {
            Text(isExpanded ? "▾" : "▸").font(Theme.mono(11, .bold))
                .foregroundStyle(Theme.phosphor.opacity(0.8)).frame(width: 14)
            Text(group.group.name.uppercased()).font(Theme.mono(10.5, .bold)).tracking(1.2).lineLimit(1)
                .foregroundStyle(containsSelection && !isExpanded ? Theme.phosphor : Theme.text.opacity(0.85))
            Text("\(count)").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            Spacer(minLength: 4)
            if blocked > 0 {
                Text("\(blocked) need you").font(Theme.mono(9.5, .semibold)).foregroundStyle(Theme.amber).lineLimit(1)
            } else if working > 0 {
                Text("\(working) working").font(Theme.mono(9.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            if hovering {
                Button { model.startNewSession(in: group.group) } label: {
                    Text("+").font(Theme.mono(13, .bold)).frame(width: 18, height: Self.contentHeight).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.onlineMachines.isEmpty ? Theme.faint.opacity(0.5) : Theme.phosphor)
                .disabled(model.onlineMachines.isEmpty)
                .help("New session in \(group.group.name)")
                ReorderArrows(item: item, model: model, shortcuts: false)
            }
        }
        .frame(height: Self.contentHeight)
        .padding(.leading, 12).padding(.trailing, 8).padding(.top, 5).padding(.bottom, 1)
        .background(receiving ? Theme.phosphor.opacity(0.12) : hovering ? Theme.raised.opacity(0.5) : .clear)
        .overlay { if receiving { Rectangle().strokeBorder(Theme.phosphor.opacity(0.6), lineWidth: 1) } }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.amber).frame(width: 2).opacity(blocked > 0 ? 0.6 : 0) }
        .dropLine(.top, hint == .before(item))
        .dropLine(.bottom, hint == .after(item) && !isExpanded)
        .measuringHeight(height)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { model.toggleCollapsed(group.group) } }
        .onHover { hovering = $0 }
        .help("\(isExpanded ? "Collapse" : "Expand") \(group.group.name). Drag to reorder; drop sessions here to add them.")
        .queueDraggable(item, model: model)
        .onDrop(of: [.plainText], delegate: QueueDropDelegate(model: model, hint: $hint) { dragged, y in
            if dragged == item { return nil }
            if y < height.value * 0.4 { return .before(item) }
            if case .session = dragged { return .into(group: group.id) }
            return .after(item)
        })
        .contextMenu {
            Button("New Session in Group…") { model.startNewSession(in: group.group) }
                .disabled(model.onlineMachines.isEmpty)
            Divider()
            Button("Rename…") { model.promptRename(group.group) }
            Button(group.group.isCollapsed ? "Expand" : "Collapse") { model.toggleCollapsed(group.group) }
            Divider()
            PriorityMenu(item: item, model: model)
            Divider()
            Button("Ungroup") { model.ungroup(group.group) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Group \(group.group.name), \(count) sessions\(blocked > 0 ? ", \(blocked) need you" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// Stands in for an expanded group's sessions until the first one is dropped in.
private struct EmptyGroupView: View {
    let group: SessionGroup
    let model: AppModel
    @Binding var hint: QueueDrop?

    var body: some View {
        Text("drop sessions here").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 30).padding(.vertical, 8)
            .background(hint == .into(group: group.id) ? Theme.phosphor.opacity(0.12) : .clear)
            .dropLine(.bottom, hint == .after(.group(group.id)))
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], delegate: QueueDropDelegate(model: model, hint: $hint) { dragged, _ in
                if case .session = dragged { return .into(group: group.id) }
                return dragged == .group(group.id) ? nil : .after(.group(group.id))
            })
    }
}

/// The space after the last row: dropping here moves a session or group to the end of the queue.
private struct QueueEndView: View {
    let model: AppModel
    @Binding var hint: QueueDrop?

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, minHeight: 28)
            .dropLine(.top, hint == .end)
            .contentShape(Rectangle())
            .onDrop(of: [.plainText], delegate: QueueDropDelegate(model: model, hint: $hint) { _, _ in .end })
    }
}

private struct ReorderArrows: View {
    let item: QueueItemID
    let model: AppModel
    /// Whether to mention ⌥⌘↑/↓, which act on the selected session.
    let shortcuts: Bool

    var body: some View {
        VStack(spacing: 0) {
            arrow("▲", .up, help: shortcuts ? "Raise priority (⌥⌘↑)" : "Raise priority")
            arrow("▼", .down, help: shortcuts ? "Lower priority (⌥⌘↓)" : "Lower priority")
        }
    }

    private func arrow(_ glyph: String, _ direction: SessionOrderStore.Move, help: String) -> some View {
        Button { withAnimation(.snappy(duration: 0.18)) { model.move(item, direction) } } label: {
            Text(glyph).font(.system(size: 7)).frame(width: 18, height: 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.canMove(item, direction) ? Theme.phosphor : Theme.faint.opacity(0.5))
        .disabled(!model.canMove(item, direction))
        .help(help)
    }
}

/// Priority commands shared by session and group context menus.
private struct PriorityMenu: View {
    let item: QueueItemID
    let model: AppModel

    var body: some View {
        Button("Move to Top") { model.move(item, .first) }.disabled(!model.canMove(item, .first))
        Button("Raise Priority") { model.move(item, .up) }.disabled(!model.canMove(item, .up))
        Button("Lower Priority") { model.move(item, .down) }.disabled(!model.canMove(item, .down))
        Button("Move to Bottom") { model.move(item, .last) }.disabled(!model.canMove(item, .last))
    }
}

/// Drop handling for one queue row: where the pointer sits within the row picks the landing spot.
private struct QueueDropDelegate: DropDelegate {
    let model: AppModel
    @Binding var hint: QueueDrop?
    /// The landing spot for the dragged item at a height within the row, or nil to refuse it.
    let resolve: (QueueItemID, CGFloat) -> QueueDrop?

    func validateDrop(info: DropInfo) -> Bool { model.dragging != nil }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: hint == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        // Rows overlap at their edges: only clear the hint this row set.
        if let item = model.dragging, hint == resolve(item, info.location.y) { hint = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { hint = nil }
        guard let item = model.dragging, let drop = resolve(item, info.location.y),
              let provider = info.itemProviders(for: [.plainText]).first else {
            model.dragging = nil
            return false
        }
        let model = model
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            let token = (text as? NSString).map(String.init)
            Task { @MainActor in
                // Only the queue drag that set `dragging` carries its token. Any other text
                // dropped here finds it left over from a drag that ended outside the queue.
                let isQueueDrag = token == model.dragToken && model.dragging == item
                model.dragging = nil
                if isQueueDrag { withAnimation(.snappy(duration: 0.2)) { model.place(item, drop) } }
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        guard let item = model.dragging else { return }
        hint = resolve(item, info.location.y)
    }
}

private struct ShellRowView: View {
    let shell: ShellRow
    /// Grouped shells are indented under their group's header, like its sessions.
    let isGrouped: Bool
    let isSelected: Bool
    let showsMachine: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("$").font(Theme.mono(11, .bold)).foregroundStyle(isSelected ? Theme.phosphor : Theme.faint)
                .frame(width: 30, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(shell.pane.workspaceName).font(Theme.mono(11.5, .medium)).foregroundStyle(Theme.text.opacity(0.8)).lineLimit(1)
                Text(showsMachine ? "shell @\(shell.machine.name)" : "shell")
                    .font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, isGrouped ? 26 : 12).padding(.trailing, 8).padding(.vertical, 5)
        .background(isSelected ? Theme.raised : .clear)
        .overlay(alignment: .leading) {
            if isGrouped { Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 18) }
        }
        .overlay(alignment: .leading) { Rectangle().fill(Theme.phosphor).frame(width: 2).opacity(isSelected ? 1 : 0) }
        .opacity(shell.isStale ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Lazy stacks need identities unique across the whole list. A shell and the agent Herdr later
/// detects in it share an `Agent.ID`, and reusing it let the agent's row keep drawing the shell.
private struct ShellListID: Hashable {
    let id: Agent.ID
}

private extension ShellRow {
    var listID: ShellListID { ShellListID(id: id) }
}

private extension View {
    /// Starts an in-app drag of a queue item. The model carries what moves; the pasteboard
    /// carries a token for this drag, so drops can tell it from any other text.
    @ViewBuilder func queueDraggable(_ item: QueueItemID, model: AppModel, enabled: Bool = true) -> some View {
        if enabled {
            onDrag {
                let token = "shepherdr-queue-item:\(UUID().uuidString)"
                model.dragging = item
                model.dragToken = token
                return NSItemProvider(object: token as NSString)
            }
        } else {
            self
        }
    }

    /// The phosphor line that marks where a dragged item will land.
    func dropLine(_ edge: VerticalEdge, _ shown: Bool) -> some View {
        overlay(alignment: edge == .top ? .top : .bottom) {
            if shown {
                Rectangle().fill(Theme.phosphor).frame(height: 2).shadow(color: Theme.phosphor, radius: 3)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Keeps `height` equal to the view's height, so drop targets can split rows into halves.
    func measuringHeight(_ height: RowHeight) -> some View {
        background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { height.value = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, new in height.value = new }
            }
        }
    }
}

/// A row's measured height, read only when something is dropped on it. A plain reference rather
/// than view state, so measuring never invalidates the view and can never feed a layout loop.
@MainActor final class RowHeight {
    var value: CGFloat
    init(_ value: CGFloat) { self.value = value }
}
