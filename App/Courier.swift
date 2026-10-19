import AppKit
import Foundation
import Observation
import ShepherdrCore

/// Shepherdr's side of the agent tools. It keeps them installed where you want them and writes
/// each machine its list. It collects the letters agents leave, from this Mac and over SSH, and
/// carries out what they ask. Every connection starts here: machines never connect back.
@MainActor @Observable
final class Courier {
    let tools: AgentToolsStore
    let mail: MailStore
    /// Letters that couldn't be read or acted on, with no session to show them on.
    private(set) var notices: [String] = []
    @ObservationIgnored weak var model: AppModel?
    /// The tools this Shepherdr carries; nil only in a broken build.
    @ObservationIgnored let kit: AgentTools.Kit?
    @ObservationIgnored private let inbox = Mailbox.inbox()
    /// Work on each machine runs one step at a time, in order.
    @ObservationIgnored private var queues: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var busy = Set<String>()
    @ObservationIgnored private var delivering = Set<String>()
    @ObservationIgnored private var lastDelivery: [Agent.ID: Date] = [:]
    /// When writing a machine's list last failed: retried after a while, not on every refresh.
    @ObservationIgnored private var listFailures: [String: Date] = [:]
    /// Why the last install on a machine failed, until the next attempt.
    private(set) var installFailures: [String: String] = [:]
    /// Sessions handing their work back before they close, by session.
    private(set) var handoffCloses: [Agent.ID: HandoffClose] = [:]
    /// Sessions whose agent is being asked to hand off right now.
    @ObservationIgnored private var asking = Set<Agent.ID>()
    /// Sessions that asked to close themselves, waiting for their agent to finish its turn.
    @ObservationIgnored private var closingWhenFree = Set<Agent.ID>()

    /// A session's agent gets one delivery at a time: the next waits until it worked on this one.
    private static let deliveryGap: TimeInterval = 20
    /// Machines are checked again at most this often when you open one of their sessions.
    private static let recheck: TimeInterval = 600

    init(tools: AgentToolsStore = AgentToolsStore(), mail: MailStore = MailStore()) {
        self.tools = tools
        self.mail = mail
        kit = try? AgentTools.bundled()
        // A request that was starting when Shepherdr quit may not have started: ask again.
        for item in mail.items where item.kind == .spawnRequest && item.status == .queued {
            mail.update(item.id) { $0.status = .needsApproval }
        }
        let inbox = inbox
        let kept = Set(mail.items.map(\.letterID))
        Task.detached(priority: .background) { Mailbox.tidy(inbox, keeping: kept) }
    }

    private var cluster: ClusterStore? { model?.cluster }
    private var catalog: [Machine] { cluster?.machines.map(\.machine) ?? [.local] }

    private func machine(_ id: String) -> Machine? {
        cluster?.machines.first { $0.id == id }.map(\.machine)
    }

    private func name(of machineID: String) -> String {
        guard let machine = machine(machineID) else { return machineID }
        return MachineList.name(of: machine, among: catalog, macName: tools.macName)
    }

    // MARK: Following refreshes

    /// Called after every refresh: checks machines seen for the first time, collects where a
    /// doorbell rang, keeps lists current and delivers what is due.
    func observe() {
        guard let cluster, kit != nil else { return }
        for state in cluster.machines where state.connection == .online {
            let id = state.id
            let current = tools.tools(on: id)
            switch current.status {
            case .unknown:
                check(id)
            case .failed where Date().timeIntervalSince(current.lastCheck ?? .distantPast) > Self.recheck:
                check(id)
            default:
                if current.status.isInstalled, let bells = state.snapshot?.doorbells, mail.hasNewDoorbells(bells, on: id) {
                    collect(id)
                }
            }
        }
        syncLists()
        deliver()
        settleMissingRecipients()
        advanceHandoffCloses()
        closeFinishedSessions()
    }

