import Foundation
import Security

/// A Mac this phone paired with: where to find it and which certificate is its own. Its token
/// lives in the keychain, on this device only.
struct PairedMac: Codable, Equatable, Identifiable {
    let deviceID: String
    var name: String
    var hosts: [String]
    var port: UInt16
    let fingerprint: String
    var id: String { deviceID }

    var token: String? { Keychain.read(account: deviceID) }
}

enum PairedMacs {
    private static let key = "pairedMacs"

    static func load() -> [PairedMac] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PairedMac].self, from: data)) ?? []
    }

    static func save(_ macs: [PairedMac]) {
        if let data = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Keeps a paired Mac; false when the keychain refused its token, so it can't be kept.
    @discardableResult
    static func add(_ mac: PairedMac, token: String) -> Bool {
        guard Keychain.write(token, account: mac.deviceID) else { return false }
        save(load().filter { $0.deviceID != mac.deviceID && $0.fingerprint != mac.fingerprint } + [mac])
        return true
    }

    static func remove(_ mac: PairedMac) {
        Keychain.delete(account: mac.deviceID)
        save(load().filter { $0.deviceID != mac.deviceID })
    }
}

enum Keychain {
    private static let service = "com.theagilemonkeys.ShepherdrRemote.token"

    @discardableResult
    static func write(_ value: String, account: String) -> Bool {
        delete(account: account)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}
