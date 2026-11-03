import Foundation
import Network
import Observation
import os
import ShepherdrRemote
import UIKit

/// The connection to Shepherdr on a Mac: one WebSocket over TLS, trusting only the certificate
/// the Mac showed when pairing. It uses Network.framework rather than URLSession, whose App
/// Transport Security refuses a self-signed certificate at a Tailscale address. It keeps the queue the Mac sends and the terminals the phone shows.
@MainActor @Observable
final class RelayClient {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var queue: QueueSnapshot?
    private(set) var mac: PairedMac?
    /// A message for a moment, such as a prompt that didn't go through.
    var notice: String?
    /// A session a link asked to open, once the queue shows it.
    var pendingSession: RemoteSessionID?
    /// The last Compass page the Mac sent.
    private(set) var compassPage: CompassPage?
    private(set) var macs: [PairedMac] = PairedMacs.load()

    @ObservationIgnored private var socket: NWConnection?
    @ObservationIgnored private var receiving: Task<Void, Never>?
    @ObservationIgnored private var retrying: Task<Void, Never>?
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var terminals: [Int: RemoteTerminal] = [:]
    @ObservationIgnored private var nextChannel = 1
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    /// Why the last address tried didn't answer, to say so.
    @ObservationIgnored private var lastProblem: String?
    /// Whether the app is in front: only then does it stay connected.
    @ObservationIgnored private var isActive = true

    init() {
        mac = macs.last
    }

    // MARK: Connecting

    func start() {
        isActive = true
        guard let mac, socket == nil else { return }
        open(.hello(mac))
    }

    /// iOS suspends the app in the background, so the connection goes, and comes back on return.
    func suspend() {
        isActive = false
        close()
        phase = .idle
    }

    func select(_ mac: PairedMac) {
        close()
        self.mac = mac
        queue = nil
        open(.hello(mac))
    }

    func forget(_ mac: PairedMac) {
        PairedMacs.remove(mac)
        macs = PairedMacs.load()
        if self.mac?.id == mac.id {
            close()
            self.mac = macs.last
            queue = nil
            phase = .idle
            if let next = self.mac { open(.hello(next)) }
        }
    }

    /// Pairs with the Mac a scanned code points at, and stays connected to it.
    func pair(with invite: PairingInvite) {
        close()
        queue = nil
        open(.pair(invite))
    }

    private enum Target {
        case hello(PairedMac)
        case pair(PairingInvite)

        var hosts: [String] {
            switch self {
            case .hello(let mac): mac.hosts
            case .pair(let invite): invite.hosts
            }
        }
        var port: UInt16 {
            switch self {
            case .hello(let mac): mac.port
            case .pair(let invite): invite.port
            }
        }
        var fingerprint: String {
            switch self {
            case .hello(let mac): mac.fingerprint
            case .pair(let invite): invite.fingerprint
            }
        }
    }

    private func open(_ target: Target) {
        retrying?.cancel()
        phase = .connecting
        lastProblem = nil
        receiving = Task { [weak self] in
            guard let self else { return }
            for host in target.hosts {
                guard !Task.isCancelled else { return }
                if await connect(to: host, target: target) { return }
            }
            guard !Task.isCancelled else { return }
            if case .connecting = phase {
                let reason = lastProblem.map { " (\($0))" } ?? ""
                phase = .failed("Shepherdr didn't answer at \(target.hosts.joined(separator: ", ")):\(target.port)\(reason). Is the relay on, and Tailscale connected on both?")
            }
            retryLater(target)
        }
    }