    /// Checks again a machine whose session you opened, when its last check is a while ago.
    func sessionOpened(_ id: Agent.ID) {
        let current = tools.tools(on: id.machineID)
        guard current.status != .unknown, Date().timeIntervalSince(current.lastCheck ?? .distantPast) > Self.recheck,
              cluster?.machines.first(where: { $0.id == id.machineID })?.connection == .online else { return }
        check(id.machineID)
    }

    /// A refresh you asked for also looks in every outbox, for letters whose doorbell was lost,
    /// such as when Herdr restarted.
    func sweep() {
        guard let cluster else { return }
        for state in cluster.machines where state.connection == .online && tools.status(on: state.id).isInstalled {
            check(state.id)
        }
    }

    private func enqueue(_ machineID: String, _ work: @escaping @MainActor () async -> Void) {
        let previous = queues[machineID]
        queues[machineID] = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: Checking and installing

    func check(_ machineID: String) {
        guard !busy.contains("check:\(machineID)") else { return }
        busy.insert("check:\(machineID)")
        if tools.status(on: machineID) == .unknown { tools.set(.checking, on: machineID) }
        enqueue(machineID) { [weak self] in
            guard let self else { return }
            defer { self.busy.remove("check:\(machineID)") }
            guard let machine = self.machine(machineID), let kit = self.kit else { return }
            let bells = self.cluster?.machines.first { $0.id == machineID }?.snapshot?.doorbells ?? [:]
            let found: AgentTools.Check
            do {
                found = try await AgentTools.check(machine)
            } catch {
                self.tools.recordFailedCheck(AppModel.failure(error).message, on: machineID)
                return
            }
            self.tools.record(found, on: machineID, bundled: kit.version)
            if found.version == nil { return }
            if found.waitingLetters > 0 { await self.collectNow(machineID) } else { self.mail.answer(bells, on: machineID) }
            let outdated = if case .outdated = self.tools.status(on: machineID) { true } else { false }
            // Codex installed after the tools, or an update you let through without asking.
            if found.lacksSkill || (outdated && self.tools.updatePolicy == .always) {
                await self.installNow(machineID)
            } else {
                await self.writeListIfNeeded(machineID)
            }
        }
    }

    func install(_ machineID: String) {
        installFailures[machineID] = nil
        tools.set(.installing, on: machineID)
        enqueue(machineID) { [weak self] in await self?.installNow(machineID) }
    }

    private func installNow(_ machineID: String) async {
        guard let machine = machine(machineID), let kit else { return }
        tools.set(.installing, on: machineID)
        let entries = listEntries(for: machine)
        do {
            try await AgentTools.install(kit, list: MachineList.render(entries), on: machine)
            let found = try await AgentTools.check(machine)
            tools.record(found, on: machineID, bundled: kit.version)
        } catch {
            let failure = AppModel.failure(error)
            installFailures[machineID] = [failure.message, failure.detail].compactMap { $0 }.joined(separator: " ")
            tools.set(.failed(failure.message), on: machineID)
        }
    }

    func uninstall(_ machineID: String) {
        tools.set(.removing, on: machineID)
        enqueue(machineID) { [weak self] in
            guard let self, let machine = self.machine(machineID), let kit = self.kit else { return }
            do {
                try await AgentTools.uninstall(from: machine)
                self.tools.record(try await AgentTools.check(machine), on: machineID, bundled: kit.version)
            } catch {
                self.tools.set(.failed(AppModel.failure(error).message), on: machineID)
            }
        }
    }

    /// What the session's banner offers about the tools on its machine, if anything.
    enum Offer: Equatable {
        case install, update(Int), working(String), failed(String)
    }

    func offer(for machineID: String) -> Offer? {
        let machineName = name(of: machineID)
        switch tools.status(on: machineID) {
        case .missing:
            return tools.declined.contains(machineID) || tools.postponed.contains(machineID) ? nil : .install
        case .outdated(let version):
            return tools.updatePolicy == .ask && !tools.postponed.contains(machineID) ? .update(version) : nil
        case .installing:
            return .working("Installing the agent tools on \(machineName)…")
        case .failed:
            return installFailures[machineID].map(Offer.failed)
        default:
            return nil
        }
    }

    // MARK: Machine lists

    private func listEntries(for machine: Machine) -> [MachineList.Entry] {
        MachineList.entries(for: machine, machines: catalog, macName: tools.macName, shares: tools.shares(machine.id))
    }

    /// Writes the list on machines whose copy doesn't match the catalog anymore. Comparing
    /// revisions costs nothing, so refreshes only write when something changed.
    private func syncLists() {
        guard let cluster else { return }
        for state in cluster.machines where state.connection == .online {
            let current = tools.tools(on: state.id)
            guard current.status.isInstalled, let check = current.check,
                  check.listRevision != MachineList.revision(of: listEntries(for: state.machine)),
                  Date().timeIntervalSince(listFailures[state.id] ?? .distantPast) > Self.recheck,
                  !busy.contains("list:\(state.id)") else { continue }
            busy.insert("list:\(state.id)")
            let id = state.id
            enqueue(id) { [weak self] in
                await self?.writeListIfNeeded(id)
                self?.busy.remove("list:\(id)")
            }
        }
    }

    private func writeListIfNeeded(_ machineID: String) async {
        guard let machine = machine(machineID), tools.status(on: machineID).isInstalled else { return }
        let entries = listEntries(for: machine)
        let revision = MachineList.revision(of: entries)
        guard tools.tools(on: machineID).check?.listRevision != revision else { return }
        do {
            try await AgentTools.writeList(MachineList.render(entries), on: machine)
            tools.recordList(revision, on: machineID)
            listFailures[machineID] = nil
        } catch {
            listFailures[machineID] = Date()
        }
    }

    // MARK: Collecting

    func collect(_ machineID: String) {
        guard !busy.contains("mail:\(machineID)") else { return }
        busy.insert("mail:\(machineID)")
        enqueue(machineID) { [weak self] in
            await self?.collectNow(machineID)
            self?.busy.remove("mail:\(machineID)")
        }
    }

    private func collectNow(_ machineID: String) async {
        guard let machine = machine(machineID) else { return }
        // The doorbells seen before the trip are the ones it answers.
        let bells = cluster?.machines.first { $0.id == machineID }?.snapshot?.doorbells ?? [:]
        var more = true
        while more {
            let delivery: Mailbox.Delivery
            do { delivery = try await Mailbox.collect(from: machine) } catch { return }
            more = delivery.hasMore
            var filed: [String] = []
            for collected in delivery.letters {
                if mail.hasRead(collected.id, from: machineID) {
                    filed.append(collected.id)
                    continue
                }
                if let size = collected.oversize {
                    // Filed unread: it moves to outbox/.collected there and stops holding up the letters after it.
                    let bytes = { (count: Int) in ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file) }
                    notices.append("A letter from \(name(of: machineID)) was set aside: at \(bytes(size)), it's over the \(bytes(Mailbox.tripLimit)) a letter may take.")
                    filed.append(collected.id)
                    continue
                }
                do {
                    let letter = try Letter(id: collected.id, contents: collected.contents)
                    let folder = try Mailbox.keep(collected, from: machine, in: inbox)
                    apply(letter, from: machine, folder: folder)
                } catch let error as LetterError {
                    // A letter Shepherdr can't read is set aside, so it doesn't come back.
                    notices.append("A letter from \(name(of: machineID)) couldn't be read: \(error.message)")
                } catch {
                    // Not kept on this Mac: leave it there for the next trip.
                    continue
                }
                filed.append(collected.id)
            }
            mail.markRead(filed, from: machineID)
            do { try await Mailbox.acknowledge(filed, on: machine) } catch { return }
        }
        mail.answer(bells, on: machineID)
    }

