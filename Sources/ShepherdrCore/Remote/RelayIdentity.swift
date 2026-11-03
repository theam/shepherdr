import CryptoKit
import Foundation
import Security
import ShepherdrRemote

/// The relay's TLS identity: a P-256 key and a self-signed certificate for it, kept in the keychain
/// so the fingerprint phones pinned stays the same across launches. The key is found by its tag and
/// the certificate by the key's hash: macOS labels a certificate with its subject, whatever label it
/// is added with.
public struct RelayIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificate: SecCertificate
    /// What a pairing code carries and phones compare: see `RemoteCrypto.fingerprint`.
    public let fingerprint: String

    static let label = "Shepherdr Relay"
    /// Each copy of the app keeps its own identity, so a test build never touches the real one's.
    static var tag: Data { Data("\(Bundle.main.bundleIdentifier ?? "com.theagilemonkeys.Shepherdr").relay".utf8) }
    static var itemLabel: String {
        let bundle = Bundle.main.bundleIdentifier ?? "com.theagilemonkeys.Shepherdr"
        return bundle == "com.theagilemonkeys.Shepherdr" ? label : "\(label) (\(bundle))"
    }

    /// The identity in the keychain, made the first time.
    /// - Parameter keychain: a keychain of its own for tests; the user's default one otherwise.
    public static func load(keychain: SecKeychain? = nil) throws -> RelayIdentity {
        if let key = try? findKey(keychain: keychain), let certificate = try? findCertificate(for: key, keychain: keychain),
           let identity = try? makeIdentity(certificate, keychain: keychain), matches(certificate, key) {
            return RelayIdentity(identity: identity, certificate: certificate, fingerprint: try fingerprint(of: certificate))
        }
        remove(keychain: keychain)
        return try create(keychain: keychain)
    }

    /// Forgets the key and the certificate: the next `load` makes new ones, and paired phones
    /// must pair again.
    /// Only this copy's own items go: every copy's certificate has the same subject, so it is
    /// told apart by its key.
    public static func remove(keychain: SecKeychain? = nil) {
        if let key = try? findKey(keychain: keychain), let hash = publicKeyHash(of: key) {
            var certificate: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrPublicKeyHash as String: hash]
            if let keychain { certificate[kSecMatchSearchList as String] = [keychain] }
            SecItemDelete(certificate as CFDictionary)
        }
        var key: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag]
        if let keychain { key[kSecMatchSearchList as String] = [keychain] }
        SecItemDelete(key as CFDictionary)
    }

    private static func create(keychain: SecKeychain?) throws -> RelayIdentity {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
            kSecAttrLabel as String: itemLabel
        ]
        if let keychain { privateAttributes[kSecUseKeychain as String] = keychain }
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateAttributes
        ]
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw RelayIdentityError.keychain(error?.takeRetainedValue().localizedDescription ?? "The key could not be made.")
        }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw RelayIdentityError.keychain("The public key could not be read.")
        }
        let tbs = SelfSignedCertificate.tbs(publicKey: point, commonName: label, now: Date())
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw RelayIdentityError.keychain(error?.takeRetainedValue().localizedDescription ?? "The certificate could not be signed.")
        }
        let der = SelfSignedCertificate.certificate(tbs: tbs, signature: signature)
        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw RelayIdentityError.keychain("The certificate could not be made.")
        }
        var add: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecValueRef as String: certificate]
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { throw RelayIdentityError.status(status) }
        let identity = try makeIdentity(certificate, keychain: keychain)
        return RelayIdentity(identity: identity, certificate: certificate, fingerprint: RemoteCrypto.fingerprint(publicKey: point))
    }

    private static func findKey(keychain: SecKeychain?) throws -> SecKey {
        var query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: tag,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecReturnRef as String: true]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() else { throw RelayIdentityError.status(status) }
        return item as! SecKey
    }

    private static func findCertificate(for key: SecKey, keychain: SecKeychain?) throws -> SecCertificate {
        guard let hash = publicKeyHash(of: key) else { throw RelayIdentityError.keychain("The key's public half could not be read.") }
        var query: [String: Any] = [kSecClass as String: kSecClassCertificate, kSecAttrPublicKeyHash as String: hash,
                                    kSecReturnRef as String: true]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let item, CFGetTypeID(item) == SecCertificateGetTypeID() else {
            throw RelayIdentityError.status(status)
        }
        return item as! SecCertificate
    }

    /// What the keychain files a certificate under (`kSecAttrPublicKeyHash`) and its private key
    /// under (`kSecAttrApplicationLabel`): the SHA-1 of the public key.
    static func publicKeyHash(of key: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(key), let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { return nil }
        return Data(Insecure.SHA1.hash(data: point))
    }

    private static func makeIdentity(_ certificate: SecCertificate, keychain: SecKeychain?) throws -> SecIdentity {
        var identity: SecIdentity?
        let status = SecIdentityCreateWithCertificate(keychain, certificate, &identity)
        guard status == errSecSuccess, let identity else { throw RelayIdentityError.status(status) }
        return identity
    }

    private static func matches(_ certificate: SecCertificate, _ key: SecKey) -> Bool {
        guard let certificateKey = SecCertificateCopyKey(certificate), let publicKey = SecKeyCopyPublicKey(key) else { return false }
        return SecKeyCopyExternalRepresentation(certificateKey, nil) as Data? == SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
    }

    public static func fingerprint(of certificate: SecCertificate) throws -> String {
        guard let key = SecCertificateCopyKey(certificate),
              let point = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw RelayIdentityError.keychain("The certificate's key could not be read.")
        }
        return RemoteCrypto.fingerprint(publicKey: point)
    }
}

