import Foundation
import Security
import Testing
@testable import ShepherdrCore

struct RemoteProtocolTests {
    @Test func messagesRoundTrip() throws {
        let pane = RemoteSessionID(machineID: "remote:buildbox", terminalID: "term_1")
        let messages: [ClientMessage] = [
            .hello(deviceID: "d", token: "t", version: 1), .pair(code: "c", deviceName: "Phone", version: 1),
            .attach(channel: 3, pane: pane, columns: 52, rows: 30), .takeOver(channel: 3), .detach(channel: 3),
            .input(channel: 3, bytes: Data([27, 0, 255])), .resize(channel: 3, columns: 60, rows: 20), .scroll(channel: 3, up: true, lines: 10),
            .prompt(pane: pane, text: "fix the flaky test\nplease"), .compassRun, .compassCancel,
            .compassPage(day: nil), .compassPage(day: "2026-11-02"), .ping
        ]
        for message in messages {
            let data = try RemoteProtocol.encoder().encode(message)
            #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == message)
        }
        let row = QueueRow(id: "s:1", kind: .session, session: pane, number: 1, depth: 2, title: "fix-login", status: "needsYou",
                           panes: [RemotePane(pane: pane, title: "claude", isAgent: true)],
                           tree: QueueTree(depth: 1, guides: [true], isLast: false, nested: 2), inGroup: true, inProject: true,
                           resources: [RemoteResource(kind: .pullRequest, name: "theam/shepherdr#12", title: "Fix login",
                                                      url: "https://github.com/theam/shepherdr/pull/12", state: "open", checks: "passed")])
        let compass = RemoteCompass(activity: "✓ updated 09:00", needsYou: false, isRunning: false, next: "next run 14:00",
                                    problem: nil, hasNews: true, pageModified: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                    today: "2026-11-02", days: ["2026-11-02", "2026-11-01"], agent: row)
        let server: [ServerMessage] = [
            .welcome(macName: "Studio", version: 1), .paired(deviceID: "d", token: "t", macName: "Studio"),
            .refused(reason: "No"), .queue(QueueSnapshot(macName: "Studio", machines: [], rows: [row], compass: compass)),
            .terminal(channel: 3, state: .controlledElsewhere, message: nil), .reset(channel: 3), .failure(message: "x"),
            .compassPage(day: "2026-11-02", html: "<h1>Today</h1>"), .compassPage(day: "2026-10-30", html: nil), .pong
        ]
        for message in server {
            let data = try RemoteProtocol.encoder().encode(message)
            #expect(try JSONDecoder().decode(ServerMessage.self, from: data) == message)
        }
    }

    @Test func rowsFromAMacWithoutLinesOrResourcesStillRead() throws {
        let json = #"{"id":"s:1","kind":"session","title":"fix-login","depth":1,"needsYou":0,"panes":[]}"#
        let row = try JSONDecoder().decode(QueueRow.self, from: Data(json.utf8))
        #expect(row.title == "fix-login" && row.depth == 1 && !row.inGroup && !row.inProject && row.resources.isEmpty && row.tree == nil)
    }

    @Test func searchFindsSessionsByEveryWordTheirResourcesAndMachine() {
        let pane = RemoteSessionID(machineID: "local", terminalID: "t1")
        let other = RemoteSessionID(machineID: "remote:box", terminalID: "t2")
        let rows = [
            QueueRow(id: "g:1", kind: .group, title: "Release"),
            QueueRow(id: "s:1", kind: .session, session: pane, number: 1, depth: 1, title: "fix-login", summary: "Wants to edit session.ts",
                     agent: "claude", machine: "Local", status: "needsYou",
                     resources: [RemoteResource(kind: .pullRequest, name: "theam/shepherdr#29", title: "Carry out each letter once",
                                                url: "https://github.com/theam/shepherdr/pull/29")]),
            QueueRow(id: "s:2", kind: .session, session: other, number: 2, title: "api-tests", agent: "codex", machine: "buildbox",
                     status: "working")
        ]
        #expect(QueueSearch.rows(rows, matching: "").count == 3)
        #expect(QueueSearch.rows(rows, matching: "login claude").map(\.id) == ["s:1"])
        #expect(QueueSearch.rows(rows, matching: "#29").map(\.id) == ["s:1"])
        #expect(QueueSearch.rows(rows, matching: "letter").map(\.id) == ["s:1"])
        #expect(QueueSearch.rows(rows, matching: "needs you").map(\.id) == ["s:1"])
        #expect(QueueSearch.rows(rows, matching: "@build").map(\.id) == ["s:2"])
        #expect(QueueSearch.rows(rows, matching: "release").isEmpty)
        #expect(QueueSearch.rows(rows, matching: "login codex").isEmpty)
    }

