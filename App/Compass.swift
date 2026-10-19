import AppKit
import Foundation
import Observation
import WebKit
import ShepherdrCore

/// The two modes of the window: the queue of agent sessions, and Compass, the day's page.
enum AppMode: String {
    case agents, compass
}

/// Compass: an agent of its own on this Mac, in `~/.shepherdr/compass`, that keeps a page of the
/// day. Shepherdr starts it, sends it a prompt on the schedule you choose, keeps a copy of the
/// page after each run, and commits the folder to Git. The page's buttons ask Shepherdr for
/// sessions, prompts and marks, and nothing happens until you confirm.
@MainActor @Observable
final class CompassController {
    @ObservationIgnored weak var model: AppModel?
    let folder: CompassFolder
    @ObservationIgnored let kit: CompassFolder.Kit?
    private(set) var config = CompassConfig()
    private(set) var state = CompassState()
    /// Whether the folder exists: Compass was set up on this Mac.
    private(set) var isSetUp = false
    /// Why compass.json couldn't be read; Compass keeps the last settings it could.
    private(set) var configProblem: String?
    /// The last thing that went wrong, such as a session that didn't start.
    var problem: String?
    /// The page and the links it opens.
    let browser = SessionBrowser()
    /// What the page tab shows: today's page, another day's, or a copy a run left.
    private(set) var shown: Shown = .today
    /// Whether the Compass agent's terminal shows beside the page.
    var showsAgent = true { didSet { UserDefaults.standard.set(showsAgent, forKey: "compassShowsAgent") } }
    private(set) var backup: BackupStatus = .none
    /// Whether the GitHub remote is public, which a Compass backup shouldn't be.
    private(set) var remoteIsPublic = false
    /// When the page changed, as last seen.
    private(set) var pageModified: Date?
    /// Set up in progress, from the empty state or a restore.
    private(set) var isPreparing = false

    enum Shown: Equatable {
        case today
        case day(String)
        case snapshot(day: String, time: String)
    }

    enum BackupStatus: Equatable {
        case none, working
        case done(Date)
        case failed(String)
    }

    @ObservationIgnored private let repository: CompassRepository
    @ObservationIgnored private var bridge: CompassBridge?
    @ObservationIgnored private var pageTab: BrowserTab?
    @ObservationIgnored private var configModified: Date?
    @ObservationIgnored private var lastSessions: CompassSessions?
    @ObservationIgnored private var lastSessionsWrite = Date.distantPast
    @ObservationIgnored private var delivering = false
    @ObservationIgnored private var creatingAgent = false
    @ObservationIgnored private var sawWorking = false
    @ObservationIgnored private var notifiedBlocked: String?
    @ObservationIgnored private var lastTyping = Date.distantPast
    @ObservationIgnored private var backupQueue: Task<Void, Never>?
    @ObservationIgnored private var pendingCommit: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// A run waits this long after you last typed to the agent.
    private static let typingPause: TimeInterval = 120
    /// The agent's own name in Herdr, and its workspace's.
    static let agentName = "compass"

    init(folder: CompassFolder = .standard()) {
        self.folder = folder
        kit = try? CompassFolder.bundledKit()
        repository = CompassRepository(root: folder.root)
        showsAgent = UserDefaults.standard.object(forKey: "compassShowsAgent") as? Bool ?? true
        load()
    }

    var calendar: Calendar { .current }
    var today: String { Compass.day(Date(), calendar: calendar) }

    // MARK: Loading

    /// Reads the folder, brings Shepherdr's files up to date and settles runs a quit left open.
    private func load() {
        isSetUp = folder.exists
        guard isSetUp else { return }
        state = folder.readState()
        if let kit, let written = try? folder.prepare(kit, written: state.written) { state.written = written }
        readConfig()
        let now = Date()
        for index in state.runs.indices where state.runs[index].isOpen {
            if state.runs[index].day != Compass.day(now, calendar: calendar) {
                state.runs[index].outcome = .failed
                state.runs[index].problem = "The day ended before it ran."
            } else if state.runs[index].outcome == .running {
                // Shepherdr quit while the agent worked: the next refresh tells whether it finished.
                sawWorking = true
            }
        }
        pageModified = folder.modified(folder.page(today))
        saveState()
        showPage()
    }

    private func readConfig() {
        configModified = folder.modified(folder.configURL)
        switch folder.readConfig() {
        case .read(let read):
            let remoteChanged = read.backup != config.backup
            config = read
            configProblem = nil
            // The agent may set the backup too, when you ask it to.
            if remoteChanged { configureRemote() }
        case .unreadable(let detail):
            configProblem = "compass.json can't be read, so Compass keeps its last settings: \(detail)"
        case .missing:
            break
        }
    }

