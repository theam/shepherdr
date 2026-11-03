import Foundation
import Observation
import ShepherdrRemote

/// A phone allowed to use the relay. The Mac keeps a hash of its token, never the token.
public struct RelayDevice: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public let tokenHash: String
    public let paired: Date
    public var lastSeen: Date?
}

/// The paired phones, kept in user defaults, and the pairing code on offer, kept in memory.
@MainActor @Observable
public final class RelayDevices {
    public private(set) var devices: [RelayDevice] = []
    /// The code a pairing QR shows, until it is used or expires.
    public private(set) var code: (value: String, expires: Date)?
    /// Recent failed attempts by address, to slow down guessing.
    @ObservationIgnored private var failures: [String: [Date]] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    static let key = "remoteDevices"
    public static let codeLifetime: TimeInterval = 300

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([RelayDevice].self, from: data) {
            devices = saved
        }
    }

    /// A new one-time code, replacing any earlier one.
    public func offerCode(now: Date = Date()) -> String {
        let value = RemoteCrypto.randomToken()
        code = (value, now.addingTimeInterval(Self.codeLifetime))
        return value
    }

    public func withdrawCode() { code = nil }

    /// Pairs a phone whose code matches the one on offer, using it up. Returns the device and the
    /// token to hand the phone.
    public func pair(code offered: String, name: String, from address: String, now: Date = Date()) -> (RelayDevice, String)? {
        guard !isThrottled(address, now: now) else { return nil }
        guard let code, code.expires > now, Self.same(code.value, offered) else {
            fail(address, now: now)
            return nil
        }
        self.code = nil
        let token = RemoteCrypto.randomToken()
        let device = RelayDevice(id: UUID().uuidString, name: String(name.prefix(80)), tokenHash: RemoteCrypto.hash(token: token),
                                 paired: now, lastSeen: now)
        devices.append(device)
        save()
        return (device, token)
    }

    /// The paired device a hello comes from, when its token is right.
    public func authenticate(deviceID: String, token: String, from address: String, now: Date = Date()) -> RelayDevice? {
        guard !isThrottled(address, now: now) else { return nil }
        guard let index = devices.firstIndex(where: { $0.id == deviceID }),
              Self.same(devices[index].tokenHash, RemoteCrypto.hash(token: token)) else {
            fail(address, now: now)
            return nil
        }
        devices[index].lastSeen = now
        save()
        return devices[index]
    }

    public func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        save()
    }

    public func removeAll() {
        devices = []
        save()
    }

    /// Five failures in five minutes from one address wait out the rest of those five minutes.
    func isThrottled(_ address: String, now: Date) -> Bool {
        let recent = (failures[address] ?? []).filter { now.timeIntervalSince($0) < 300 }
        failures[address] = recent
        return recent.count >= 5
    }

    private func fail(_ address: String, now: Date) {
        failures[address, default: []].append(now)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(devices) { defaults.set(data, forKey: Self.key) }
    }

    /// Compares without stopping at the first difference.
    static func same(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