    private func apply(_ letter: Letter, from machine: Machine, folder: URL) {
        guard let model else { return }
        let context = MailContext(origin: machine, isTrusted: tools.trusted.contains(machine.id), rows: model.cluster.agents,
                                  machines: catalog, macName: tools.macName, waits: model.relations.waits,
                                  protected: model.compass.terminal.map { [$0] } ?? [])
        let actions = MailPlanner.plan(letter, folder: folder.path, context: context)
        for action in actions {
            switch action {
            case .wait(let waiter, let awaited):
                model.relations.setWaiting(waiter, for: awaited, true)
            case .stopWaiting(let waiter, nil):
                model.relations.stopWaiting(waiter)
            case .stopWaiting(let waiter, let awaited?):
                model.relations.setWaiting(waiter, for: awaited, false)
            case .place(let child, let parent):
                // Compass isn't in the queue: what it starts joins the end.
                model.order.insert(child, model.compass.isCompass(parent) ? .end : .after(.session(parent)))
            case .keep(let item):
                mail.add(item)
                if item.kind == .spawnRequest, item.status == .queued {
                    start(item)
                } else if item.needsUser {
                    model.notifier.mailArrived(item, about: item.recipient ?? item.sender)
                }
            case .pin(let session, let resource):
                model.collectResources([resource], for: session)
            case .open(let session, let url):
                model.workspace(for: session).browser.open(url)
            case .notify(let session, let text):
                model.notifier.letterNotice(text, from: session, machine: name(of: machine.id))
            case .problem(let session?, let text):
                model.sessionNotices[session] = text
            case .problem(nil, let text):
                notices.append(text)
            }
        }
        for close in handoffCloses.values {
            if let outcome = close.outcome(of: actions) { finish(close, outcome) }
        }
    }