    @Test func framesRoundTripThroughTheirBinaryHeader() throws {
        let frame = RemoteFrame(channel: 70_000, isFull: true, columns: 300, rows: 41, bytes: Data("\u{1b}[2Jhola".utf8))
        let encoded = frame.encoded()
        #expect(encoded.count == 9 + frame.bytes.count)
        #expect(RemoteFrame(decoding: encoded) == frame)
        #expect(RemoteFrame(decoding: Data([0, 1])) == nil)
        // A slice that doesn't start at index 0 decodes the same.
        let sliced = (Data([9]) + encoded).dropFirst()
        #expect(RemoteFrame(decoding: sliced) == frame)
    }

    @Test func invitesRoundTripThroughTheirLink() throws {
        let invite = PairingInvite(macName: "Javier’s MacBook Pro", hosts: ["100.101.102.103", "192.168.1.20"], port: 1337,
                                   fingerprint: "abc-_123", code: "c0de")
        #expect(PairingInvite(string: invite.url.absoluteString) == invite)
        #expect(PairingInvite(string: "  \(invite.url.absoluteString)\n") == invite)
        #expect(PairingInvite(string: "https://example.com/pair?h=a&p=1&f=x&c=y&n=z") == nil)
        #expect(PairingInvite(string: "shepherdr-remote://pair?n=x&h=&p=1337&f=x&c=y") == nil)
        #expect(PairingInvite(string: "shepherdr-remote://pair?n=x&h=a&p=0&f=x&c=y") == nil)
    }

    @Test func framesLoseSynchronizedOutputAndLinksOnly() {
        let frame = Data("\u{1b}[?2026hA\u{1b}]8;;https://x.dev\u{7}link\u{1b}]8;;\u{1b}\\B\u{1b}[31mC\u{1b}[?2026l".utf8)
        #expect(RemoteFrameFilter.clean(frame) == Data("AlinkB\u{1b}[31mC".utf8))
        #expect(RemoteFrameFilter.clean(Data("plain".utf8)) == Data("plain".utf8))
    }

    @Test func tokensAreRandomAndHashedConsistently() {
        let a = RemoteCrypto.randomToken(), b = RemoteCrypto.randomToken()
        #expect(a != b)
        #expect(a.count == 43)
        #expect(!a.contains("=") && !a.contains("+") && !a.contains("/"))
        #expect(RemoteCrypto.hash(token: a) == RemoteCrypto.hash(token: a))
        #expect(RemoteCrypto.hash(token: a).count == 64)
    }
}

struct RelayAddressTests {
    @Test func tailscaleRangesAndLoopback() throws {
        #expect(try #require(RelayAddress("100.64.0.1")).isTailscale)
        #expect(try #require(RelayAddress("100.127.255.254")).isTailscale)
        #expect(try #require(RelayAddress("100.128.0.1")).isTailscale == false)
        #expect(try #require(RelayAddress("100.63.255.255")).isTailscale == false)
        #expect(try #require(RelayAddress("192.168.1.10")).isTailscale == false)
        #expect(try #require(RelayAddress("fd7a:115c:a1e0::1")).isTailscale)
        #expect(try #require(RelayAddress("fd7a:115c:a1e1::1")).isTailscale == false)
        #expect(try #require(RelayAddress("127.0.0.1")).isLoopback)
        #expect(try #require(RelayAddress("::1")).isLoopback)
        // IPv4 mapped into IPv6 is still Tailscale.
        let mapped = try #require(RelayAddress(bytes: [UInt8](repeating: 0, count: 10) + [0xFF, 0xFF, 100, 100, 1, 2]))
        #expect(mapped.isTailscale)
        #expect(mapped.description == "100.100.1.2")
    }
}

