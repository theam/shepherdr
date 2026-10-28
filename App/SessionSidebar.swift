import SwiftUI
import ShepherdrCore

/// The priority queue: every agent session in the user's order, with reordering controls.
struct SessionSidebar: View {
    @AppStorage("refreshSeconds") private var refreshSeconds = 5
    @Bindable var model: AppModel
    @ViewState<Bool> private var showShells = true
    /// Where a drag in progress would land, drawn as a line or a highlighted group.
    @ViewState<QueueDrop?> private var dropHint: QueueDrop?

    private var cluster: ClusterStore { model.cluster }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SwitcherButton(model: model).padding(.horizontal, 12).padding(.bottom, 10)
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
                    Text("SHEPHERDR").font(Theme.mono(13, .heavy)).tracking(2.5).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Overview (⌘0)")
            Button { model.startNewSession() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(ConsoleButtonStyle())
                .disabled(model.onlineMachines.isEmpty)
                .help("New session (⌘N)")
                .accessibilityLabel("New session")
        }
        .padding(.horizontal, 14).padding(.top, 34).padding(.bottom, 12)
    }

    private var queue: some View {
        // Sessions on hold list the sessions they wait for under them, instead of in their own place.
        let forest = model.waitForest
        let items = model.queue
        return ScrollViewReader { proxy in
            ScrollView {
                // A plain stack: the queue is short, and a lazy stack whose rows measure themselves
                // could loop on layout and freeze the window.
                VStack(alignment: .leading, spacing: 0) {
                    queueHeader
                    ForEach(model.slots(of: items, forest: forest)) { slot in
                        switch slot {
                        case .item(.session(let row)):
                            if !forest.isNested(row.id) {
                                ForEach(forest.rows(from: row)) { tree in sessionRow(tree, in: nil, isFirst: false, isLast: false) }
                            }
                        case .item(.group(let group)):
                            groupSection(group, forest: forest)
                        case .project(let run):
                            ProjectHeaderView(run: run, group: nil, isFirst: false, isLast: false, model: model, hint: $dropHint)
                            if !run.isCollapsed {
                                ForEach(run.rows.flatMap(forest.rows(from:))) { tree in
                                    sessionRow(tree, in: nil, run: run, isFirst: false, isLast: false)
                                }
                            }
                        }
                    }
                    if items.isEmpty { emptyQueue }
                    QueueEndView(model: model, hint: $dropHint)
                    shellsSection
                }
            }
            // The session on screen stays in sight: opened from Compass, a notification or ⌘1…⌘9.
            .onAppear { reveal(model.selectedID, with: proxy, animated: false) }
            .onChange(of: model.selectedID) { _, id in reveal(id, with: proxy, animated: true) }
        }
    }

    /// Scrolls the queue just enough to show a session, or the header of the collapsed group hiding it.
    private func reveal(_ id: Agent.ID?, with proxy: ScrollViewProxy, animated: Bool) {
        guard let id else { return }
        let target: SidebarAnchor
        if let group = model.groups.first(where: { $0.members.contains(id) }), group.isCollapsed {
            target = .group(group.id)
        } else {
            target = model.row(for: id) == nil ? .shell(id) : .session(id)
        }
        // Once the row is laid out, as when the sidebar just appeared.
        DispatchQueue.main.async {
            if animated { withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(target) } } else { proxy.scrollTo(target) }
        }
    }

    @ViewBuilder private func groupSection(_ group: QueueGroupRow, forest: WaitForest) -> some View {
        let expanded = !group.group.isCollapsed
        GroupHeaderView(group: group, isExpanded: expanded,
                        containsSelection: model.selectedID.map(group.group.members.contains) == true,
                        model: model, hint: $dropHint)
            .id(SidebarAnchor.group(group.group.id))
        if expanded {
            let slots = model.slots(of: group, forest: forest)
            let listed = Self.listing(slots, forest: forest)
            // A group dragged over the first or last of these lands before or after this group; shells don't count.
            let edges = listed.filter { if case .shell = $0 { false } else { true } }
            ForEach(listed) { place in
                switch place {
                case .tree(let tree, let run):
                    sessionRow(tree, in: group, run: run, isFirst: place.id == edges.first?.id, isLast: place.id == edges.last?.id)
                case .heading(let run):
                    ProjectHeaderView(run: run, group: group.group, isFirst: place.id == edges.first?.id,
                                      isLast: place.id == edges.last?.id, model: model, hint: $dropHint)
                case .shell(let shell):
                    shellRow(shell, grouped: true)
                }
            }
            if slots.isEmpty {
                EmptyGroupView(group: group.group, model: model, hint: $dropHint)
            }
        }
    }

    /// What an expanded group lists, row by row: its sessions with those nested under them, its
    /// projects' headings followed by their sessions, and its shells.
    private static func listing(_ slots: [MemberSlot], forest: WaitForest) -> [GroupPlace] {
        slots.flatMap { slot -> [GroupPlace] in
            switch slot {
            case .member(.session(let row)):
                return forest.isNested(row.id) ? [] : forest.rows(from: row).map { .tree($0, nil) }
            case .member(.shell(let shell)):
                return [.shell(shell)]
            case .project(let run):
                let rows = run.isCollapsed ? [] : run.rows.flatMap(forest.rows(from:)).map { GroupPlace.tree($0, run) }
                return [.heading(run)] + rows
            }
        }
    }

    private var queueHeader: some View {
        let gathers = Binding { model.order.gathersProjects } set: { model.order.gathersProjects = $0 }
        return HStack(spacing: 10) {
            ConsoleHeader(title: "Sessions", trailing: nil)
            Menu {
                Toggle("Gather Sessions by Project", isOn: gathers)
                Button("New Group…") { model.promptNewGroup() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(Theme.dim)
            .help("Organize sessions")
            .accessibilityLabel("Organize sessions")
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
    }

    private func sessionRow(_ tree: TreeRow, in group: QueueGroupRow?, run: ProjectRun? = nil, isFirst: Bool, isLast: Bool) -> some View {
        SessionRowView(tree: tree, group: group?.group, run: run, isFirst: isFirst, isLast: isLast,
                       isSelected: model.selectedID == tree.id, showsMachine: model.showsMachineNames,
                       model: model, hint: $dropHint)
            .id(SidebarAnchor.session(tree.id))
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
            .help("Sessions without an agent yet")
            if showShells {
                ForEach(shells, id: \.listID) { shell in shellRow(shell, grouped: false) }
            }
        }
    }

    private func shellRow(_ shell: ShellRow, grouped: Bool) -> some View {
        let checkout = model.cluster.checkout(machineID: shell.machine.id, workspaceID: shell.pane.workspaceID)
        let folder = shell.pane.directory.map { ($0 as NSString).lastPathComponent }
        return ShellRowView(shell: shell, isGrouped: grouped, isSelected: model.selectedID == shell.id,
                     showsMachine: model.showsMachineNames,
                     place: checkout?.branch ?? checkout?.name ?? folder) { model.open(shell.id) }
            .id(SidebarAnchor.shell(shell.id))
            .contextMenu {
                Button("Open") { model.open(shell.id) }
                Button("Rename…") { model.promptRename(shell.id) }.disabled(shell.isStale)
                Button("New Session in Same Folder…") { model.startNewSession(besides: shell.id) }
                    .disabled(!model.canStartNewSession(besides: shell.id))
                Button("Show Folder in Finder") { model.showFolder(of: shell.id) }
                    .disabled(shell.id.machineID != Machine.local.id)
                if grouped {
                    Divider()
                    Button("Remove from Group") { model.moveToGroup(shell.id, nil) }
                }
                Divider()
                Button("Close Shell…") { model.requestClose(shell.id) }.disabled(shell.isStale)
            }
    }

    @ViewBuilder private var emptyQueue: some View {
        let text: String = if cluster.isRefreshing && cluster.lastRefresh == nil { "Connecting…" }
            else if cluster.onlineCount == 0 { "Can't reach your machines.\nCheck Settings → Machines." }
            else { "No sessions yet.\nCreate one with +." }
        Text(text).font(Theme.mono(11)).foregroundStyle(Theme.faint)
            .padding(.horizontal, 14).padding(.vertical, 12)
    }

    /// One row: a notice only when something needs doing, then the lid face, the coffee cup and settings.
    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            connectionNotice
            Spacer(minLength: 4)
            LidStatus(cluster: cluster, keepAwake: model.keepAwake)
            CoffeeButton(keepAwake: model.keepAwake)
            SettingsLink { Image(systemName: "gearshape").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(Theme.dim)
                .help("Machines and preferences (⌘,)")
                .accessibilityLabel("Settings")
        }
        .font(Theme.mono(10))
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    /// Shown only when a machine is down or the refresh is paused; silent while everything is fine.
    @ViewBuilder private var connectionNotice: some View {
        let enabled = cluster.machines.filter(\.machine.isEnabled)
        let offline = max(0, enabled.count - cluster.onlineCount)
        let connecting = cluster.isRefreshing && cluster.lastRefresh == nil
        let lastCheck = cluster.lastRefresh.map { "Checked \($0.formatted(date: .omitted, time: .standard))" } ?? ""
        if !enabled.isEmpty && offline > 0 && !connecting {
            HStack(spacing: 6) {
                ConnectionDot(state: .unreachable)
                Text(cluster.onlineCount == 0 ? "Not connected" : "\(offline) machine\(offline == 1 ? "" : "s") offline")
                    .lineLimit(1).truncationMode(.tail)
            }
            .help(lastCheck)
        } else if refreshSeconds == 0 {
            Text("Refresh paused").foregroundStyle(Theme.faint).lineLimit(1)
                .help("Sessions are not refreshed automatically (Settings). Refresh Sessions (⌘R) updates them." + (lastCheck.isEmpty ? "" : "\n" + lastCheck))
        }
    }
}

/// Whether this Mac can sleep: closing the lid pauses agents working here, never remote ones.
/// Unknown, and hidden, while the local Herdr does not answer.
private struct LidStatus: View {
    let cluster: ClusterStore
    let keepAwake: KeepAwake

    var body: some View {
        if cluster.machines.first(where: { $0.machine.isLocal })?.connection == .online {
            let working = cluster.agents.filter {
                $0.id.machineID == Machine.local.id && !$0.isStale && $0.agent.state == .working
            }.count
            // Words only for a warning: the calm cases are the face and the cup.
            let warning: String? = keepAwake.isOn ? (keepAwake.onBattery ? "Lid still sleeps it" : nil)
                : working > 0 ? "Keep the lid open" : nil
            HStack(spacing: 7) {
                if let warning {
                    Text(warning).foregroundStyle(Theme.amber).lineLimit(1).truncationMode(.tail)
                }
                PixelFace(mood: working > 0 ? .working : .happy, caffeinated: keepAwake.isOn)
            }
            .help(keepAwake.isOn && keepAwake.onBattery ? "This Mac is on battery: it won't sleep by itself, but closing the lid still puts it to sleep and pauses its agents. Plug it in to keep them going."
                  : keepAwake.isOn ? "Coffee is on: this Mac won't sleep while it's plugged in. Remote sessions keep going either way."
                  : working > 0 ? "Closing the lid puts this Mac to sleep and pauses the agents working on it. Remote sessions keep going."
                  : "No agent is working on this Mac. Remote sessions keep going while it sleeps.")
            .accessibilityElement(children: .combine)
        }
    }
}

/// The coffee cup: keeps this Mac awake until you click it again or quit. The menu also keeps the
/// screen on, which agents don't need, so it starts off.
private struct CoffeeButton: View {
    @Bindable var keepAwake: KeepAwake

    var body: some View {
        Button { keepAwake.toggle() } label: {
            PixelCup(isOn: keepAwake.isOn)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Toggle("Keep the Screen On Too", isOn: $keepAwake.keepsScreenOn)
        }
        .help(keepAwake.isOn ? "Coffee is on: this Mac won't sleep. Click to let it sleep again."
                             : "Keep this Mac awake so agents keep working. Right-click to keep the screen on too.")
        .accessibilityLabel("Keep this Mac awake")
        .accessibilityValue(keepAwake.isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// One row of an expanded group.
private enum GroupPlace: Identifiable {
    case tree(TreeRow, ProjectRun?)
    case heading(ProjectRun)
    case shell(ShellRow)

    enum ID: Hashable { case tree(Agent.ID), heading(ProjectRunID), shell(Agent.ID) }

    var id: ID {
        switch self {
        case .tree(let tree, _): .tree(tree.id)
        case .heading(let run): .heading(run.id)
        case .shell(let shell): .shell(shell.id)
        }
    }
}

private struct SessionRowView: View {
    /// How far each level of sessions on hold is indented.
    static let indent: CGFloat = 16
    /// How far a project's sessions are indented under its heading.
    static let projectIndent: CGFloat = 14

    let tree: TreeRow
    /// The group this row is listed in, if any; grouped rows are indented under its header.
    let group: SessionGroup?
    /// The project heading this row is listed under, if any.
    let run: ProjectRun?
    let isFirst: Bool
    let isLast: Bool
    let isSelected: Bool
    let showsMachine: Bool
    let model: AppModel
    @Binding var hint: QueueDrop?
    @ViewState<Bool> private var hovering = false
    /// The session's details, the same panel as the ⓘ in its header, after the pointer rests on the row.
    @ViewState<Bool> private var showsDetails = false
    @ViewState private var height = RowHeight(36)

    private var row: AgentRow { tree.row }
    private var item: QueueItemID { .session(row.id) }
    /// Listed under the session waiting for it: it moves with that session, never on its own.
    private var isNested: Bool { tree.depth > 0 }
    /// Where the list this row is in starts: the queue's edge, or its group's indent.
    private var listLeading: CGFloat { group == nil ? 12 : 26 }
    private var leading: CGFloat { listLeading + (run == nil ? 0 : Self.projectIndent) }
    /// A project's first session: a drop before it is drawn above the project's heading.
    private var opensProject: Bool { !isNested && run?.rows.first?.id == row.id }

    private var accent: Color { model.status(of: row) == .needsYou ? Theme.amber : Theme.phosphor }

    // Split into parts: one expression this size takes older compilers too long to type-check.
    var body: some View {
        decorated
            .opacity(row.isStale ? 0.6 : 1)
            .measuringHeight(height)
            .contentShape(Rectangle())
            .onTapGesture { model.open(row.id) }
            .onHover { hovering = $0 }
            .task(id: hovering) {
                guard hovering else { showsDetails = false; return }
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { showsDetails = true }
            }
            .popover(isPresented: $showsDetails, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) { detailsPanel }
            .queueDraggable(item, model: model, enabled: !isNested)
            .onDrop(of: [.plainText], delegate: QueueDropDelegate(model: model, hint: $hint) { dragged, y in
                drop(of: dragged, at: y)
            })
            .contextMenu { menu }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    /// One line: state, name, machine when there are several, mail. Everything else is in the tooltip
    /// and in the session's own view.
    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            line
            if hovering { summary }
        }
    }

    /// On hover, under the name: what the session is doing and, below it, the branch it works on.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !row.title.isEmpty {
                Text(row.title).font(Theme.mono(10.5)).foregroundStyle(Theme.text.opacity(0.7))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if let place = placeName {
                Label { Text(place).lineLimit(1).truncationMode(.middle) } icon: {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .semibold))
                }
                .font(Theme.mono(10)).foregroundStyle(Theme.dim)
            }
        }
        .padding(.leading, 44).padding(.bottom, 2)
    }

    private var line: some View {
        HStack(alignment: .center, spacing: 8) {
            stateMark
            AgentMark(program: row.agent.program, style: .glyph)
            Text(row.workspace).font(Theme.mono(12, .semibold)).lineLimit(1)
                .foregroundStyle(isSelected ? Theme.text : Theme.text.opacity(0.85))
            if showsMachine {
                Text("@\(row.machineName)").font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            MailMark(session: row.id, courier: model.courier)
            checksFailedMark
            Spacer(minLength: 0)
            if tree.nestedCount > 0 { nestedToggle }
            if (hovering || isSelected) && !isNested { ReorderArrows(item: item, model: model, shortcuts: true) }
        }
        // As tall as the reorder arrows, so showing them never changes the row's height.
        .frame(minHeight: 26)
    }

    /// Where the session works, shown on hover only: its branch, else its repository or folder.
    private var placeName: String? {
        let checkout = model.cluster.checkout(machineID: row.id.machineID, workspaceID: row.agent.workspaceID)
        let folder = row.agent.directory.map { ($0 as NSString).lastPathComponent }
        let place = checkout?.branch ?? checkout?.name ?? folder
        return place?.isEmpty == false ? place : nil
    }

    /// The one thing worth a glance from the list: CI failed on the session's pull request.
    @ViewBuilder private var checksFailedMark: some View {
        if model.checksMonitor.state(of: model.pullRequests(of: row.id)) == .failed {
            ChecksMark(state: .failed).font(Theme.mono(10, .bold)).help("Checks failed on its pull request")
        }
    }

    private var stateMark: some View {
        StateGlyph(status: model.status(of: row), background: !model.backgroundCommands(of: row).isEmpty)
    }

    private var decorated: some View {
        let selectionOpacity: Double = isSelected ? 1 : model.status(of: row) == .needsYou ? 0.6 : 0
        let background: Color = isSelected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear
        return content
            .padding(.leading, leading + CGFloat(tree.depth) * Self.indent).padding(.trailing, 8).padding(.vertical, 5)
            .background(background)
            .overlay(alignment: .leading) {
                if group != nil { Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 18) }
            }
            .overlay(alignment: .leading) {
                if run != nil { ProjectRule(leading: listLeading) }
            }
            .overlay {
                if isNested || (tree.nestedCount > 0 && !tree.isCollapsed) { TreeLines(tree: tree, leading: leading) }
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(accent).frame(width: 2).opacity(selectionOpacity)
                    .shadow(color: accent, radius: isSelected ? 4 : 0)
            }
            .dropLine(.top, hint == .before(item) && !opensProject)
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
        // Only the project's own sessions go among its sessions. Anything else lands before or
        // after the whole project, and a group next to the group the project is in.
        if let run, let first = run.rows.first?.id, let last = run.rows.last?.id, !isSameProject(dragged) {
            if case .group(let draggedGroup) = dragged, let group {
                return group.id == draggedGroup ? nil : .after(.group(group.id))
            }
            let target = upper && row.id == first && !isNested ? first : last
            guard dragged != .session(target) else { return nil }
            return target == first ? .before(.session(first)) : .after(.session(last))
        }
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

    private func isSameProject(_ dragged: QueueItemID) -> Bool {
        guard case .session(let id) = dragged, let run, let other = model.row(for: id) else { return false }
        return model.project(of: other) == run.id.project
    }

    @ViewBuilder private var menu: some View {
        Button("Open") { model.open(row.id) }
        let pulls = model.pullRequests(of: row.id)
        Button(pulls.count == 1 ? "Open Pull Request" : "Open Pull Requests") { model.openPullRequests(of: row.id) }
            .disabled(pulls.isEmpty)
        Button("Rename…") { model.promptRename(row.id) }.disabled(row.isStale)
        Button("New Session in Same Folder…") { model.startNewSession(besides: row.id) }
            .disabled(!model.canStartNewSession(besides: row.id))
        Button("Show Folder in Finder") { model.showFolder(of: row.id) }
            .disabled(row.id.machineID != Machine.local.id)
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
        Button("Wait For…") { model.pickWaits(for: row.id) }
            .disabled(model.cluster.agents.count < 2)
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
        text += "\(row.workspace), \(row.title), \(model.status(of: row).label)"
        if tree.nestedCount > 0 { text += ", waits for \(tree.nestedCount)" + (tree.isCollapsed ? ", hidden" : "") }
        let background = model.backgroundCommands(of: row)
        if !background.isEmpty { text += ", left running: " + background.map(\.command).joined(separator: ", ") }
        return text
    }

    @ViewBuilder private var detailsPanel: some View {
        if let context = model.context(for: row.id) {
            SessionDetails(context: context, cluster: model.cluster,
                           checkout: model.cluster.checkout(machineID: row.id.machineID, workspaceID: row.agent.workspaceID),
                           background: model.backgroundCommands(of: row))
                .frame(width: 320)
        }
    }

    /// Shows or hides the sessions nested under this one. Amber while a hidden one needs you.
    private var nestedToggle: some View {
        Button { withAnimation(.snappy(duration: 0.18)) { model.toggleNestedSessions(of: row.id) } } label: {
            Text("\(tree.isCollapsed ? "▸" : "▾")\(tree.nestedCount)")
                .font(Theme.mono(10, .semibold))
                .foregroundStyle(tree.hiddenBlocked > 0 ? Theme.amber : tree.hidesSelection ? Theme.phosphor : Theme.dim)
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
    /// The middle of the row's line, and below the parent's state glyph.
    private let elbow: CGFloat = 18, parentBottom: CGFloat = 27

    var body: some View {
        // Read on the main actor: Canvas draws from a nonisolated closure.
        let indent = SessionRowView.indent
        return Canvas { context, size in
            // Each level's line runs under the middle of its parent's state glyph.
            func x(_ level: Int) -> CGFloat {
                leading + CGFloat(level - 1) * indent + 7
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
        let blocked = live.filter { model.status(of: $0) == .needsYou }.count
        let working = live.filter { model.status(of: $0) == .working }.count
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

/// A project's heading: its sessions in this list follow it, indented. Lighter than a group's
/// header, which it can sit in. Click to collapse or expand; ▲▼ move the whole project.
private struct ProjectHeaderView: View {
    /// Fixed, so the controls shown on hover never change the row's height.
    private static let contentHeight: CGFloat = 20

    let run: ProjectRun
    /// The group the project is listed in, if any.
    let group: SessionGroup?
    /// Whether the heading is the first or last place of its group, for drops next to the group.
    let isFirst: Bool
    let isLast: Bool
    let model: AppModel
    @Binding var hint: QueueDrop?
    @ViewState<Bool> private var hovering = false
    @ViewState private var height = RowHeight(24)

    private var first: Agent.ID? { run.rows.first?.id }
    private var last: Agent.ID? { run.rows.last?.id }

    var body: some View {
        let live = run.rows.filter { !$0.isStale }
        let blocked = live.filter { model.status(of: $0) == .needsYou }.count
        let working = live.filter { model.status(of: $0) == .working }.count
        let containsSelection = model.selectedID.map { id in run.rows.contains { $0.id == id } } == true
        HStack(spacing: 6) {
            Text(run.isCollapsed ? "▸" : "▾").font(Theme.mono(10, .bold))
                .foregroundStyle(Theme.dim).frame(width: 12)
            Image(systemName: "folder").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.dim)
            Text(run.id.project).font(Theme.mono(11, .medium)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(containsSelection && run.isCollapsed ? Theme.phosphor : Theme.text.opacity(0.7))
            Text("\(run.rows.count)").font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
            Spacer(minLength: 4)
            if blocked > 0 {
                Text("\(blocked) need you").font(Theme.mono(9.5, .semibold)).foregroundStyle(Theme.amber).lineLimit(1)
            } else if working > 0 {
                Text("\(working) working").font(Theme.mono(9.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            if hovering { ReorderArrows(project: run.id, model: model) }
        }
        .frame(height: Self.contentHeight)
        .padding(.leading, group == nil ? 12 : 26).padding(.trailing, 8).padding(.top, 3).padding(.bottom, 1)
        .background(hovering ? Theme.raised.opacity(0.5) : .clear)
        .overlay(alignment: .leading) {
            if group != nil { Rectangle().fill(Theme.line).frame(width: 1).padding(.leading, 18) }
        }
        // While collapsed, its sessions can't show they need you.
        .overlay(alignment: .leading) { Rectangle().fill(Theme.amber).frame(width: 2).opacity(blocked > 0 && run.isCollapsed ? 0.6 : 0) }
        .dropLine(.top, first.map { hint == .before(.session($0)) } == true)
        .dropLine(.bottom, run.isCollapsed && closesDropLine)
        .measuringHeight(height)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.18)) { model.toggleCollapsed(run.id) } }
        .onHover { hovering = $0 }
        .help("\(run.isCollapsed ? "Expand" : "Collapse") \(run.id.project): \(run.rows.count) sessions of this project\(group.map { " in \($0.name)" } ?? "").")
        .onDrop(of: [.plainText], delegate: QueueDropDelegate(model: model, hint: $hint) { dragged, y in drop(of: dragged, at: y) })
        .contextMenu {
            Button(run.isCollapsed ? "Expand" : "Collapse") { model.toggleCollapsed(run.id) }
            Divider()
            PriorityMenu(project: run.id, model: model)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(run.id.project), \(run.rows.count) sessions\(blocked > 0 ? ", \(blocked) need you" : "")")
        .accessibilityAddTraits(.isButton)
    }

    /// A collapsed heading stands for its sessions: a drop after the last one is drawn below it.
    private var closesDropLine: Bool {
        if let last, hint == .after(.session(last)) { return true }
        guard isLast, let group else { return false }
        return hint == .after(.group(group.id))
    }

    private func drop(of dragged: QueueItemID, at y: CGFloat) -> QueueDrop? {
        guard let first, let last else { return nil }
        let upper = y < height.value / 2
        // Groups never nest: over a grouped project, a group lands next to that group.
        if case .group(let draggedGroup) = dragged, let group {
            guard draggedGroup != group.id else { return nil }
            return upper && isFirst ? .before(.group(group.id)) : .after(.group(group.id))
        }
        let target = upper || !run.isCollapsed ? first : last
        guard dragged != .session(target) else { return nil }
        return target == first ? .before(.session(first)) : .after(.session(last))
    }
}

/// The line down a project's sessions, under its heading's ▾.
private struct ProjectRule: View {
    /// Where the project's list starts.
    let leading: CGFloat

    var body: some View {
        Rectangle().fill(Theme.line.opacity(0.7)).frame(width: 1).padding(.leading, leading + 6)
            .allowsHitTesting(false)
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
    let canMove: @MainActor (SessionOrderStore.Move) -> Bool
    let move: @MainActor (SessionOrderStore.Move) -> Void
    /// Whether to mention ⌥⌘↑/↓, which act on the selected session.
    let shortcuts: Bool

    init(item: QueueItemID, model: AppModel, shortcuts: Bool) {
        canMove = { model.canMove(item, $0) }
        move = { model.move(item, $0) }
        self.shortcuts = shortcuts
    }

    init(project: ProjectRunID, model: AppModel) {
        canMove = { model.canMove(project, $0) }
        move = { model.move(project, $0) }
        shortcuts = false
    }

    var body: some View {
        VStack(spacing: 0) {
            arrow("▲", .up, help: shortcuts ? "Raise priority (⌥⌘↑)" : "Raise priority")
            arrow("▼", .down, help: shortcuts ? "Lower priority (⌥⌘↓)" : "Lower priority")
        }
    }

    private func arrow(_ glyph: String, _ direction: SessionOrderStore.Move, help: String) -> some View {
        let enabled = canMove(direction)
        return Button { withAnimation(.snappy(duration: 0.18)) { move(direction) } } label: {
            Text(glyph).font(.system(size: 7)).frame(width: 18, height: 13).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.phosphor : Theme.faint.opacity(0.5))
        .disabled(!enabled)
        .help(help)
    }
}

/// Priority commands shared by session, group and project context menus.
private struct PriorityMenu: View {
    let canMove: @MainActor (SessionOrderStore.Move) -> Bool
    let move: @MainActor (SessionOrderStore.Move) -> Void

    init(item: QueueItemID, model: AppModel) {
        canMove = { model.canMove(item, $0) }
        move = { model.move(item, $0) }
    }

    init(project: ProjectRunID, model: AppModel) {
        canMove = { model.canMove(project, $0) }
        move = { model.move(project, $0) }
    }

    var body: some View {
        Button("Move to Top") { move(.first) }.disabled(!canMove(.first))
        Button("Raise Priority") { move(.up) }.disabled(!canMove(.up))
        Button("Lower Priority") { move(.down) }.disabled(!canMove(.down))
        Button("Move to Bottom") { move(.last) }.disabled(!canMove(.last))
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
        if let item = model.dragging, hint == landing(item, info.location.y) { hint = nil }
    }

    /// Where the item would land, unless the queue keeps it from going there.
    private func landing(_ item: QueueItemID, _ y: CGFloat) -> QueueDrop? {
        resolve(item, y).flatMap { model.allowsDrop(item, $0) ? $0 : nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { hint = nil }
        guard let item = model.dragging, let drop = landing(item, info.location.y),
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
        hint = landing(item, info.location.y)
    }
}

private struct ShellRowView: View {
    let shell: ShellRow
    /// Grouped shells are indented under their group's header, like its sessions.
    let isGrouped: Bool
    let isSelected: Bool
    let showsMachine: Bool
    /// Its branch, else its repository or folder; shown on hover only.
    let place: String?
    let open: () -> Void
    @ViewState<Bool> private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("$").font(Theme.mono(11, .bold)).foregroundStyle(isSelected ? Theme.phosphor : Theme.faint)
                .frame(width: 18, alignment: .center)
                .help("Shell")
            Text(shell.pane.workspaceName).font(Theme.mono(12, .medium)).foregroundStyle(Theme.text.opacity(0.8)).lineLimit(1)
            if hovering, let place {
                Text(place).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            }
            if showsMachine {
                Text("@\(shell.machine.name)").font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .padding(.leading, isGrouped ? 26 : 12).padding(.trailing, 8).padding(.vertical, 5)
        .background(isSelected ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear)
        .onHover { hovering = $0 }
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

/// Where the queue can scroll to. Distinct per kind, like the lists' own identities: a shell and
/// the agent Herdr later detects in it share an `Agent.ID`.
private enum SidebarAnchor: Hashable {
    case session(Agent.ID), shell(Agent.ID), group(String)
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

/// A session's pull requests, `⇄ #12` or `⇄ 3 PRs` with their checks: lilac once they landed, dim
/// once closed. With `showsIssues`, a session without any shows its issues instead, `◉ #7` or
/// `◉ 2 issues`. Clicking opens them in the session's browser.
struct SessionLinksLabel: View {
    let model: AppModel
    let id: Agent.ID
    var showsIssues = false

    var body: some View {
        let pulls = model.pullRequests(of: id)
        let issues = showsIssues && pulls.isEmpty ? model.issues(of: id) : []
        if !pulls.isEmpty {
            pullsButton(pulls)
        } else if !issues.isEmpty {
            issuesButton(issues)
        }
    }

    private func issuesButton(_ issues: [SessionResource]) -> some View {
        let label = issues.count == 1 ? Self.number(of: issues[0]) : "\(issues.count) issues"
        return Button { model.openResources(issues, of: id) } label: {
            Text("◉ " + label).foregroundStyle(Theme.phosphor.opacity(0.85)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(([issues.count == 1 ? "Open in this session's browser:" : "Open these issues in this session's browser:"]
               + issues.prefix(10).map { [$0.name, $0.title].compactMap { $0 }.joined(separator: "  ") }).joined(separator: "\n"))
    }

    private func pullsButton(_ pulls: [SessionResource]) -> some View {
        let label = pulls.count == 1 ? Self.number(of: pulls[0]) : "\(pulls.count) PRs"
        // Lilac once its pull requests landed, as in Resources: the session's work is in.
        let tint = switch model.checksMonitor.outcome(of: pulls) {
        case .landed: Theme.lilac
        case .dropped: Theme.dim
        case nil: Theme.phosphor
        }
        return Button { model.openResources(pulls, of: id) } label: {
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

    /// `#12`: the number without its repository, or `!12` for GitLab.
    private static func number(of resource: SessionResource) -> String {
        guard let mark = resource.name.lastIndex(where: { $0 == "#" || $0 == "!" }) else { return resource.name }
        return String(resource.name[mark...])
    }
}