    func dismissNotice(at index: Int) {
        guard notices.indices.contains(index) else { return }
        notices.remove(at: index)
    }

    // MARK: Delivering

    /// Sends queued handoffs and first prompts to their sessions once those are free: idle or done.
    private func deliver() {
        guard let model else { return }
        let now = Date()
        for item in mail.items where item.status == .queued && (item.kind == .handoff || item.kind == .prompt) {
            guard !delivering.contains(item.id), let recipient = item.recipient, let row = model.row(for: recipient), !row.isStale,
                  row.agent.state == .idle || row.agent.state == .done,
                  now.timeIntervalSince(lastDelivery[recipient] ?? .distantPast) > Self.deliveryGap else { continue }
            delivering.insert(item.id)
            lastDelivery[recipient] = now
            Task { await transmit(item, to: row) }
        }
    }

    private func transmit(_ item: MailItem, to row: AgentRow) async {
        defer { delivering.remove(item.id) }
        guard let model else { return }
        let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
        let message = item.hasMessage ? try? String(contentsOf: folder.appendingPathComponent("message.md"), encoding: .utf8) : nil
        let machine = model.machine(for: row.id)
        do {
            var attachments = item.files.map { folder.appendingPathComponent($0).path }
            var messagePath: String? = folder.appendingPathComponent("message.md").path
            if !machine.isLocal {
                // On another machine, its files are copied there first.
                attachments = []
                for file in item.files { attachments.append(try await FileDrop.upload(folder.appendingPathComponent(file), to: machine)) }
                if item.kind == .handoff, (message?.count ?? 0) > 6_000 {
                    messagePath = try await FileDrop.upload(folder.appendingPathComponent("message.md"), to: machine)
                }
            }
            let text = MailPlanner.prompt(for: item, message: message, messagePath: messagePath, attachments: attachments)
            try await model.cluster.prompt(paneID: row.agent.paneID, text: text, onMachine: row.id.machineID)
            remove(item)
        } catch {
            let failure = AppModel.failure(error)
            // A question on screen or an agent still starting: tried again once it is free.
            if let detail = failure.detail, ["agent_blocked", "agent_not_ready", "agent_busy"].contains(where: detail.hasSuffix) {
                return
            }
            mail.update(item.id) {
                $0.status = .failed
                $0.problem = failure.message
            }
        }
    }