@MainActor
struct RelayDevicesTests {
    func defaults() -> UserDefaults {
        let suite = "RelayDevicesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func pairingUsesTheCodeOnceAndKeepsOnlyAHash() throws {
        let store = defaults()
        let devices = RelayDevices(defaults: store)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let code = devices.offerCode(now: now)
        let (device, token) = try #require(devices.pair(code: code, name: "iPhone", from: "100.64.0.2", now: now))
        #expect(device.tokenHash == RemoteCrypto.hash(token: token))
        #expect(devices.pair(code: code, name: "Other", from: "100.64.0.3", now: now) == nil)
        #expect(devices.authenticate(deviceID: device.id, token: token, from: "100.64.0.2", now: now)?.id == device.id)
        #expect(devices.authenticate(deviceID: device.id, token: "wrong", from: "100.64.0.2", now: now) == nil)
        // Saved without the token.
        let saved = try #require(store.data(forKey: RelayDevices.key))
        #expect(!String(decoding: saved, as: UTF8.self).contains(token))
        #expect(RelayDevices(defaults: store).devices == devices.devices)
        devices.remove(device.id)
        #expect(devices.authenticate(deviceID: device.id, token: token, from: "100.64.0.2", now: now) == nil)
    }

    @Test func codesExpireAndGuessingIsSlowedDown() {
        let devices = RelayDevices(defaults: defaults())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let code = devices.offerCode(now: now)
        #expect(devices.pair(code: code, name: "Late", from: "a", now: now.addingTimeInterval(RelayDevices.codeLifetime + 1)) == nil)
        let fresh = devices.offerCode(now: now)
        for _ in 0..<5 { _ = devices.pair(code: "guess", name: "x", from: "b", now: now) }
        // Even the right code waits once an address has failed five times.
        #expect(devices.pair(code: fresh, name: "x", from: "b", now: now) == nil)
        let later = now.addingTimeInterval(301)
        let again = devices.offerCode(now: later)
        #expect(devices.pair(code: again, name: "x", from: "b", now: later) != nil)
    }
}

struct RelayCertificateTests {
    @Test func derEncodesLengthsIntegersAndObjectIDs() {
        #expect(DER.tlv(0x04, Data(repeating: 1, count: 3)) == Data([0x04, 3, 1, 1, 1]))
        #expect(DER.tlv(0x04, Data(repeating: 1, count: 200)).prefix(3) == Data([0x04, 0x81, 200]))
        #expect(DER.tlv(0x04, Data(repeating: 1, count: 300)).prefix(4) == Data([0x04, 0x82, 0x01, 0x2C]))
        #expect(DER.integer(Data([0x80])) == Data([0x02, 2, 0, 0x80]))
        #expect(DER.integer(Data([0, 0, 5])) == Data([0x02, 1, 5]))
        // ecdsa-with-SHA256
        #expect(DER.oid([1, 2, 840, 10045, 4, 3, 2]) == Data([0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
    }

