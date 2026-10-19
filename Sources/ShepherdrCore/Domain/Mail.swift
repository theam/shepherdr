import Foundation

/// A collected letter that waits for something: the user's approval, a recipient, or its
/// recipient to be free. Shepherdr keeps these across launches; the letters' files stay in the
/// inbox on this Mac.
public struct MailItem: Identifiable, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// Work handed back, delivered to its recipient as a prompt.
        case handoff
        /// The first prompt of a session `shepherdr spawn` started, for when its agent is ready.
        case prompt
        /// A session on a machine the sender can't reach.
        case spawnRequest
        /// A page a session on another machine suggests opening.
        case openPage
        /// A session an agent asks to close, its own or another: it closes only when the user
        /// presses CLOSE.
        case close
    }

    public enum Status: String, Codable, Sendable {
        /// Waits for the user to let it through.
        case needsApproval
        /// Nobody waits for its sender, or the session it named doesn't exist: the user picks one.
        case needsRecipient
        /// On its way: delivered once its recipient is free, or carried out right away.
        case queued
        /// Couldn't be delivered; `problem` says why.
        case failed
    }

    /// A requested session, as the letter asked for it.
    public struct Request: Codable, Equatable, Sendable {
        public let machine: String
        public let directory: String
        public let agent: String?
        public let name: String?
        public let wait: Bool
    }

    public let id: String
    public let letterID: String
    public let kind: Kind
    /// The machine the letter came from.
    public let origin: String
    public let originName: String
    public let sender: Agent.ID?
    /// Who the sender was when the letter arrived, such as `fixer`.
    public let senderName: String?
    public var recipient: Agent.ID?
    public var status: Status
    public let received: Date
    /// Where the letter's files are kept on this Mac.
    public let folder: String
    public let headline: String?
    public let hasMessage: Bool
    public let files: [String]
    /// The recipient as the letter named it.
    public let addressedTo: String?
    public var url: URL?
    public var request: Request?
    public var problem: String?

    public init(id: String, letterID: String, kind: Kind, origin: String, originName: String, sender: Agent.ID?,
                senderName: String?, recipient: Agent.ID?, status: Status, received: Date, folder: String,
                headline: String?, hasMessage: Bool, files: [String], addressedTo: String?,
                url: URL? = nil, request: Request? = nil, problem: String? = nil) {
        self.id = id
        self.letterID = letterID
        self.kind = kind
        self.origin = origin
        self.originName = originName
        self.sender = sender
        self.senderName = senderName
        self.recipient = recipient
        self.status = status
        self.received = received
        self.folder = folder
        self.headline = headline
        self.hasMessage = hasMessage
        self.files = files
        self.addressedTo = addressedTo
        self.url = url
        self.request = request
        self.problem = problem
    }

    /// Whether it waits for the user rather than for a session.
    public var needsUser: Bool { status != .queued }
}

/// What Shepherdr does with a letter.
public enum MailAction: Equatable, Sendable {
    case wait(Agent.ID, for: Agent.ID)
    /// Stops waiting for one session, or for all when nil.
    case stopWaiting(Agent.ID, for: Agent.ID?)
    /// Puts a new session right after the one that started it, in its group.
    case place(Agent.ID, after: Agent.ID)
    case keep(MailItem)
    case pin(Agent.ID, SessionResource)
    case open(Agent.ID, URL)
    case notify(Agent.ID?, String)
    /// Something in the letter couldn't be done, to show on the sender if there is one.
    case problem(Agent.ID?, String)
}

/// What Shepherdr knows when a letter arrives.
public struct MailContext: Sendable {
    public let origin: Machine
    /// You chose to let this machine's letters through without asking.
    public let isTrusted: Bool
    public let rows: [AgentRow]
    public let machines: [Machine]
    public let macName: String
    /// Each waiting session and the sessions it waits for.
    public let waits: [Agent.ID: [Agent.ID]]
    /// Sessions letters can't close, such as Compass's own agent.
    public let protected: Set<Agent.ID>

    public init(origin: Machine, isTrusted: Bool, rows: [AgentRow], machines: [Machine], macName: String,
                waits: [Agent.ID: [Agent.ID]], protected: Set<Agent.ID> = []) {
        self.origin = origin
        self.isTrusted = isTrusted
        self.rows = rows
        self.machines = machines
        self.macName = macName
        self.waits = waits
        self.protected = protected
    }
}