    /// Mail for a session that closed can't be delivered anymore. Only a snapshot taken a while
    /// after the letter arrived can tell: a session started on another machine may not be in the
    /// last one yet.
    private func settleMissingRecipients() {
        guard let cluster else { return }
        for item in mail.items where item.status == .queued || item.status == .needsApproval {
            guard let recipient = item.recipient,
                  let state = cluster.machines.first(where: { $0.id == recipient.machineID }),
                  state.connection == .online, let snapshot = state.snapshot,
                  let taken = cluster.lastSuccess[state.id], taken.timeIntervalSince(item.received) > 30,
                  !snapshot.panes.contains(where: { $0.terminalID == recipient.terminalID }) else { continue }
            mail.update(item.id) {
                $0.status = .failed
                $0.problem = "Its session closed before it could be delivered."
            }
        }
    }

    // MARK: Closing

    /// Ends a session as Close Session does, and tells the session that asked, if another did.
    private func close(_ session: Agent.ID, asked asker: Agent.ID?) {
        guard let model else { return }
        closingWhenFree.remove(session)
        let name = model.row(for: session)?.workspace ?? model.shell(for: session)?.pane.workspaceName ?? "A session"
        Task {
            guard await model.closeSession(session), let asker, asker != session, model.row(for: asker) != nil else { return }
            model.sessionNotices[asker] = "Closed \(name), as this session's agent asked."
        }
    }

    /// Closes the sessions that asked to close themselves once their agent is idle or done; forgets
    /// the ones that closed some other way.
    private func closeFinishedSessions() {
        guard let model else { return }
        for id in closingWhenFree {
            guard let row = model.row(for: id) else {
                closingWhenFree.remove(id)
                continue
            }
            if !row.isStale, row.agent.state == .idle || row.agent.state == .done { close(id, asked: nil) }
        }
    }

    // MARK: Handing off and closing

    /// Why a session can't hand off and close, or nil when it can: it needs an agent, sessions
    /// waiting for it, and the agent tools on its machine to hand off with.
    func whyNoHandoffClose(_ id: Agent.ID) -> String? {
        guard let model, let row = model.row(for: id), !row.isStale else { return "Only a session with an agent can hand off its work." }
        guard !model.relations.waiters(of: id).isEmpty else { return "No session waits for this one." }
        guard tools.status(on: id.machineID).isInstalled else {
            return "Its agent hands off with the agent tools. Install them on \(name(of: id.machineID)) from the session's banner or Settings → Agents."
        }
        return nil
    }

    /// Asks the session's agent, once it is free, to hand its work back to the sessions waiting for
    /// it, and closes the session when the handoff arrives.
    func handOffAndClose(_ id: Agent.ID) {
        guard let model, whyNoHandoffClose(id) == nil, handoffCloses[id] == nil else { return }
        handoffCloses[id] = HandoffClose(session: id, waiters: model.relations.waiters(of: id))
        model.sessionNotices[id] = nil
        advanceHandoffCloses()
    }

    /// Keeps the session open. A request already in its agent's prompt stays there; a handoff
    /// that comes is delivered as usual.
    func cancelHandoffClose(_ id: Agent.ID) {
        handoffCloses[id] = nil
    }

    /// Asks the agents that are free now, and gives up on handoffs that never came.
    private func advanceHandoffCloses() {
        guard let model else { return }
        let now = Date()
        for (id, close) in handoffCloses {
            // Closed some other way.
            guard let row = model.row(for: id) else {
                handoffCloses[id] = nil
                continue
            }
            switch close.stage {
            case .queued:
                guard !row.isStale, row.agent.state == .idle || row.agent.state == .done, !asking.contains(id) else { continue }
                ask(row, for: close)
            case .asked:
                guard close.hasExpired(now: now, agentIsWorking: row.agent.state == .working) else { continue }
                handoffCloses[id] = nil
                model.sessionNotices[id] = "No handoff came from \(row.workspace) within \(Int(HandoffClose.patience / 60)) minutes of asking, so it stays open."
            }
        }
    }

