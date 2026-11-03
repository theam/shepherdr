import Foundation
import Network
import os
import Security
import ShepherdrRemote

/// What the relay does with each connection, for `log stream --predicate 'category == "relay"'`.
public let relayLog = Logger(subsystem: "com.theagilemonkeys.Shepherdr", category: "relay")

/// Listens for Shepherdr Remote: WebSocket over TLS 1.3 on one port, accepting only the addresses
/// it is told to. It knows nothing of pairing or sessions; `RelayConnection` hands their messages on.
public final class RelayServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    public struct Configuration: Equatable, Sendable {
        public var port: UInt16
        /// Listen on 127.0.0.1 only, for Tailscale Serve to forward the tailnet's connections to:
        /// a Mac whose firewall blocks incoming connections can still be reached that way.
        public var loopbackOnly: Bool
        /// Accept Tailscale and loopback addresses only, rather than any address.
        public var tailscaleOnly: Bool

        public init(port: UInt16, loopbackOnly: Bool, tailscaleOnly: Bool = true) {
            self.port = port
            self.loopbackOnly = loopbackOnly
            self.tailscaleOnly = tailscaleOnly
        }
    }

    private let queue = DispatchQueue(label: "com.theagilemonkeys.Shepherdr.relay")
    private var listener: NWListener?
    private var configuration: Configuration?
    /// Told about every change, on the main actor.
    public var onState: (@MainActor @Sendable (State) -> Void)?
    /// Told about every connection that got past the address check, on the main actor.
    public var onConnection: (@MainActor @Sendable (RelayConnection) -> Void)?

    public init() {}

    public func start(identity: RelayIdentity, configuration: Configuration) {
        stop()
        self.configuration = configuration
        report(.starting)
        // Port 0 lets the system choose, for tests.
        guard let port = configuration.port == 0 ? .any : NWEndpoint.Port(rawValue: configuration.port) else {
            report(.failed("\(configuration.port) is not a port."))
            return
        }
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            report(.failed("The relay's certificate could not be used."))
            return
        }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        let parameters = NWParameters(tls: tls, tcp: tcp)
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        websocket.maximumMessageSize = 4 * 1024 * 1024
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.allowLocalEndpointReuse = true
        if configuration.loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        }
        do {
            let listener = configuration.loopbackOnly ? try NWListener(using: parameters) : try NWListener(using: parameters, on: port)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready: self?.report(.listening(port: listener?.port?.rawValue ?? configuration.port))
                case .failed(let error): self?.report(.failed(Self.describe(error, port: configuration.port)))
                case .waiting(let error): self?.report(.failed(Self.describe(error, port: configuration.port)))
                case .cancelled: self?.report(.stopped)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        } catch {
            report(.failed(Self.describe(error, port: configuration.port)))
        }
    }

    public func stop() {
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let address = RelayAddress(endpoint: connection.endpoint)
        guard let configuration, let address,
              configuration.loopbackOnly ? address.isLoopback : !configuration.tailscaleOnly || address.isTailscale || address.isLoopback else {
            relayLog.notice("Refused a connection from \(String(describing: connection.endpoint), privacy: .public)")
            connection.cancel()
            return
        }
        relayLog.info("Connection from \(address.description, privacy: .public)")
        let relayConnection = RelayConnection(connection: connection, address: address.description, queue: queue)
        let onConnection = onConnection
        Task { @MainActor in
            onConnection?(relayConnection)
            relayConnection.start()
        }
    }

    private func report(_ state: State) {
        let onState = onState
        Task { @MainActor in onState?(state) }
    }

    private static func describe(_ error: Error, port: UInt16) -> String {
        if case NWError.posix(let code) = error, code == .EADDRINUSE {
            return "Port \(port) is already in use by another program. Choose another one."
        }
        if case NWError.posix(let code) = error, code == .EACCES {
            return "macOS doesn't let Shepherdr listen on port \(port). Choose another one."
        }
        return error.localizedDescription
    }
}

/// One phone's WebSocket. Messages arrive and leave on the main actor's side through callbacks.
public final class RelayConnection: @unchecked Sendable, Identifiable {
    public let id = UUID()
    /// The phone's address, such as its Tailscale address.
    public let address: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let encoder = RemoteProtocol.encoder()
    private let decoder = JSONDecoder()
    /// Bytes handed to the network and not yet sent. Past the limit the phone can't keep up, and
    /// the connection is closed rather than queueing without end.
    private var pending = 0
    private static let pendingLimit = 16 * 1024 * 1024