public enum MailPlanner {
    /// Turns a letter into actions. Letters from this Mac apply on their own. From another
    /// machine, text that would reach a session on a different machine, a request for a session,
    /// a page to open and closing a session on a different machine wait for the user, unless you
    /// trust that machine.
    public static func plan(_ letter: Letter, folder: String, context: MailContext, now: Date = Date()) -> [MailAction] {
        let origin = context.origin
        let sender = letter.sender.map { Agent.ID(machineID: origin.id, terminalID: $0.terminalID) }
        let senderName = sender.flatMap { id in context.rows.first { $0.id == id } }.map(\.name)
        func item(_ kind: MailItem.Kind, index: Int = 0, recipient: Agent.ID?, status: MailItem.Status,
                  addressedTo: String? = nil, problem: String? = nil) -> MailItem {
            MailItem(id: "\(origin.id)/\(letter.id)/\(index)", letterID: letter.id, kind: kind, origin: origin.id,
                     originName: MachineList.name(of: origin, among: context.machines, macName: context.macName),
                     sender: sender, senderName: senderName, recipient: recipient, status: status, received: now,
                     folder: folder, headline: letter.headline, hasMessage: letter.message != nil, files: letter.files,
                     addressedTo: addressedTo, problem: problem)
        }
        func needsSender(_ what: String) -> MailAction {
            .problem(nil, "A letter from \(origin.name) asked to \(what), but it wasn't written in a Herdr pane.")
        }

        switch letter.content {
        case .spawned(let spawned):
            let child: Agent.ID
            switch spawned.machine {
            case .here:
                child = Agent.ID(machineID: origin.id, terminalID: spawned.terminalID)
            case .profile(let profile):
                // Only this Mac's Herdr profiles mean anything to Shepherdr.
                guard origin.isLocal, let machine = context.machines.first(where: { $0.profileID == profile }) else {
                    return [.problem(sender, "A session started on a machine Shepherdr doesn't know couldn't be linked.")]
                }
                child = Agent.ID(machineID: machine.id, terminalID: spawned.terminalID)
            }
            var actions: [MailAction] = []
            if let sender {
                actions.append(.place(child, after: sender))
                if spawned.wait { actions.append(.wait(sender, for: child)) }
            }
            if spawned.promptPending {
                actions.append(.keep(item(.prompt, recipient: child, status: .queued)))
            }
            return actions

        case .spawnRequest(let request):
            var kept = item(.spawnRequest, recipient: nil, status: context.isTrusted ? .queued : .needsApproval)
            kept.request = MailItem.Request(machine: request.machine, directory: request.directory, agent: request.agent,
                                            name: request.name, wait: request.wait)
            return [.keep(kept)]

        case .handoff(let to):
            let recipients: [Agent.ID]
            var problem: String?
            if let to {
                switch SessionLookup.find(to, in: context.rows, machines: context.machines, macName: context.macName,
                                          preferring: origin.id) {
                case .found(let id): recipients = [id]
                case .missing: recipients = []; problem = "No session is named \(to)."
                case .ambiguous: recipients = []; problem = "Several sessions are named \(to)."
                }
            } else if let sender {
                recipients = context.waits.filter { $0.value.contains(sender) }.map(\.key)
                    .sorted { ($0.machineID, $0.terminalID) < ($1.machineID, $1.terminalID) }
                if recipients.isEmpty { problem = "No session waits for its sender." }
            } else {
                recipients = []
            }
            guard !recipients.isEmpty else {
                return [.keep(item(.handoff, recipient: nil, status: .needsRecipient, addressedTo: to, problem: problem))]
            }
            return recipients.enumerated().map { index, recipient in
                let crosses = recipient.machineID != origin.id
                let asks = !origin.isLocal && !context.isTrusted && crosses
                return .keep(item(.handoff, index: index, recipient: recipient, status: asks ? .needsApproval : .queued, addressedTo: to))
            }

        case .wait(let names):
            guard let sender else { return [needsSender("wait for other sessions")] }
            return names.map { name in
                switch SessionLookup.find(name, in: context.rows, machines: context.machines, macName: context.macName,
                                          preferring: origin.id) {
                case .found(let id) where id != sender: .wait(sender, for: id)
                case .found: .problem(sender, "A session can't wait for itself.")
                case .missing: .problem(sender, "No session is named \(name), so this one can't wait for it.")
                case .ambiguous: .problem(sender, "Several sessions are named \(name). Add @machine to pick one.")
                }
            }

        case .resume(let names):
            guard let sender else { return [needsSender("resume a session")] }
            guard !names.isEmpty else { return [.stopWaiting(sender, for: nil)] }
            return names.map { name in
                switch SessionLookup.find(name, in: context.rows, machines: context.machines, macName: context.macName,
                                          preferring: origin.id) {
                case .found(let id): .stopWaiting(sender, for: id)
                case .missing: .problem(sender, "No session is named \(name).")
                case .ambiguous: .problem(sender, "Several sessions are named \(name). Add @machine to pick one.")
                }
            }

        case .pin(let url, let title):
            guard let sender else { return [needsSender("pin a link")] }
            guard let resource = SessionResource(pinned: url, title: title) else { return [.problem(sender, "Only http and https links can be pinned.")] }
            return [.pin(sender, resource)]

        case .open(let url):
            guard let sender else { return [needsSender("open a page")] }
            if origin.isLocal || context.isTrusted { return [.open(sender, url)] }
            var kept = item(.openPage, recipient: sender, status: .needsApproval)
            kept.url = url
            return [.keep(kept)]

        case .notify:
            return [.notify(sender, letter.message ?? "")]

        case .close(let names, let force):
            guard let sender else { return [needsSender("close a session")] }
            let protected = "Compass's own session can't be closed this way."
            // Ending a session is always the user's call: each one asked for waits for their CLOSE,
            // whichever machine asked and however trusted it is.
            func ask(_ id: Agent.ID, index: Int, name: String?) -> MailAction {
                .keep(item(.close, index: index, recipient: id, status: .needsApproval, addressedTo: name))
            }
            func closeSelf(index: Int = 0, name: String? = nil) -> MailAction {
                if context.protected.contains(sender) { return .problem(sender, protected) }
                return ask(sender, index: index, name: name)
            }
            guard !names.isEmpty else { return [closeSelf()] }
            return names.enumerated().map { index, name in
                let id: Agent.ID
                switch SessionLookup.find(name, in: context.rows, machines: context.machines, macName: context.macName,
                                          preferring: origin.id) {
                case .found(let found): id = found
                case .missing: return .problem(sender, "No session is named \(name), so nothing was closed.")
                case .ambiguous: return .problem(sender, "Several sessions are named \(name). Add @machine to pick one.")
                }
                if id == sender { return closeSelf(index: index, name: name) }
                if context.protected.contains(id) { return .problem(sender, protected) }
                guard let row = context.rows.first(where: { $0.id == id }) else { return .problem(sender, "No session is named \(name).") }
                if row.isStale { return .problem(sender, "\(row.workspace) is on a machine that isn't answering, so it wasn't closed.") }
                if !force, row.agent.state == .working || row.agent.state == .blocked {
                    let doing = row.agent.state == .working ? "is working" : "needs the user"
                    return .problem(sender, "\(row.workspace) \(doing), so it wasn't closed. Close it with --force only if the user asked for that.")
                }
                return ask(id, index: index, name: name)
            }
        }
    }