    private func ask(_ row: AgentRow, for close: HandoffClose) {
        guard let model else { return }
        asking.insert(row.id)
        let names = close.waiters.compactMap { model.row(for: $0)?.workspace }
        Task {
            defer { asking.remove(row.id) }
            do {
                try await model.cluster.prompt(paneID: row.agent.paneID, text: HandoffClose.prompt(waiters: names), onMachine: row.id.machineID)
                if handoffCloses[row.id]?.stage == .queued { handoffCloses[row.id]?.stage = .asked(Date()) }
            } catch {
                let failure = AppModel.failure(error)
                // A question on screen or an agent still starting: asked again once it is free.
                if let detail = failure.detail, ["agent_blocked", "agent_not_ready", "agent_busy"].contains(where: detail.hasSuffix) {
                    return
                }
                handoffCloses[row.id] = nil
                model.sessionNotices[row.id] = "Couldn't ask \(row.workspace) to hand off, so it stays open: \(failure.message)"
            }
        }
    }

    /// Closes a session whose handoff is on this Mac, and tells the sessions waiting for it; opens
    /// one of them if the session was on screen. A handoff that went elsewhere keeps it open.
    private func finish(_ close: HandoffClose, _ outcome: HandoffClose.Outcome) {
        guard let model else { return }
        handoffCloses[close.session] = nil
        switch outcome {
        case .strayed(let text):
            model.sessionNotices[close.session] = text
        case .handedOff(let awaitingApproval):
            let name = model.row(for: close.session)?.workspace ?? "The session it waited for"
            let waiters = close.waiters.filter { model.row(for: $0) != nil }
            for waiter in waiters {
                model.sessionNotices[waiter] = awaitingApproval.contains(waiter)
                    ? "\(name) handed off its work and closed. Its handoff waits for your approval in this session's mail."
                    : "\(name) handed off its work and closed. Shepherdr delivers it once this session is free."
            }
            if model.selectedID == close.session, let first = waiters.first { model.open(first) }
            Task { await model.closeSession(close.session) }
        }
    }

    // MARK: Your decisions

    /// Lets an item through: a handoff is delivered once its recipient is free, a session starts,
    /// a page opens.
    func approve(_ item: MailItem) {
        switch item.kind {
        case .handoff, .prompt:
            mail.update(item.id) {
                $0.status = .queued
                $0.problem = nil
            }
            deliver()
        case .spawnRequest:
            start(item)
        case .openPage:
            if let url = item.url, let session = item.recipient { model?.workspace(for: session).browser.open(url) }
            mail.remove(item.id)
        case .close:
            mail.remove(item.id)
            guard let model, let session = item.recipient else { return }
            // A session that asked to close itself ends once its agent has finished its turn; a
            // shell has no turn to finish.
            if session == item.sender, let row = model.row(for: session), row.agent.state == .working || row.agent.state == .blocked {
                closingWhenFree.insert(session)
                model.sessionNotices[session] = "Shepherdr closes this session once its agent finishes this turn."
                closeFinishedSessions()
            } else {
                close(session, asked: item.sender)
            }
        }
    }

    /// Picks the session a handoff goes to. Choosing it is letting it through.
    func send(_ item: MailItem, to recipient: Agent.ID) {
        mail.update(item.id) {
            $0.recipient = recipient
            $0.status = .queued
            $0.problem = nil
        }
        deliver()
    }

    func discard(_ item: MailItem) { remove(item) }