    private func saveState() {
        if state.runs.count > CompassState.keptRuns { state.runs.removeFirst(state.runs.count - CompassState.keptRuns) }
        try? folder.writeState(state)
    }

    /// Starts checking the schedule. Refreshes also check it; this covers paused refreshing.
    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    // MARK: Setting up

    /// Makes the folder, starts the agent and asks for the first page.
    func setUp(agent: String) async {
        guard let kit, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            state.written = try folder.prepare(kit, written: state.written)
            var config = CompassConfig()
            config.agent = agent
            try folder.writeConfig(config)
            isSetUp = true
            readConfig()
            saveState()
            commitSoon("Set up Compass")
            runNow()
        } catch {
            problem = AppModel.failure(error).message
        }
    }

    /// Brings the folder back from its backup, then starts as usual.
    func restore(from remote: String) async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await repository.restore(from: remote)
            load()
            if config.backup != remote { update { $0.backup = remote } }
            backup = .done(Date())
        } catch {
            problem = (error as? HerdrFailure).map { [$0.message, $0.detail].compactMap { $0 }.joined(separator: " ") }
                ?? error.localizedDescription
        }
    }

    // MARK: Settings

    /// Changes the settings and saves them to compass.json, as the agent may too.
    func update(_ change: (inout CompassConfig) -> Void) {
        var changed = config
        change(&changed)
        guard changed != config else { return }
        let remoteChanged = changed.backup != config.backup
        config = changed
        do {
            try folder.writeConfig(changed)
            configModified = folder.modified(folder.configURL)
            configProblem = nil
        } catch {
            problem = "Couldn't save compass.json: \(error.localizedDescription)"
        }
        if remoteChanged { configureRemote() }
    }

    var templateIsCustomized: Bool { isSetUp && folder.isCustomized("template.html", written: state.written) }

    func restoreTemplate() {
        guard let kit else { return }
        if let written = try? folder.restore("template.html", from: kit) {
            state.written["template.html"] = written
            saveState()
        }
    }

    // MARK: The agent

    /// The Compass agent's terminal, while Herdr has it: by the terminal Shepherdr started, or
    /// by its workspace and folder after Herdr restarted.
    var agentID: Agent.ID? {
        guard isSetUp, let snapshot = localSnapshot else { return nil }
        if let terminal = state.terminalID, snapshot.panes.contains(where: { $0.terminalID == terminal }) {
            return Agent.ID(machineID: Machine.local.id, terminalID: terminal)
        }
        let root = folder.root.standardizedFileURL.resolvingSymlinksInPath().path
        let pane = snapshot.panes.first { pane in
            pane.workspaceName == Self.agentName
                && pane.directory.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == root } == true
        }
        return pane.map { Agent.ID(machineID: Machine.local.id, terminalID: $0.terminalID) }
    }

    /// Cheap enough to ask for every row: the terminal is kept current on each refresh.
    func isCompass(_ id: Agent.ID) -> Bool {
        isSetUp && id.machineID == Machine.local.id && id.terminalID == state.terminalID
    }

    /// The terminal Compass's agent last ran in.
    var terminal: Agent.ID? { state.terminalID.map { Agent.ID(machineID: Machine.local.id, terminalID: $0) } }

    private var localSnapshot: MachineSnapshot? {
        model?.cluster.machines.first { $0.machine.isLocal }?.snapshot
    }

    var agentRow: AgentRow? { agentID.flatMap { model?.row(for: $0) } }

    /// You typed to the agent: a run waits until you've been quiet for a while.
    func noteTyping() { lastTyping = Date() }

    private var isTyping: Bool {
        var last = lastTyping
        if let terminal = model?.activeTerminal, let id = agentID, terminal.target.terminalID == id.terminalID,
           let input = terminal.lastInput { last = max(last, input) }
        return Date().timeIntervalSince(last) < Self.typingPause
    }

    /// Every pane in Compass's folder and workspace: the agent's, and any left from before.
    private var compassPanes: [TerminalPane] {
        let root = folder.root.standardizedFileURL.resolvingSymlinksInPath().path
        return localSnapshot?.panes.filter { pane in
            pane.terminalID == state.terminalID || (pane.workspaceName.hasPrefix(Self.agentName)
                && pane.directory.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path == root } == true)
        } ?? []
    }

    /// Gets the agent going for a run: a fresh one for the day's first, closing yesterday's and
    /// anything left in Compass's folder; or an agent in the pane whose agent exited.
    private func prepareAgent(fresh: Bool) async -> Bool {
        guard let model, !creatingAgent else { return false }
        creatingAgent = true
        defer { creatingAgent = false }
        do {
            var pane = fresh ? nil : agentID.flatMap { id in localSnapshot?.panes.first { $0.terminalID == id.terminalID } }
                .map { (paneID: $0.paneID, terminalID: $0.terminalID) }
            // Sessions the old agent waited for hand their results to the new one.
            var awaited: [Agent.ID] = []
            if fresh {
                for old in compassPanes {
                    awaited += model.relations.waitingFor(Agent.ID(machineID: Machine.local.id, terminalID: old.terminalID))
                    try await model.cluster.closeSession(paneID: old.paneID, onMachine: Machine.local.id)
                    model.forgetSession(Agent.ID(machineID: Machine.local.id, terminalID: old.terminalID))
                }
            }
            if pane == nil {
                let created = try await model.cluster.createSession(
                    NewSessionRequest(directory: folder.root.path, name: Self.agentName, agentKind: nil), onMachine: Machine.local.id)
                pane = (paneID: created.paneID, terminalID: created.terminalID)
            }
            guard let pane else { return false }
            let id = Agent.ID(machineID: Machine.local.id, terminalID: pane.terminalID)
            for other in awaited { model.relations.setWaiting(id, for: other, true) }
            state.terminalID = pane.terminalID
            state.agentDay = today
            sawWorking = false
            saveState()
            // Another agent may be called compass already, such as one Herdr kept from before.
            var notice: String?
            do {
                notice = try await model.cluster.startAgent(Self.agentName, kind: config.agent, paneID: pane.paneID, onMachine: Machine.local.id)
            } catch let failure as HerdrFailure where failure.detail == "Herdr error: agent_name_taken" {
                let name = "\(Self.agentName)-\(String(format: "%04x", Int.random(in: 0..<0x10000)))"
                notice = try await model.cluster.startAgent(name, kind: config.agent, paneID: pane.paneID, onMachine: Machine.local.id)
            }
            if let notice { model.sessionNotices[Agent.ID(machineID: Machine.local.id, terminalID: pane.terminalID)] = notice }
            return true
        } catch {
            problem = "The Compass agent didn't start: \(AppModel.failure(error).message)"
            return false
        }
    }

    // MARK: Runs

    var openRun: CompassRun? { state.runs.last(where: \.isOpen) }
    var lastFinished: CompassRun? { state.runs.last { $0.finished != nil && $0.outcome != .failed } }

    var nextRun: Date? {
        guard isSetUp, config.enabled else { return nil }
        return config.schedule.nextSlot(after: Date(), calendar: calendar)
    }

    /// A run now, as if it were scheduled: the first of the day if none ran today.
    func runNow() {
        guard isSetUp, openRun == nil else { return }
        let now = Date()
        let kind = Compass.kind(for: nil, at: now, runs: state.runs, schedule: config.schedule, calendar: calendar)
        state.runs.append(CompassRun(kind: kind, trigger: .manual, slot: nil, created: now, day: Compass.day(now, calendar: calendar)))
        saveState()
        problem = nil
        deliver()
    }

    /// Stops waiting for the open run: the agent keeps whatever it is doing.
    func cancelRun() {
        guard let run = openRun else { return }
        fail(run.id, "Cancelled")
    }

    /// Checks the schedule and moves the open run along.
    func tick() {
        guard isSetUp else { return }
        if folder.modified(folder.configURL) != configModified { readConfig() }
        let now = Date()
        if config.enabled, openRun == nil,
           let slot = config.schedule.dueSlot(at: now, lastRun: state.runs.last?.created, calendar: calendar) {
            let kind = Compass.kind(for: slot, at: now, runs: state.runs, schedule: config.schedule, calendar: calendar)
            state.runs.append(CompassRun(kind: kind, trigger: .scheduled, slot: slot, created: now, day: Compass.day(now, calendar: calendar)))
            saveState()
        }
        settleDay(now)
        deliver()
    }

    /// A run left waiting past midnight belongs to a day that is over.
    private func settleDay(_ now: Date) {
        let today = Compass.day(now, calendar: calendar)
        guard let index = state.runs.lastIndex(where: \.isOpen), state.runs[index].day != today,
              state.runs[index].outcome == .waiting else { return }
        state.runs[index].outcome = .failed
        state.runs[index].problem = "The day ended before it ran."
        saveState()
    }

    /// What the agent is doing about the open run, for the column and the tab.
    enum Activity: Equatable {
        case idle
        case waitingForAgent
        case waitingForYou
        case running(since: Date)
        /// The agent stopped at a question, such as a permission.
        case needsYou
    }

    var activity: Activity {
        guard let run = openRun else { return agentRow?.agent.state == .blocked ? .needsYou : .idle }
        if agentRow?.agent.state == .blocked { return .needsYou }
        if run.outcome == .running { return .running(since: run.sent ?? run.created) }
        return isTyping ? .waitingForYou : .waitingForAgent
    }

    /// Sends the open run's prompt once the agent is free, starting the agent first if needed.
    private func deliver() {
        // Only Herdr's answer tells whether the agent is there: wait for this Mac's first one.
        guard let model, !delivering, localSnapshot != nil, model.cluster.machines.first(where: { $0.machine.isLocal })?.connection == .online,
              let index = state.runs.lastIndex(where: \.isOpen), state.runs[index].outcome == .waiting else { return }
        let run = state.runs[index]
        let agent = agentID
        // The day's first run starts a fresh agent; a pane whose agent exited gets one again.
        let fresh = agent == nil || (run.kind == .first && state.agentDay != run.day)
        if fresh || model.row(for: agent!) == nil {
            guard !isTyping, !creatingAgent else { return }
            delivering = true
            Task {
                let started = await prepareAgent(fresh: fresh)
                delivering = false
                if !started { fail(run.id, problem ?? "The Compass agent didn't start.") }
            }
            return
        }
        guard let agent, let row = model.row(for: agent), !row.isStale,
              row.agent.state == .idle || row.agent.state == .done, !isTyping,
              !model.courier.mail.items.contains(where: { $0.recipient == agent && $0.status == .queued }) else {
            notifyIfBlocked(run)
            return
        }
        delivering = true
        writeSessions(force: true)
        writeRunContext(run)
        let since = lastFinished?.finished
        let prompt = run.prompt(since: since, calendar: calendar, page: folder.pagePath(run.day))
        Task {
            defer { delivering = false }
            do {
                try await model.cluster.prompt(paneID: row.agent.paneID, text: prompt, onMachine: agent.machineID)
                record(run.id) {
                    $0.outcome = .running
                    $0.sent = Date()
                }
                sawWorking = false
            } catch {
                let failure = AppModel.failure(error)
                // A question on screen or an agent still starting: tried again on a later tick.
                if let detail = failure.detail, ["agent_blocked", "agent_not_ready", "agent_busy"].contains(where: detail.hasSuffix) { return }
                fail(run.id, failure.message)
            }
        }
    }

    private func notifyIfBlocked(_ run: CompassRun) {
        guard agentRow?.agent.state == .blocked, notifiedBlocked != run.id, let id = agentID else { return }
        notifiedBlocked = run.id
        model?.notifier.letterNotice("Compass is waiting for you in its terminal before it can update the page.",
                                     from: id, machine: "this Mac")
    }

    private func record(_ id: String, _ change: (inout CompassRun) -> Void) {
        guard let index = state.runs.firstIndex(where: { $0.id == id }) else { return }
        change(&state.runs[index])
        saveState()
    }

    private func fail(_ id: String, _ problem: String) {
        record(id) {
            $0.outcome = .failed
            $0.finished = Date()
            $0.problem = problem
        }
    }

    /// Called after every refresh: follows the agent through the run, and keeps its context current.
    func observe() {
        guard isSetUp else { return }
        if let id = agentID, state.terminalID != id.terminalID {
            state.terminalID = id.terminalID
            saveState()
        }
        checkPage()
        writeSessions(force: false)
        pushDecorations()
        if let run = openRun, run.outcome == .running { follow(run) }
        tick()
    }

    private func follow(_ run: CompassRun) {
        guard let row = agentRow else {
            if localSnapshot != nil { fail(run.id, "The Compass agent stopped during the run.") }
            return
        }
        switch row.agent.state {
        case .working:
            sawWorking = true
        case .blocked:
            notifyIfBlocked(run)
        case .idle, .done:
            let sent = run.sent ?? run.created
            // Herdr may not report the agent working before it is done with a short run.
            guard sawWorking || Date().timeIntervalSince(sent) > 60 else { return }
            finish(run, sent: sent)
        case .unknown:
            break
        }
    }

    private func finish(_ run: CompassRun, sent: Date) {
        let page = folder.page(run.day)
        let updated = (folder.modified(page) ?? .distantPast) > sent
        var snapshot: String?
        if updated {
            let time = Compass.time(run.slot ?? run.created, calendar: calendar).replacingOccurrences(of: ":", with: "-")
            snapshot = try? folder.snapshot(run.day, at: time)
        }
        record(run.id) {
            $0.outcome = updated ? .updated : .unchanged
            $0.finished = Date()
            $0.snapshot = snapshot
        }
        if let cutoff = calendar.date(byAdding: .day, value: -14, to: Date()) {
            folder.pruneSnapshots(before: Compass.day(cutoff, calendar: calendar))
        }
        checkPage()
        commitSoon("Compass run · \(run.kind.rawValue) · \(Compass.stamp(run.slot ?? run.created, calendar: calendar))", now: true)
    }

    /// The run's details for the agent, in context/run.json.
    private func writeRunContext(_ run: CompassRun) {
        var details: [String: Any] = [
            "kind": run.kind.rawValue, "trigger": run.trigger.rawValue,
            "started": Compass.iso(Date(), calendar: calendar),
            "page": folder.pagePath(run.day), "marks": "days/\(run.day).marks.json",
            "time_zone": calendar.timeZone.identifier,
            "language": Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en",
            "strip": ["from": config.strip.from.description, "to": config.strip.to.description],
            "schedule": config.schedule.summary,
            "last_of_day": run.kind == .last,
        ]
        if let slot = run.slot { details["slot"] = Compass.iso(slot, calendar: calendar) }
        if let since = lastFinished?.finished { details["since"] = Compass.iso(since, calendar: calendar) }
        if let previous = folder.days().first(where: { $0 < run.day }) { details["previous"] = folder.pagePath(previous) }
        if let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? folder.writeContext("run.json", data)
        }
    }

    // MARK: Your sessions, for the agent

    /// Writes context/sessions.json when the queue changed, at most every half minute.
    private func writeSessions(force: Bool) {
        guard let model, force || Date().timeIntervalSince(lastSessionsWrite) > 30 else { return }
        let sessions = context(model)
        guard force || sessions.sessions != lastSessions?.sessions || sessions.machines != lastSessions?.machines else { return }
        lastSessions = sessions
        lastSessionsWrite = Date()
        try? folder.writeContext("sessions.json", sessions.encoded())
    }

    private func context(_ model: AppModel) -> CompassSessions {
        let catalog = model.cluster.machines.map(\.machine)
        let macName = model.courier.tools.macName
        func machineName(_ id: String) -> String {
            MachineList.name(of: model.machine(for: Agent.ID(machineID: id, terminalID: "")), among: catalog, macName: macName)
        }
        func link(_ resource: SessionResource) -> CompassSessions.Link {
            let checks = model.checksMonitor.checks[resource.key]
            let state: String? = if let checks { checks.isMerged ? "merged" : checks.isOpen ? "open" : "closed" }
                else { model.checksMonitor.issues[resource.key].map { $0.isOpen ? "open" : "closed" } }
            let result: String? = switch checks?.state {
            case .passed: "passed"
            case .failed: "failed"
            case .running: "running"
            case .some(.none), nil: nil
            }
            return .init(url: resource.url.absoluteString, title: resource.title, checks: result, state: state)
        }
        let sessions = model.rankedRows.map { row in
            CompassSessions.Session(
                priority: row.manualPriority, name: row.name, workspace: row.workspace, machine: machineName(row.id.machineID),
                state: row.agent.state.rawValue, agent: row.agent.program.name, title: row.title, folder: row.agent.directory,
                group: model.groups.first { $0.members.contains(row.id) }?.name,
                waitsFor: model.relations.waitingFor(row.id).compactMap { model.row(for: $0)?.name },
                pullRequests: model.pullRequests(of: row.id).prefix(10).map(link),
                issues: model.issues(of: row.id).prefix(10).map(link),
                links: model.resources(for: row.id).filter { $0.kind == .artifact || $0.kind == .link }.filter { !$0.isMissing }
                    .prefix(10).map(link),
                stale: row.isStale)
        }
        let machines = model.cluster.machines.filter(\.machine.isEnabled).map {
            CompassSessions.MachineInfo(name: machineName($0.id), online: $0.connection == .online, here: $0.machine.isLocal)
        }
        return CompassSessions(generated: Compass.iso(Date(), calendar: calendar), machines: machines, sessions: sessions)
    }

    // MARK: The page

    /// The page the tab should show.
    var shownURL: URL? {
        switch shown {
        case .today: folder.page(today)
        case .day(let day): folder.page(day)
        case .snapshot(let day, let time): folder.snapshotFolder(day).appendingPathComponent("\(time).html")
        }
    }

    var hasTodaysPage: Bool { FileManager.default.fileExists(atPath: folder.page(today).path) }

    func show(_ what: Shown) {
        shown = what
        showPage()
    }

    /// Loads what `shown` names into the page's tab, which stays first and can't be closed.
    private func showPage() {
        guard let url = shownURL, FileManager.default.fileExists(atPath: url.path) else {
            if let tab = pageTab {
                browser.close(tab)
                pageTab = nil
            }
            return
        }
        if let tab = pageTab, browser.tabs.contains(where: { $0 === tab }) {
            if tab.url != url { tab.load(url) }
            browser.selectedID = tab.id
        } else {
            let bridge = bridge ?? CompassBridge(controller: self)
            self.bridge = bridge
            let tab = BrowserTab(url: url, browser: browser, configuration: bridge.configuration)
            tab.isPinned = true
            tab.opensLink = { [weak self] url in self?.open(url) }
            pageTab = tab
            browser.add(tab)
            browser.move(tab, to: 0)
        }
        browser.isVisible = true
    }

    /// Reloads the page when the agent changed it, and notes that there's something new.
    private func checkPage() {
        let modified = folder.modified(folder.page(today))
        guard modified != pageModified else { return }
        pageModified = modified
        if case .today = shown { showPage(); pageTab?.reload() }
        commitSoon("Compass page · \(Compass.stamp(Date(), calendar: calendar))")
    }

    /// Whether today's page changed since you last looked at it.
    var hasNews: Bool {
        guard let pageModified else { return false }
        return pageModified > (state.lastViewed ?? .distantPast)
    }

    /// You're looking at the page.
    func viewed() {
        guard hasNews else { return }
        state.lastViewed = Date()
        saveState()
    }

    /// Opens a link from the page or the agent's terminal: Compass pages in the page tab, the rest in a tab of their own.
    func open(_ url: URL) {
        let root = folder.root.standardizedFileURL.path + "/"
        if url.isFileURL, url.standardizedFileURL.path.hasPrefix(root + "days/"), url.pathExtension == "html" {
            let name = url.deletingPathExtension().lastPathComponent
            if Compass.isDay(name) { show(name == today ? .today : .day(name)); return }
        }
        browser.open(url)
    }

    // MARK: Actions from the page

    /// The page asked for something. Every action waits for you: nothing starts by itself.
    func perform(_ action: CompassAction) {
        guard let model else { return }
        switch action {
        case .spawn(let spawn, let item):
            let names = MachineList.uniqueNames(model.cluster.machines.map(\.machine), macName: model.courier.tools.macName)
            let machineID = spawn.machine.flatMap { wanted in names.first { $0.value.lowercased() == wanted.lowercased() }?.key }
            if let wanted = spawn.machine, machineID == nil {
                problem = "The page asked for a session on \(wanted), which isn't one of your machines."
                return
            }
            model.newSession = NewSessionDraft(
                directory: spawn.directory, machineID: machineID ?? Machine.local.id, placement: nil,
                name: spawn.name, agentKind: spawn.agent == "shell" ? nil : (spawn.agent ?? config.agent),
                prompt: spawn.prompt, compass: .init(day: currentDay, item: item, compassWaits: agentID != nil))
        case .ask(let text):
            guard let id = agentID else { problem = "Start the Compass session first: RUN NOW."; return }
            model.fill(text, into: id)
            showsAgent = true
        case .session(let name):
            guard let id = lookup(name) else { return }
            model.mode = .agents
            model.open(id)
        case .prompt(let name, let text):
            guard let id = lookup(name) else { return }
            model.mode = .agents
            model.open(id)
            model.fill(text, into: id)
        case .done(let item):
            toggleDone(item)
        }
    }

    /// The day the page tab shows, whose marks its buttons change.
    private var currentDay: String {
        switch shown {
        case .today: today
        case .day(let day), .snapshot(let day, _): day
        }
    }

    private func lookup(_ name: String) -> Agent.ID? {
        guard let model else { return nil }
        switch SessionLookup.find(name, in: model.rankedRows, machines: model.cluster.machines.map(\.machine),
                                  macName: model.courier.tools.macName, preferring: nil) {
        case .found(let id): return id
        case .missing: problem = "No session is named \(name)."
        case .ambiguous: problem = "Several sessions are named \(name). The page should add @machine."
        }
        return nil
    }

    private func toggleDone(_ item: String) {
        var marks = folder.readMarks(currentDay)
        if marks.done[item] == nil { marks.done[item] = Date() } else { marks.done[item] = nil }
        try? folder.writeMarks(marks, for: currentDay)
        pushDecorations()
        commitSoon("Compass marks · \(Compass.stamp(Date(), calendar: calendar))")
    }

    /// A session you started from the page: the page shows it, the agent reads it next run, and
    /// Compass's session waits for it, so a handoff you ask it for comes back to Compass.
    func started(_ session: Agent.ID, named name: String, for draft: NewSessionDraft.FromCompass) {
        guard let model else { return }
        if draft.compassWaits, let compass = agentID { model.relations.setWaiting(compass, for: session, true) }
        guard let item = draft.item else { return }
        var marks = folder.readMarks(draft.day)
        let machine = model.machine(for: session)
        let label = machine.isLocal ? name
            : "\(name)@\(MachineList.name(of: machine, among: model.cluster.machines.map(\.machine), macName: model.courier.tools.macName))"
        marks.started[item] = .init(session: label, at: Date())
        try? folder.writeMarks(marks, for: draft.day)
        pushDecorations()
    }

    /// What Shepherdr adds to the page: each session's state, the items done and the sessions started.
    private func decorations() -> [String: Any] {
        guard let model else { return [:] }
        var sessions: [String: [String: String]] = [:]
        let catalog = model.cluster.machines.map(\.machine)
        let names = MachineList.uniqueNames(catalog, macName: model.courier.tools.macName)
        for row in model.rankedRows {
            let status = model.status(of: row)
            let info = ["state": status.rawValue, "label": status.label]
            let machine = names[row.id.machineID]?.lowercased()
            for key in [row.name.lowercased(), row.workspace.lowercased()] where !key.isEmpty {
                if sessions[key] == nil || row.id.machineID == Machine.local.id { sessions[key] = info }
                if let machine { sessions["\(key)@\(machine)"] = info }
            }
        }
        let marks = folder.readMarks(currentDay)
        return ["sessions": sessions, "done": Array(marks.done.keys),
                "started": marks.started.mapValues(\.session)]
    }

    /// Sends the decorations to the page, which applies them in Shepherdr's own script world.
    /// - Parameter force: for a page that just loaded, which has nothing yet.
    func pushDecorations(force: Bool = false) {
        guard let tab = pageTab, let bridge else { return }
        bridge.apply(decorations(), to: tab.webView, force: force)
    }

    // MARK: Backup

    /// Commits the folder after a change, a little later so a burst of edits makes one commit;
    /// pushes when a remote is set.
    func commitSoon(_ message: String, now: Bool = false) {
        guard isSetUp, repository.isAvailable else { return }
        pendingCommit?.cancel()
        pendingCommit = Task { [weak self] in
            if !now { try? await Task.sleep(for: .seconds(45)) }
            guard !Task.isCancelled else { return }
            self?.enqueueBackup { repository in
                _ = try await repository.commit(message)
                try await repository.push()
            }
        }
    }

    /// Backs up right away, from Settings.
    func backUpNow() {
        enqueueBackup { repository in
            _ = try await repository.commit("Compass backup · \(Compass.stamp(Date(), calendar: .current))")
            try await repository.push()
        }
    }

    private func configureRemote() {
        let remote = config.backup
        enqueueBackup { repository in
            try await repository.setRemote(remote)
            _ = try await repository.commit("Compass backup settings")
            try await repository.push()
        }
        remoteIsPublic = false
        if let remote {
            Task { remoteIsPublic = await CompassRepository.isPrivate(remote) == false }
        }
    }

    private func enqueueBackup(_ work: @escaping @Sendable (CompassRepository) async throws -> Void) {
        let previous = backupQueue
        let repository = repository
        backupQueue = Task { [weak self] in
            await previous?.value
            self?.backup = .working
            do {
                try await repository.prepare()
                try await work(repository)
                self?.backup = .done(Date())
            } catch {
                let failure = AppModel.failure(error)
                self?.backup = .failed([failure.message, failure.detail].compactMap { $0 }.joined(separator: " "))
            }
        }
    }

    var hasGit: Bool { repository.isAvailable }
}