    /// The prompt that delivers an item: a session's first prompt as it was written, and a handoff
    /// introduced by who sent it, with the paths of its files on the recipient's machine.
    public static func prompt(for item: MailItem, message: String?, messagePath: String?, attachments: [String]) -> String {
        if item.kind == .prompt { return message ?? "" }
        let from = [item.senderName, "on \(item.originName)"].compactMap { $0 }.joined(separator: " ")
        var parts = ["Handoff from \(from), through Shepherdr:"]
        if let message, !message.isEmpty {
            if message.count <= 6_000 || messagePath == nil {
                parts.append(message.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if let messagePath {
                parts.append("The message is long, so it is in \(messagePath).")
            }
        }
        if !attachments.isEmpty {
            parts.append((attachments.count == 1 ? "Attached file: " : "Attached files: ") + attachments.joined(separator: ", "))
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Finds a session by the name an agent used: its Herdr agent name or its workspace's,
/// ignoring case, with `@machine` to pick among machines.
public enum SessionLookup {
    public enum Result: Equatable, Sendable {
        case found(Agent.ID)
        case missing
        case ambiguous([Agent.ID])
    }

    public static func find(_ query: String, in rows: [AgentRow], machines: [Machine], macName: String,
                            preferring machineID: String?) -> Result {
        var name = query.trimmingCharacters(in: .whitespaces)
        var onMachines: Set<String>?
        if let at = name.lastIndex(of: "@") {
            let suffix = name[name.index(after: at)...].trimmingCharacters(in: .whitespaces).lowercased()
            let names = MachineList.uniqueNames(MachineList.withLocal(machines), macName: macName)
            let matching = Set(names.filter { $0.value.lowercased() == suffix }.map(\.key))
                .union(machines.filter { $0.name.lowercased() == suffix }.map(\.id))
            if !matching.isEmpty {
                onMachines = matching
                name = String(name[..<at]).trimmingCharacters(in: .whitespaces)
            }
        }
        let wanted = name.lowercased()
        guard !wanted.isEmpty else { return .missing }
        let pool = rows.filter { onMachines?.contains($0.id.machineID) ?? true }
        // An agent's own name is more specific than its workspace's, which panes share.
        var candidates = pool.filter { $0.agent.name.lowercased() == wanted }
        if candidates.isEmpty { candidates = pool.filter { $0.workspace.lowercased() == wanted } }
        if onMachines == nil, let machineID, candidates.contains(where: { $0.id.machineID == machineID }) {
            candidates = candidates.filter { $0.id.machineID == machineID }
        }
        var seen = Set<Agent.ID>()
        let ids = candidates.map(\.id).filter { seen.insert($0).inserted }
        switch ids.count {
        case 0: return .missing
        case 1: return .found(ids[0])
        default: return .ambiguous(ids)
        }
    }
}