    /// Tries one address. Returns true once the Mac answered, after the connection ends.
    private func connect(to host: String, target: Target) async -> Bool {
        let address = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "wss://\(address):\(target.port)/v1") else { return false }
        let refusal = OSAllocatedUnfairLock<String?>(initialState: nil)
        let failure = OSAllocatedUnfairLock<NWError?>(initialState: nil)
        let socket = NWConnection(to: .url(url), using: RelaySocket.parameters(pinning: target.fingerprint, refusal: refusal))
        socket.stateUpdateHandler = { [weak socket] state in
            switch state {
            case .failed(let error), .waiting(let error):
                failure.withLock { $0 = $0 ?? error }
                socket?.cancel()
            default: break
            }
        }
        self.socket = socket
        socket.start(queue: RelaySocket.queue)
        // A Mac that takes the connection but never answers counts as not answering.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { socket.cancel() }
        }
        defer { deadline.cancel() }
        let device = UIDevice.current.name
        switch target {
        case .hello(let mac):
            guard let token = mac.token else {
                phase = .failed("This phone lost its key for \(mac.name). Pair it again.")
                socket.cancel()
                self.socket = nil
                return true
            }
            send(.hello(deviceID: mac.deviceID, token: token, version: RemoteProtocol.version))
        case .pair(let invite):
            send(.pair(code: invite.code, deviceName: device, version: RemoteProtocol.version))
        }
        var answered = false
        do {
            while !Task.isCancelled {
                let (data, opcode) = try await RelaySocket.receive(on: socket)
                if !answered {
                    answered = true
                    attempts = 0
                    deadline.cancel()
                }
                switch opcode {
                case .text:
                    if let decoded = try? JSONDecoder().decode(ServerMessage.self, from: data) {
                        handle(decoded, host: host, target: target)
                    }
                case .binary:
                    if let frame = RemoteFrame(decoding: data) { terminals[frame.channel]?.show(frame) }
                case .close:
                    throw NWError.posix(.ECONNRESET)
                default: break
                }
            }
        } catch {
            if !answered {
                let reason = failure.withLock { $0 } ?? (error as? NWError)
                lastProblem = refusal.withLock { $0 } ?? reason.map(RelaySocket.describe) ?? error.localizedDescription
                print("RelayClient: \(host):\(target.port) didn't answer: \(String(describing: reason ?? error))")
            }
            guard self.socket === socket else { return answered }
            self.socket = nil
            socket.cancel()
            heartbeat?.cancel()
            if answered, isActive, case .connected = phase {
                phase = .connecting
                retryLater(.hello(mac ?? PairedMac(deviceID: "", name: "", hosts: [host], port: target.port, fingerprint: target.fingerprint)))
            }
        }
        return answered
    }

    private func handle(_ message: ServerMessage, host: String, target: Target) {
        switch message {
        case .welcome(let name, _):
            phase = .connected
            if var mac, mac.name != name || mac.hosts.first != host {
                mac.name = name
                // The address that worked goes first next time.
                mac.hosts = [host] + mac.hosts.filter { $0 != host }
                self.mac = mac
                PairedMacs.save(macs.map { $0.id == mac.id ? mac : $0 })
                macs = PairedMacs.load()
            }
            startHeartbeat()
            // Terminals open before a reconnect stream again.
            for terminal in terminals.values { terminal.reattach() }
        case .paired(let deviceID, let token, let name):
            guard case .pair(let invite) = target else { return }
            let mac = PairedMac(deviceID: deviceID, name: name, hosts: [host] + invite.hosts.filter { $0 != host },
                                port: invite.port, fingerprint: invite.fingerprint)
            guard PairedMacs.add(mac, token: token) else {
                phase = .failed("This iPhone's keychain didn't keep the key for \(name), so the pairing can't be saved.")
                close()
                return
            }
            macs = PairedMacs.load()
            self.mac = mac
        case .refused(let reason):
            phase = .failed(reason)
            retrying?.cancel()
            close()
        case .queue(let snapshot):
            queue = snapshot
        case .terminal(let channel, let state, let message):
            terminals[channel]?.update(state, message: message)
        case .reset(let channel):
            terminals[channel]?.onReset?()
        case .failure(let message):
            notice = message
        case .compassPage(let day, let html):
            compassPage = CompassPage(day: day, html: html)
        case .pong:
            break
        }
    }

    private func retryLater(_ target: Target) {
        guard isActive else { return }
        attempts += 1
        let delay = min(15.0, pow(2.0, Double(min(attempts, 4))))
        retrying = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, isActive, socket == nil else { return }
            switch target {
            case .hello: if let mac { open(.hello(mac)) }
            case .pair: break
            }
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                self?.send(.ping)
            }
        }
    }

    private func close() {
        retrying?.cancel()
        receiving?.cancel()
        heartbeat?.cancel()
        socket?.cancel()
        socket = nil
    }

    func send(_ message: ClientMessage) {
        guard let socket, let data = try? RemoteProtocol.encoder().encode(message) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        socket.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    // MARK: Terminals

    func terminal(for pane: RemoteSessionID) -> RemoteTerminal {
        let channel = nextChannel
        nextChannel += 1
        let terminal = RemoteTerminal(channel: channel, pane: pane, client: self)
        terminals[channel] = terminal
        return terminal
    }

    func release(_ terminal: RemoteTerminal) {
        guard terminals.removeValue(forKey: terminal.channel) != nil else { return }
        send(.detach(channel: terminal.channel))
    }

    func prompt(_ text: String, into pane: RemoteSessionID) {
        send(.prompt(pane: pane, text: text))
    }

    // MARK: Compass

    /// Asks the Mac for a day's page, or today's.
    func requestCompassPage(_ day: String?) { send(.compassPage(day: day)) }
    func runCompass() { send(.compassRun) }
    func cancelCompassRun() { send(.compassCancel) }
}