/// The page's way to Shepherdr. Its script runs in a world of its own, out of reach of the
/// page's scripts, and only passes on clicks a person made on elements with `data-shepherdr`.
/// It also shows what Shepherdr knows on the page: sessions' states, marks, sessions started.
@MainActor
final class CompassBridge: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "shepherdr-compass")
    weak var controller: CompassController?
    let configuration: WKWebViewConfiguration
    /// What the page was last given: the same again on every refresh would only wake its web process.
    private var applied: (page: ObjectIdentifier, json: String)?

    init(controller: CompassController) {
        self.controller = controller
        configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = BrowserTab.configuration.websiteDataStore
        configuration.applicationNameForUserAgent = BrowserTab.configuration.applicationNameForUserAgent
        super.init()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Self.world))
        content.add(self, contentWorld: Self.world, name: "shepherdr")
        configuration.userContentController = content
    }

    func apply(_ decorations: [String: Any], to webView: WKWebView, force: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: decorations, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return }
        let page = ObjectIdentifier(webView)
        guard force || applied?.page != page || applied?.json != json else { return }
        applied = (page, json)
        webView.evaluateJavaScript("window.__shepherdrCompass && window.__shepherdrCompass.apply(\(json))", in: nil, in: Self.world)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let controller, message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let url = message.frameInfo.request.url, url.isFileURL,
              url.standardizedFileURL.path.hasPrefix(controller.folder.root.standardizedFileURL.path + "/") else { return }
        switch body["type"] as? String {
        case "ready":
            controller.pushDecorations(force: true)
        case "action":
            guard let raw = body["fields"] as? [String: Any] else { return }
            let fields = raw.compactMapValues { $0 as? String }
            if let action = CompassAction(fields) { controller.perform(action) }
            else { controller.problem = "Shepherdr didn't recognize that button on the page, or one of its values." }
        default:
            break
        }
    }

    /// Runs in the bridge's own world: page scripts can't reach `postMessage` here.
    static let script = #"""
    (function () {
      if (window.__shepherdrCompass) return;
      function post(message) { try { window.webkit.messageHandlers.shepherdr.postMessage(message); } catch (e) {} }
      function fields(element) {
        var result = {};
        for (var key in element.dataset) result[key] = String(element.dataset[key]);
        if (!result.item) {
          var holder = element.closest('[data-item]');
          if (holder) result.item = holder.getAttribute('data-item');
        }
        return result;
      }
      document.addEventListener('click', function (event) {
        if (!event.isTrusted || !event.target || !event.target.closest) return;
        var element = event.target.closest('[data-shepherdr]');
        if (!element) return;
        event.preventDefault();
        event.stopPropagation();
        post({ type: 'action', fields: fields(element) });
      }, true);
      var style = document.createElement('style');
      style.textContent =
        '.shepherdr-state{display:inline-flex;align-items:center;gap:5px;margin-left:6px;padding:1px 7px;border-radius:999px;' +
        'border:1px solid #1F2B25;font:500 10.5px ui-monospace,Menlo,monospace;color:#7E9488;vertical-align:middle;white-space:nowrap}' +
        '.shepherdr-state::before{content:"";width:6px;height:6px;border-radius:50%;background:#4B5E53}' +
        '.shepherdr-state[data-state=working]{color:#5CD6FF}.shepherdr-state[data-state=working]::before{background:#5CD6FF}' +
        '.shepherdr-state[data-state=needsYou]{color:#FFB547;border-color:rgba(255,181,71,.4)}.shepherdr-state[data-state=needsYou]::before{background:#FFB547}' +
        '.shepherdr-state[data-state=waiting]{color:#5CD6FF}.shepherdr-state[data-state=waiting]::before{background:transparent;border:1px solid #5CD6FF}' +
        '.shepherdr-state[data-state=done]{color:#4DFFA0}.shepherdr-state[data-state=done]::before{background:#4DFFA0}' +
        '.shepherdr-done{opacity:.5}.shepherdr-done .t,.shepherdr-done>.t{text-decoration:line-through}' +
        '[data-shepherdr=done][aria-pressed=true]{color:#4DFFA0;border-color:rgba(77,255,160,.6)}' +
        '.shepherdr-started{font:500 10.5px ui-monospace,Menlo,monospace;color:#5CD6FF;margin-left:6px}';
      document.head.appendChild(style);
      function badge(element, info) {
        var mark = element.querySelector(':scope > .shepherdr-state');
        if (!info) { if (mark) mark.remove(); return; }
        if (!mark) { mark = document.createElement('span'); mark.className = 'shepherdr-state'; element.appendChild(mark); }
        mark.setAttribute('data-state', info.state);
        mark.textContent = info.label;
      }
      function apply(state) {
        var sessions = state.sessions || {}, done = state.done || [], started = state.started || {};
        document.querySelectorAll('[data-session]').forEach(function (element) {
          if (element.getAttribute('data-shepherdr') === 'prompt') return;
          badge(element, sessions[String(element.getAttribute('data-session')).toLowerCase()]);
        });
        document.querySelectorAll('[data-item]').forEach(function (element) {
          var id = element.getAttribute('data-item');
          var isDone = done.indexOf(id) >= 0;
          element.classList.toggle('shepherdr-done', isDone);
          element.querySelectorAll('[data-shepherdr=done]').forEach(function (button) {
            if (button.closest('[data-item]') !== element) return;
            button.setAttribute('aria-pressed', isDone ? 'true' : 'false');
            if (!button.hasAttribute('data-label')) button.setAttribute('data-label', button.textContent);
            button.textContent = isDone ? '✓ ' + button.getAttribute('data-label') : button.getAttribute('data-label');
          });
          var name = started[id];
          element.querySelectorAll('[data-shepherdr=spawn]').forEach(function (button) {
            if (button.closest('[data-item]') !== element) return;
            var note = button.nextElementSibling && button.nextElementSibling.classList.contains('shepherdr-started') ? button.nextElementSibling : null;
            if (!name) { if (note) note.remove(); return; }
            if (!note) { note = document.createElement('span'); note.className = 'shepherdr-started'; button.after(note); }
            note.textContent = '▶ ' + name;
            badge(note, sessions[String(name).toLowerCase()]);
          });
        });
      }
      window.__shepherdrCompass = { apply: apply };
      post({ type: 'ready' });
    })();
    """#
}
