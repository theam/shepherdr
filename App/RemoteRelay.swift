import AppKit
import CoreImage
import Foundation
import Observation
import os
import ShepherdrCore
import SystemConfiguration

/// The relay Shepherdr Remote connects to: off until you turn it on in Settings → Remote. It
/// listens on one port, pairs phones by QR code, and serves each paired phone the queue, terminals
/// and prompts, all through what this Mac already does.
@MainActor @Observable
final class RemoteRelay {
    static let enabledKey = "remoteEnabled"
    static let portKey = "remotePort"
    static let throughServeKey = "remoteThroughTailscaleServe"
    /// For testing with the iOS Simulator: listen on 127.0.0.1 without asking Tailscale for anything.
    /// Not in Settings; see DEVELOPMENT.
    static let loopbackForTestingKey = "remoteLoopbackForTesting"

    weak var model: AppModel?
    let devices = RelayDevices()
    private(set) var state: RelayServer.State = .stopped
    private(set) var fingerprint: String?
    /// Set while the pairing QR code shows.
    private(set) var invite: PairingInvite?
    /// What Tailscale Serve said the last time Shepherdr asked it to forward the relay's port.
    private(set) var serveMessage: String?
    /// The port the relay listens on at 127.0.0.1 while Tailscale Serve forwards to it. It is never
    /// the relay's own port: Tailscale holds that one on this Mac's tailnet addresses, and then
    /// Network.framework won't listen on it at any address.
    private(set) var localPort: UInt16?
    private(set) var clients: [UUID: Client] = [:] {
        didSet { if clients.isEmpty != oldValue.isEmpty { phonesChanged() } }
    }
    /// Keeps App Nap from slowing the relay down while a phone is connected.
    @ObservationIgnored private var activity: NSObjectProtocol?

    /// Whether a paired phone is connected.
    var hasPhones: Bool { clients.values.contains { $0.device != nil } }

    /// The Mac's name, as Sharing settings give it.
    static let macName: String = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ProcessInfo.processInfo.hostName

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var port: UInt16 {
        let saved = UserDefaults.standard.integer(forKey: Self.portKey)
        return (1...65535).contains(saved) ? UInt16(saved) : RemoteProtocol.defaultPort
    }
    /// Listen on 127.0.0.1 and let Tailscale Serve forward the tailnet's connections: for Macs
    /// whose firewall blocks incoming connections.
    var throughServe: Bool { UserDefaults.standard.bool(forKey: Self.throughServeKey) }
    private var loopbackForTesting: Bool { UserDefaults.standard.bool(forKey: Self.loopbackForTestingKey) }

    @ObservationIgnored private let server = RelayServer()
    @ObservationIgnored private var identity: RelayIdentity?
    @ObservationIgnored private var publishing: Task<Void, Never>?
    /// The last Tailscale Serve command, which the next one waits for.
    @ObservationIgnored private var serving: Task<Void, Never>?

    /// One connected phone.
    final class Client {
        let connection: RelayConnection
        var device: RelayDevice?
        var channels: [Int: Channel] = [:]
        var lastQueue: QueueSnapshot?
        init(connection: RelayConnection) { self.connection = connection }
    }

    /// A pane a phone streams, through a terminal connection of the relay's own.
    final class Channel {
        let pane: Agent.ID
        let store: TerminalStore
        var reported: (RemoteTerminalState, String?)?
        var watching: Task<Void, Never>?
        init(pane: Agent.ID, store: TerminalStore) {
            self.pane = pane
            self.store = store
        }
    }

    init() {
        server.onState = { [weak self] state in
            guard let self else { return }
            self.state = state
            guard case .listening(let local) = state else { return }
            if loopbackForTesting {
                offerInviteForTesting()
            } else if throughServe {
                localPort = local
                forwardThroughServe(to: local)
            }
        }
        server.onConnection = { [weak self] connection in self?.accept(connection) }
    }

    // MARK: Turning it on and off