/// A Compass page as the Mac sent it: nil HTML when that day has none.
struct CompassPage: Equatable {
    let day: String
    let html: String?
}

/// One pane the phone shows, on a channel of its own.
@MainActor @Observable
final class RemoteTerminal {
    let channel: Int
    let pane: RemoteSessionID
    private(set) var state: RemoteTerminalState = .connecting
    private(set) var message: String?
    @ObservationIgnored weak var client: RelayClient?
    @ObservationIgnored var onFrame: ((RemoteFrame) -> Void)?
    @ObservationIgnored var onReset: (() -> Void)?
    @ObservationIgnored private var size: (columns: Int, rows: Int)?

    init(channel: Int, pane: RemoteSessionID, client: RelayClient) {
        self.channel = channel
        self.pane = pane
        self.client = client
    }

    func show(_ frame: RemoteFrame) { onFrame?(frame) }

    func update(_ state: RemoteTerminalState, message: String?) {
        self.state = state
        self.message = message
    }

    /// The first size attaches; later ones resize.
    func resize(columns: Int, rows: Int) {
        guard columns > 1, rows > 1 else { return }
        let first = size == nil
        size = (columns, rows)
        if first {
            client?.send(.attach(channel: channel, pane: pane, columns: columns, rows: rows))
        } else {
            client?.send(.resize(channel: channel, columns: columns, rows: rows))
        }
    }

    func reattach() {
        guard let size else { return }
        state = .connecting
        client?.send(.attach(channel: channel, pane: pane, columns: size.columns, rows: size.rows))
    }

    func input(_ bytes: Data) { client?.send(.input(channel: channel, bytes: bytes)) }
    func scroll(up: Bool, lines: Int) { client?.send(.scroll(channel: channel, up: up, lines: lines)) }
    func takeOver() { client?.send(.takeOver(channel: channel)) }
}

/// The WebSocket under `RelayClient`: TLS 1.3 that trusts exactly the Mac's own certificate, the key
/// whose fingerprint the pairing code carried.
enum RelaySocket {
    static let queue = DispatchQueue(label: "com.theagilemonkeys.ShepherdrRemote.relay")

    static func parameters(pinning fingerprint: String, refusal: OSAllocatedUnfairLock<String?>) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            guard let point = publicKey(of: sec_trust_copy_ref(trust).takeRetainedValue()) else {
                refusal.withLock { $0 = "its certificate couldn't be read" }
                return complete(false)
            }
            let trusted = RemoteCrypto.fingerprint(publicKey: point) == fingerprint
            if !trusted { refusal.withLock { $0 = "it showed a certificate other than the one it paired with" } }
            complete(trusted)
        }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 8 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        return parameters
    }

    /// The certificate's public key, as its fingerprint is taken.
    static func publicKey(of trust: SecTrust) -> Data? {
        guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(leaf) else { return nil }
        return SecKeyCopyExternalRepresentation(key, nil) as Data?
    }

    /// The next whole message, or an error once the connection ends.
    static func receive(on connection: NWConnection) async throws -> (Data, NWProtocolWebSocket.Opcode) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receiveMessage { data, context, _, error in
                if let error { return continuation.resume(throwing: error) }
                guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata else { return continuation.resume(throwing: NWError.posix(.ECONNRESET)) }
                continuation.resume(returning: (data ?? Data(), metadata.opcode))
            }
        }
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: "nothing listens on that port"
        case .posix(let code) where code == .ETIMEDOUT: "the connection timed out"
        case .posix(let code) where code == .ECANCELED: "it took too long to answer"
        case .tls(let status): "TLS failed, \(status)"
        default: error.localizedDescription
        }
    }
}