    public var onMessage: (@MainActor @Sendable (ClientMessage) -> Void)?
    public var onClose: (@MainActor @Sendable () -> Void)?

    init(connection: NWConnection, address: String, queue: DispatchQueue) {
        self.connection = connection
        self.address = address
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self, address] state in
            switch state {
            case .ready: relayLog.info("Connection from \(address, privacy: .public) is open")
            case .waiting(let error): relayLog.notice("Connection from \(address, privacy: .public) waits: \(String(describing: error), privacy: .public)")
            case .failed(let error):
                relayLog.notice("Connection from \(address, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self?.closed()
            case .cancelled: self?.closed()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public func send(_ message: ServerMessage) {
        guard let data = try? encoder.encode(message) else { return }
        send(data, opcode: .text)
    }

    public func send(_ frame: RemoteFrame) {
        send(frame.encoded(), opcode: .binary)
    }

    /// Sends what is queued, then closes.
    public func close() {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(content: nil, contentContext: context, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode) {
        queue.async { [self] in
            guard pending + data.count <= Self.pendingLimit else {
                connection.cancel()
                return
            }
            pending += data.count
            let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
            let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { [weak self] _ in
                self?.pending -= data.count
            })
        }
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { connection.cancel(); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                if let data, let message = try? decoder.decode(ClientMessage.self, from: data) {
                    let onMessage = onMessage
                    Task { @MainActor in onMessage?(message) }
                } else {
                    relayLog.notice("A message from \(self.address, privacy: .public) couldn't be read (\(data?.count ?? 0) bytes)")
                }
            case .close?:
                connection.cancel()
                return
            default: break
            }
            receive()
        }
    }

    private var didClose = false

    private func closed() {
        guard !didClose else { return }
        didClose = true
        let onClose = onClose
        Task { @MainActor in onClose?() }
    }
}

/// A peer's IP address, and whether it belongs to Tailscale.
public struct RelayAddress: Equatable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        // An IPv4 address mapped into IPv6 is the IPv4 address.
        if bytes.count == 16, bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            self.bytes = Array(bytes[12...])
        } else {
            self.bytes = bytes
        }
    }

    public init?(_ string: String) {
        if let v4 = IPv4Address(string) { self.init(bytes: [UInt8](v4.rawValue)) }
        else if let v6 = IPv6Address(string) { self.init(bytes: [UInt8](v6.rawValue)) }
        else { return nil }
    }

    init?(endpoint: NWEndpoint) {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let address): self.init(bytes: [UInt8](address.rawValue))
        case .ipv6(let address): self.init(bytes: [UInt8](address.rawValue))
        default: return nil
        }
    }

    /// Tailscale's ranges: 100.64.0.0/10 and fd7a:115c:a1e0::/48.
    public var isTailscale: Bool {
        if bytes.count == 4 { return bytes[0] == 100 && bytes[1] & 0xC0 == 64 }
        return bytes.starts(with: [0xFD, 0x7A, 0x11, 0x5C, 0xA1, 0xE0])
    }

    public var isLoopback: Bool {
        bytes.count == 4 ? bytes[0] == 127 : bytes == [UInt8](repeating: 0, count: 15) + [1]
    }

    public var description: String {
        if bytes.count == 4 { return bytes.map(String.init).joined(separator: ".") }
        return IPv6Address(Data(bytes)).map { "\($0)" } ?? "?"
    }

    /// This Mac's own addresses, Tailscale's first: where a phone can find the relay.
    public static func local(includingLAN: Bool) -> [RelayAddress] {
        var addresses: [RelayAddress] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [] }
        defer { freeifaddrs(first) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let socket = current.pointee.ifa_addr, current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            if socket.pointee.sa_family == UInt8(AF_INET) {
                var address = socket.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let bytes = withUnsafeBytes(of: &address) { [UInt8]($0) }
                if let relay = RelayAddress(bytes: bytes) { addresses.append(relay) }
            }
        }
        let tailscale = addresses.filter(\.isTailscale)
        let lan = includingLAN ? addresses.filter { !$0.isTailscale && !$0.isLoopback && !$0.isLinkLocal } : []
        return tailscale + lan
    }

    var isLinkLocal: Bool { bytes.count == 4 && bytes[0] == 169 && bytes[1] == 254 }
}