    func start() {
        guard isEnabled else { return }
        do {
            let identity = try self.identity ?? RelayIdentity.load()
            self.identity = identity
            fingerprint = identity.fingerprint
            // Through Tailscale Serve the relay takes any free port on 127.0.0.1, and Serve forwards to
            // it once it listens.
            let local = servesThroughTailscale ? 0 : port
            server.start(identity: identity, configuration: .init(port: local, loopbackOnly: throughServe || loopbackForTesting))
            startPublishing()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        for client in clients.values { disconnect(client) }
        clients = [:]
        server.stop()
        publishing?.cancel()
        publishing = nil
        invite = nil
        devices.withdrawCode()
        state = .stopped
        localPort = nil
    }

    /// Whether Tailscale Serve forwards to the relay. Quitting Shepherdr leaves the forwarding in
    /// place, so the phone can't connect until Shepherdr opens again; turning the relay or Serve off
    /// removes it.
    private var servesThroughTailscale: Bool { throughServe && !loopbackForTesting }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if enabled {
            start()
        } else {
            stop()
            if servesThroughTailscale { stopForwarding(port: port) }
        }
    }

    func setPort(_ port: UInt16) {
        guard port != self.port else { return }
        if isEnabled && servesThroughTailscale { stopForwarding(port: self.port) }
        UserDefaults.standard.set(Int(port), forKey: Self.portKey)
        restart()
    }

    func setThroughServe(_ on: Bool) {
        guard on != throughServe else { return }
        if isEnabled && servesThroughTailscale { stopForwarding(port: port) }
        UserDefaults.standard.set(on, forKey: Self.throughServeKey)
        restart()
    }

    private func restart() {
        guard isEnabled else { return }
        stop()
        start()
    }

    /// Forgets the certificate and every paired phone, which must pair again.
    func regenerateCertificate() {
        RelayIdentity.remove()
        identity = nil
        devices.removeAll()
        restart()
    }

    // MARK: Pairing

    func beginPairing() {
        guard let fingerprint, case .listening(let listening) = state else { return }
        let code = devices.offerCode()
        let hosts = loopbackForTesting ? ["127.0.0.1"] : RelayAddress.local(includingLAN: !throughServe).map(\.description)
        // Through Tailscale Serve, phones connect to the relay's port, which Serve forwards to the local one.
        invite = PairingInvite(macName: Self.macName, hosts: hosts.isEmpty ? ["127.0.0.1"] : hosts,
                               port: servesThroughTailscale ? port : listening, fingerprint: fingerprint, code: code)
    }