public enum RelayIdentityError: Error, LocalizedError, Equatable {
    case keychain(String)
    case status(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keychain(let message): message
        case .status(let status): (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)."
        }
    }
}

/// A minimal X.509 v3 certificate for a P-256 key, signed by that same key, in DER.
enum SelfSignedCertificate {
    static func tbs(publicKey: Data, commonName: String, now: Date) -> Data {
        var serial = (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7F
        serial[0] |= 0x01
        let name = DER.sequence(DER.set(DER.sequence(DER.oid([2, 5, 4, 3]), DER.utf8(commonName))))
        let ecdsaWithSHA256 = DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2]))
        let validity = DER.sequence(DER.utcTime(now.addingTimeInterval(-86_400)), DER.utcTime(now.addingTimeInterval(10 * 365 * 86_400)))
        let spki = DER.sequence(DER.sequence(DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])),
                                DER.bitString(publicKey))
        let basicConstraints = DER.sequence(DER.oid([2, 5, 29, 19]), DER.boolean(true), DER.octetString(DER.sequence()))
        // digitalSignature only.
        let keyUsage = DER.sequence(DER.oid([2, 5, 29, 15]), DER.boolean(true), DER.octetString(DER.tlv(0x03, Data([0x07, 0x80]))))
        let serverAuth = DER.sequence(DER.oid([2, 5, 29, 37]), DER.octetString(DER.sequence(DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1]))))
        return DER.sequence(
            DER.explicit(0, DER.integer(Data([2]))),
            DER.integer(Data(serial)),
            ecdsaWithSHA256,
            name,
            validity,
            name,
            spki,
            DER.explicit(3, DER.sequence(basicConstraints, keyUsage, serverAuth))
        )
    }

    static func certificate(tbs: Data, signature: Data) -> Data {
        DER.sequence(tbs, DER.sequence(DER.oid([1, 2, 840, 10045, 4, 3, 2])), DER.bitString(signature))
    }
}

/// Just enough DER to write a certificate.
enum DER {
    static func tlv(_ tag: UInt8, _ content: Data) -> Data {
        var data = Data([tag])
        if content.count < 0x80 {
            data.append(UInt8(content.count))
        } else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 0xFF), at: 0); length >>= 8 }
            data.append(0x80 | UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(content)
        return data
    }

    static func sequence(_ items: Data...) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: Data...) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func boolean(_ value: Bool) -> Data { tlv(0x01, Data([value ? 0xFF : 0x00])) }
    static func octetString(_ content: Data) -> Data { tlv(0x04, content) }
    static func utf8(_ string: String) -> Data { tlv(0x0C, Data(string.utf8)) }
    static func bitString(_ content: Data) -> Data { tlv(0x03, Data([0]) + content) }
    static func explicit(_ number: UInt8, _ content: Data) -> Data { tlv(0xA0 | number, content) }

    /// A positive integer from its big-endian bytes.
    static func integer(_ bytes: Data) -> Data {
        var bytes = [UInt8](bytes.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, Data(bytes))
    }

    static func oid(_ components: [UInt64]) -> Data {
        var bytes = [UInt8(components[0] * 40 + components[1])]
        for component in components.dropFirst(2) {
            var value = component
            var encoded = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 { encoded.insert(UInt8(value & 0x7F) | 0x80, at: 0); value >>= 7 }
            bytes += encoded
        }
        return tlv(0x06, Data(bytes))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(formatter.string(from: date).utf8))
    }
}