    @Test func aSignedCertificateParsesAndCarriesItsKey() throws {
        let key = try #require(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(key))
        let point = try #require(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let tbs = SelfSignedCertificate.tbs(publicKey: point, commonName: "Shepherdr Relay", now: Date())
        let signature = try #require(SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, nil) as Data?)
        let certificate = try #require(SecCertificateCreateWithData(nil, SelfSignedCertificate.certificate(tbs: tbs, signature: signature) as CFData))
        #expect(SecCertificateCopySubjectSummary(certificate) as String? == "Shepherdr Relay")
        #expect(try RelayIdentity.fingerprint(of: certificate) == RemoteCrypto.fingerprint(publicKey: point))
        // It verifies as self-signed: its own key checks its signature.
        let policy = SecPolicyCreateBasicX509()
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, policy, &trust) == errSecSuccess)
        SecTrustSetAnchorCertificates(try #require(trust), [certificate] as CFArray)
        #expect(SecTrustEvaluateWithError(try #require(trust), nil))
    }
}

/// A real TLS WebSocket on loopback, with the identity in a keychain of its own.
@MainActor
struct RelayServerTests {
    @Test(.timeLimit(.minutes(1))) func aPinnedClientConnectsAndTalks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keychain = try TemporaryKeychain(path: folder.appendingPathComponent("test.keychain").path)
        defer { keychain.delete() }
        let identity = try RelayIdentity.load(keychain: keychain.keychain)
        // Loading again finds the same identity.
        #expect(try RelayIdentity.load(keychain: keychain.keychain).fingerprint == identity.fingerprint)

        let server = RelayServer()
        let listening = AsyncStream<UInt16>.makeStream()
        server.onState = { state in
            switch state {
            case .listening(let port): listening.continuation.yield(port)
            case .failed: listening.continuation.yield(0)
            default: break
            }
        }
        server.onConnection = { connection in
            connection.onMessage = { message in
                if case .hello(let device, _, _) = message { connection.send(.welcome(macName: device, version: RemoteProtocol.version)) }
            }
        }
        server.start(identity: identity, configuration: .init(port: 0, loopbackOnly: true))
        defer { server.stop() }
        var iterator = listening.stream.makeAsyncIterator()
        let port = try #require(await iterator.next())
        try #require(port != 0, "The relay didn't start listening.")

        let pinning = PinningDelegate(fingerprint: identity.fingerprint)
        let session = URLSession(configuration: .ephemeral, delegate: pinning, delegateQueue: nil)
        let task = session.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/v1")!)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }
        // Control messages are text; the relay ignores binary ones from phones.
        let hello = try RemoteProtocol.encoder().encode(ClientMessage.hello(deviceID: "probe", token: "t", version: 1))
        try await task.send(.string(String(decoding: hello, as: UTF8.self)))
        let reply = try await task.receive()
        guard case .string(let text) = reply else { throw CancellationError() }
        #expect(try JSONDecoder().decode(ServerMessage.self, from: Data(text.utf8)) == .welcome(macName: "probe", version: RemoteProtocol.version))

        // A client pinning another fingerprint never gets through.
        let wrong = URLSession(configuration: .ephemeral, delegate: PinningDelegate(fingerprint: "other"), delegateQueue: nil)
        let refused = wrong.webSocketTask(with: URL(string: "wss://127.0.0.1:\(port)/v1")!)
        refused.resume()
        await #expect(throws: (any Error).self) { try await refused.receive() }
    }
}

/// Trusts exactly one key, as Shepherdr Remote does.
final class PinningDelegate: NSObject, URLSessionDelegate, Sendable {
    let fingerprint: String
    init(fingerprint: String) { self.fingerprint = fingerprint }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let key = SecCertificateCopyKey(leaf),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              RemoteCrypto.fingerprint(publicKey: point) == fingerprint else { return (.cancelAuthenticationChallenge, nil) }
        return (.useCredential, URLCredential(trust: trust))
    }
}

/// A file keychain that tests make and throw away, so they never touch the user's keychain.
struct TemporaryKeychain {
    let keychain: SecKeychain
    let path: String

    init(path: String) throws {
        var keychain: SecKeychain?
        let password = "relay-tests"
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else { throw RelayIdentityError.status(status) }
        self.keychain = keychain
        self.path = path
    }

    func delete() { SecKeychainDelete(keychain) }
}