    /// In the Simulator test setup, nobody clicks Pair iPhone: the invite goes to a file instead.
    private func offerInviteForTesting() {
        beginPairing()
        guard let invite else { return }
        let folder = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".shepherdr")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? invite.url.absoluteString.write(to: folder.appendingPathComponent("remote-invite.txt"), atomically: true, encoding: .utf8)
    }

    func endPairing() {
        invite = nil
        devices.withdrawCode()
    }

    var isListening: Bool { if case .listening = state { true } else { false } }
    var connectedDevices: [RelayDevice] { clients.values.compactMap(\.device) }

    static func qrImage(for invite: PairingInvite) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(invite.url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    // MARK: Tailscale Serve

    /// The Tailscale command line inside the app, or one on the PATH.
    static var tailscaleExecutable: URL? {
        ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
            .map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func serveArguments(port: UInt16, to local: UInt16) -> [String] {
        ["serve", "--bg", "--tcp", String(port), "tcp://127.0.0.1:\(local)"]
    }

    static func serveOffArguments(port: UInt16) -> [String] { ["serve", "--tcp=\(port)", "off"] }

    /// The command that forwards the tailnet's connections to the relay, once it listens.
    var serveCommand: String? {
        localPort.map { "tailscale " + Self.serveArguments(port: port, to: $0).joined(separator: " ") }
    }

    /// Asks Tailscale Serve to forward the tailnet's connections on the relay's port to it.
    private func forwardThroughServe(to local: UInt16) {
        let port = self.port
        runServe(Self.serveArguments(port: port, to: local), success: "Tailscale Serve forwards port \(port) to the relay.")
    }

    private func stopForwarding(port: UInt16) {
        runServe(Self.serveOffArguments(port: port), success: nil)
    }

    /// Runs one Tailscale Serve command after the ones before it, so that turning forwarding off
    /// and on again ends on.
    private func runServe(_ arguments: [String], success: String?) {
        let previous = serving
        serving = Task { [weak self] in
            await previous?.value
            guard let executable = Self.tailscaleExecutable else {
                self?.serveMessage = "Tailscale's command line wasn't found. Install Tailscale, or run the command below yourself."
                return
            }
            let result = await Task.detached { () -> (Int32, String) in
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { return (-1, error.localizedDescription) }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: data, as: UTF8.self))
            }.value
            let output = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
            self?.serveMessage = result.0 == 0 ? success
                : "Tailscale Serve: \(output.isEmpty ? "exit status \(result.0)" : output)"
        }
    }

    // MARK: Phones

    private func phonesChanged() {
        if hasPhones, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                             reason: "Shepherdr Remote is connected")
        } else if !hasPhones, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        model?.phonesChanged()
    }

    private func accept(_ connection: RelayConnection) {
        let client = Client(connection: connection)
        clients[connection.id] = client
        connection.onMessage = { [weak self] message in self?.handle(message, from: connection.id) }
        connection.onClose = { [weak self] in
            guard let self, let client = clients.removeValue(forKey: connection.id) else { return }
            disconnect(client)
        }
        // A phone that doesn't say who it is soon is let go.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let client = clients[connection.id], client.device == nil else { return }
            client.connection.close()
        }
    }

    private func disconnect(_ client: Client) {
        for channel in client.channels.values { close(channel) }
        client.channels = [:]
        client.connection.close()
    }

    private func handle(_ message: ClientMessage, from id: UUID) {
        guard let client = clients[id] else { return }
        let connection = client.connection
        guard let device = client.device else {
            switch message {
            case .hello(let deviceID, let token, _):
                guard let device = devices.authenticate(deviceID: deviceID, token: token, from: connection.address) else {
                    return refuse(connection, "This phone isn't paired with this Mac anymore. Pair it again from Settings → Remote.")
                }
                client.device = device
                phonesChanged()
                welcome(client)
            case .pair(let code, let name, _):
                guard let (device, token) = devices.pair(code: code, name: name, from: connection.address) else {
                    return refuse(connection, "The pairing code is wrong or expired. Show a new one in Settings → Remote.")
                }
                client.device = device
                phonesChanged()
                invite = nil
                connection.send(.paired(deviceID: device.id, token: token, macName: Self.macName))
                welcome(client)
            default:
                refuse(connection, "Say hello first.")
            }
            return
        }
        _ = device
        switch message {
        case .hello, .pair: break
        case .ping: connection.send(.pong)
        case .attach(let number, let pane, let columns, let rows): attach(number, pane: pane, columns: columns, rows: rows, for: client)
        case .takeOver(let number): client.channels[number]?.store.takeOver()
        case .detach(let number): if let channel = client.channels.removeValue(forKey: number) { close(channel) }
        case .input(let number, let bytes):
            guard let channel = client.channels[number] else { return }
            noteTyping(to: channel.pane)
            channel.store.send(.bytes(bytes))
        case .resize(let number, let columns, let rows): client.channels[number]?.store.resize(columns: columns, rows: rows)
        case .scroll(let number, let up, let lines): client.channels[number]?.store.scroll(up: up, lines: lines)
        case .prompt(let pane, let text): prompt(text, into: pane, for: client)
        case .compassRun: model?.compass.runNow()
        case .compassCancel: model?.compass.cancelRun()
        case .compassPage(let day):
            guard let model else { return }
            let page = model.remoteCompassPage(day)
            connection.send(.compassPage(day: page.day, html: page.html))
        }
    }

    private func refuse(_ connection: RelayConnection, _ reason: String) {
        relayLog.notice("Refused \(connection.address, privacy: .public): \(reason, privacy: .public)")
        connection.send(.refused(reason: reason))
        connection.close()
    }

    private func welcome(_ client: Client) {
        client.connection.send(.welcome(macName: Self.macName, version: RemoteProtocol.version))
        client.lastQueue = nil
        publish()
    }

    // MARK: Terminals

    private func attach(_ number: Int, pane: RemoteSessionID, columns: Int, rows: Int, for client: Client) {
        if let old = client.channels.removeValue(forKey: number) { close(old) }
        let id = Agent.ID(machineID: pane.machineID, terminalID: pane.terminalID)
        guard let model, let context = model.context(for: id) else {
            client.connection.send(.terminal(channel: number, state: .ended, message: "That pane isn't on any of this Mac's machines anymore."))
            return
        }
        // The phone's size wins: the Mac lets go of the pane while the phone shows it.
        model.yieldTerminal(id)
        let store = TerminalStore(target: context.target, mode: .control)
        let channel = Channel(pane: id, store: store)
        client.channels[number] = channel
        let connection = client.connection
        store.display = { frame in
            connection.send(RemoteFrame(channel: number, isFull: frame.isFull, columns: frame.columns, rows: frame.rows,
                                        bytes: RemoteFrameFilter.clean(frame.bytes)))
        }
        store.resetDisplay = { connection.send(.reset(channel: number)) }
        store.resize(columns: columns, rows: rows)
        store.open(mode: .control)
        channel.watching = Task { [weak self, weak channel] in
            while let channel, !Task.isCancelled {
                self?.report(channel, number, to: connection)
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func report(_ channel: Channel, _ number: Int, to connection: RelayConnection) {
        let store = channel.store
        let state: RemoteTerminalState = switch store.status {
        case .interactive: .control
        case .observing: store.isControlledElsewhere ? .controlledElsewhere : .observing
        case .ended: .ended
        case .failed: .failed
        default: .connecting
        }
        let message = state == .ended || state == .failed ? store.message : nil
        guard channel.reported.map({ $0.0 != state || $0.1 != message }) ?? true else { return }
        channel.reported = (state, message)
        connection.send(.terminal(channel: number, state: state, message: message))
    }

    private func close(_ channel: Channel) {
        channel.watching?.cancel()
        channel.store.display = nil
        channel.store.resetDisplay = nil
        channel.store.disconnect()
        model?.reclaimTerminal(channel.pane)
    }

    /// Typing to Compass's agent from the phone holds its runs back, as typing on the Mac does.
    private func noteTyping(to id: Agent.ID) {
        if let compass = model?.compass, compass.agentID == id { compass.noteTyping() }
    }

    private func prompt(_ text: String, into pane: RemoteSessionID, for client: Client) {
        let id = Agent.ID(machineID: pane.machineID, terminalID: pane.terminalID)
        noteTyping(to: id)
        if let channel = client.channels.values.first(where: { $0.pane == id }), channel.store.submit(prompt: text) { return }
        guard let model, let context = model.context(for: id) else {
            client.connection.send(.failure(message: "That session isn't on any of this Mac's machines anymore."))
            return
        }
        Task {
            do { try await model.cluster.prompt(paneID: context.paneID, text: text, onMachine: id.machineID) }
            catch { client.connection.send(.failure(message: error.localizedDescription)) }
        }
    }

    // MARK: The queue

    private func startPublishing() {
        publishing?.cancel()
        publishing = Task { [weak self] in
            while !Task.isCancelled {
                self?.publish()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Sends each phone the queue, when it changed since the last one it got.
    func publish() {
        let ready = clients.values.filter { $0.device != nil }
        guard !ready.isEmpty, let model else { return }
        let snapshot = model.remoteQueue()
        for client in ready where client.lastQueue != snapshot {
            client.lastQueue = snapshot
            client.connection.send(.queue(snapshot))
        }
    }
}

extension AppModel {
    /// A shell pane's name on the phone: `shell · <folder>`.
    static func shellTitle(_ directory: String?) -> String {
        guard let folder = directory.map({ ($0 as NSString).lastPathComponent }), !folder.isEmpty, folder != "/" else { return "shell" }
        return "shell · \(folder)"
    }

    /// The last two folders of a path, which is what fits on a phone.
    static func shortFolder(_ directory: String?) -> String? {
        guard let directory else { return nil }
        let parts = directory.split(separator: "/")
        return parts.count > 2 ? "…/" + parts.suffix(2).joined(separator: "/") : directory
    }

    /// The queue as the sidebar lists it, every group and project expanded, for a phone.
    func remoteQueue() -> QueueSnapshot {
        let forest = waitForest
        var rows: [QueueRow] = []
        var number = 0

        func tree(_ row: AgentRow, depth: Int, inGroup: Bool = false, inProject: Bool = false) {
            guard !forest.isNested(row.id) else { return }
            // Expanded on the phone, whatever the sidebar shows.
            let expanded = WaitForest(parents: forest.parents, children: forest.children, collapsed: [], selected: nil)
            let trees = expanded.rows(from: row)
            for tree in trees {
                number += 1
                // Only a session with others nested under it, or nested itself, is part of a tree.
                let lines = trees.count > 1
                    ? QueueTree(depth: tree.depth, guides: tree.guides, isLast: tree.isLastSibling, nested: tree.nestedCount) : nil
                rows.append(remoteRow(tree.row, number: number, depth: depth + tree.depth, tree: lines,
                                      inGroup: inGroup, inProject: inProject))
            }
        }

        func shell(_ shell: ShellRow, depth: Int, inGroup: Bool = false) {
            let id = shell.id
            rows.append(QueueRow(id: "h:\(id.machineID)/\(id.terminalID)", kind: .shell,
                                 session: .init(machineID: id.machineID, terminalID: id.terminalID), depth: depth,
                                 title: shell.pane.workspaceName, summary: Self.shortFolder(shell.pane.directory), machine: shell.machine.name,
                                 status: (status(for: id) ?? .shell).rawValue,
                                 panes: [RemotePane(pane: .init(machineID: id.machineID, terminalID: id.terminalID),
                                                    title: Self.shellTitle(shell.pane.directory), isAgent: false)],
                                 inGroup: inGroup, resources: remoteResources(for: id)))
        }

        func needingYou(_ rows: [AgentRow]) -> Int { rows.filter { status(of: $0) == .needsYou }.count }

        for slot in slots(of: queue, forest: forest) {
            switch slot {
            case .project(let run):
                rows.append(QueueRow(id: "p:\(run.id.project)", kind: .project, depth: 0, title: run.id.project,
                                     needsYou: needingYou(run.rows)))
                for row in run.rows { tree(row, depth: 1, inProject: true) }
            case .item(.session(let row)):
                tree(row, depth: 0)
            case .item(.group(let group)):
                rows.append(QueueRow(id: "g:\(group.id)", kind: .group, depth: 0, title: group.group.name,
                                     needsYou: needingYou(group.rows)))
                for member in slots(of: group, forest: forest) {
                    switch member {
                    case .project(let run):
                        rows.append(QueueRow(id: "p:\(group.id)/\(run.id.project)", kind: .project, depth: 1, title: run.id.project,
                                             needsYou: needingYou(run.rows), inGroup: true))
                        for row in run.rows { tree(row, depth: 2, inGroup: true, inProject: true) }
                    case .member(.session(let row)): tree(row, depth: 1, inGroup: true)
                    case .member(.shell(let item)): shell(item, depth: 1, inGroup: true)
                    }
                }
            }
        }
        let shells = ungroupedShells
        if !shells.isEmpty {
            rows.append(QueueRow(id: "shells", kind: .section, title: "Shells"))
            for item in shells { shell(item, depth: 0) }
        }
        let machines = cluster.machines.map {
            RemoteMachine(id: $0.id, name: $0.machine.name, connection: $0.connection.title, isOnline: $0.connection == .online)
        }
        return QueueSnapshot(macName: RemoteRelay.macName, machines: machines, rows: rows, compass: remoteCompass())
    }

    /// A session's row on the phone.
    private func remoteRow(_ row: AgentRow, number: Int?, depth: Int, tree: QueueTree? = nil,
                           inGroup: Bool = false, inProject: Bool = false) -> QueueRow {
        QueueRow(id: "s:\(row.id.machineID)/\(row.id.terminalID)", kind: .session,
                 session: .init(machineID: row.id.machineID, terminalID: row.id.terminalID),
                 number: number, depth: depth, title: row.workspace, summary: row.agent.summary,
                 agent: row.agent.kind, machine: row.machineName, status: status(of: row).rawValue, panes: remotePanes(of: row),
                 tree: tree, inGroup: inGroup, inProject: inProject, resources: remoteResources(for: row.id))
    }

    /// The panes of a session's Herdr tab, its own first.
    private func remotePanes(of row: AgentRow) -> [RemotePane] {
        let own = RemotePane(pane: .init(machineID: row.id.machineID, terminalID: row.id.terminalID),
                             title: "\(row.agent.kind) · \(row.workspace)", isAgent: true)
        guard let split = split(of: row.id) else { return [own] }
        return split.map { pane in
            if pane.terminalID == row.id.terminalID { return own }
            let id = Agent.ID(machineID: row.id.machineID, terminalID: pane.terminalID)
            if let agent = self.row(for: id) {
                return RemotePane(pane: .init(machineID: id.machineID, terminalID: id.terminalID),
                                  title: "\(agent.agent.kind) · \(agent.workspace)", isAgent: true)
            }
            let shell = cluster.machines.first { $0.id == id.machineID }?.snapshot?.panes.first { $0.terminalID == pane.terminalID }
            return RemotePane(pane: .init(machineID: id.machineID, terminalID: id.terminalID),
                              title: Self.shellTitle(shell?.directory), isAgent: false)
        }
    }

    /// The session's resources as its Resources column lists them, ten of each kind at most, and
    /// its repository.
    func remoteResources(for id: Agent.ID) -> [RemoteResource] {
        let all = resources(for: id)
        var result = SessionResource.Kind.allCases.flatMap { kind in
            SessionResources.ranked(all, kind: kind).prefix(10).map { resource in
                let status = status(of: resource)
                return RemoteResource(kind: Self.remoteKind(resource.kind), name: resource.name, title: resource.title,
                                      url: resource.url.absoluteString, state: status.state, checks: status.checks)
            }
        }
        if let repository = sessionRepositories[id] {
            result.append(RemoteResource(kind: .repository, name: repository.id, title: nil, url: "https://github.com/\(repository.id)"))
        }
        return result
    }

    private static func remoteKind(_ kind: SessionResource.Kind) -> RemoteResource.Kind {
        switch kind {
        case .pullRequest: .pullRequest
        case .issue: .issue
        case .artifact: .artifact
        case .link: .link
        }
    }

    /// Compass as its column shows it, once it is set up.
    private func remoteCompass() -> RemoteCompass? {
        guard compass.isSetUp else { return nil }
        let agent = compass.agentRow.map { row in
            QueueRow(id: "compass", kind: .session, session: .init(machineID: row.id.machineID, terminalID: row.id.terminalID),
                     title: "compass", summary: row.agent.summary, agent: row.agent.kind, machine: row.machineName,
                     status: status(of: row).rawValue, panes: [RemotePane(pane: .init(machineID: row.id.machineID, terminalID: row.id.terminalID),
                                                                           title: "\(row.agent.kind) · compass", isAgent: true)])
        }
        return RemoteCompass(activity: compass.activitySummary, needsYou: compass.activity == .needsYou,
                             isRunning: compass.openRun != nil, next: compass.nextSummary,
                             problem: compass.problem ?? compass.configProblem, hasNews: compass.hasNews,
                             pageModified: compass.pageModified, today: compass.today,
                             days: Array(compass.folder.days().prefix(30)), agent: agent)
    }

    /// A day's Compass page, for the phone. Only a day's name reaches the file system.
    func remoteCompassPage(_ day: String?) -> (day: String, html: String?) {
        let day = day ?? compass.today
        guard day.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return (day, nil) }
        return (day, try? String(contentsOf: compass.folder.page(day), encoding: .utf8))
    }
}