    /// Done with an item. A first prompt Shepherdr kept for a session it started, such as one
    /// a Compass page asked for, leaves the disk with it: only letters stay in the inbox.
    private func remove(_ item: MailItem) {
        mail.remove(item.id)
        let kept = inbox.appendingPathComponent("compass", isDirectory: true).standardizedFileURL.path + "/"
        guard item.id.hasPrefix("compass/"), URL(fileURLWithPath: item.folder).standardizedFileURL.path.hasPrefix(kept) else { return }
        try? FileManager.default.removeItem(atPath: item.folder)
    }

    /// A first prompt for a session Shepherdr just started, such as one a Compass page asked
    /// for: kept in the inbox like a letter's, and delivered once the agent is ready.
    func queuePrompt(_ text: String, for session: Agent.ID, name: String) {
        // Named like a letter, so the inbox clears it after a month like one.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let id = "\(formatter.string(from: Date()))-\(String(format: "%06x", Int.random(in: 0..<0x100_0000)))"
        let folder = inbox.appendingPathComponent("compass", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: folder.appendingPathComponent("message.md"), options: .atomic)
        } catch {
            model?.sessionNotices[session] = "Shepherdr couldn't keep the first prompt for \(name): \(error.localizedDescription)"
            return
        }
        let headline = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) }
        mail.add(MailItem(id: "compass/\(id)", letterID: id, kind: .prompt, origin: Machine.local.id, originName: "Compass",
                          sender: nil, senderName: "Compass", recipient: session, status: .queued, received: Date(),
                          folder: folder.path, headline: headline, hasMessage: true, files: [], addressedTo: nil))
        deliver()
    }

    /// Starts a session another machine asked for, linked to the session that asked.
    private func start(_ item: MailItem) {
        guard let model, let request = item.request else { return }
        let names = MachineList.uniqueNames(catalog, macName: tools.macName)
        guard let machineID = names.first(where: { $0.value.lowercased() == request.machine.lowercased() })?.key else {
            mail.update(item.id) {
                $0.status = .failed
                $0.problem = "No machine is named \(request.machine)."
            }
            return
        }
        mail.update(item.id) { $0.status = .queued }
        Task {
            let name = request.name ?? Self.sessionName(for: request.directory, agent: request.agent)
            let created: CreatedSession
            do {
                created = try await model.cluster.createSession(NewSessionRequest(directory: request.directory, name: name, agentKind: request.agent),
                                                                onMachine: machineID)
            } catch {
                mail.update(item.id) {
                    $0.status = .failed
                    $0.problem = AppModel.failure(error).message
                }
                return
            }
            let child = Agent.ID(machineID: machineID, terminalID: created.terminalID)
            if let notice = created.notice { model.sessionNotices[child] = notice }
            if let requester = item.sender {
                model.order.insert(child, .after(.session(requester)))
                if request.wait { model.relations.setWaiting(requester, for: child, true) }
            }
            mail.remove(item.id)
            if item.hasMessage {
                // The request's prompt waits for the new agent like any first prompt.
                mail.add(MailItem(id: item.id + "/prompt", letterID: item.letterID, kind: .prompt, origin: item.origin,
                                  originName: item.originName, sender: item.sender, senderName: item.senderName,
                                  recipient: child, status: .queued, received: Date(), folder: item.folder,
                                  headline: item.headline, hasMessage: true, files: [], addressedTo: nil))
            }
        }
    }

    /// A Herdr agent name from a folder, like the command line makes them: `api-7f3a`.
    static func sessionName(for directory: String, agent: String?) -> String {
        let base = (directory as NSString).lastPathComponent.lowercased()
            .map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "-" }
            .drop { !($0.isASCII && $0.isLetter) }
        let stem = String(String(base).prefix(24))
        let suffix = String(format: "%04x", Int.random(in: 0..<0x10000))
        return "\(stem.isEmpty || directory == "~" ? (agent ?? "shell") : stem)-\(suffix)"
    }
}
