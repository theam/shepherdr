import CryptoKit
import Foundation

/// What a pairing QR code carries: where the Mac listens, which certificate is its own, and a code
/// that can be used once.
public struct PairingInvite: Equatable, Sendable {
    public static let scheme = "shepherdr-remote"

    public let macName: String
    /// Addresses to try in order, such as the Mac's Tailscale addresses.
    public let hosts: [String]
    public let port: UInt16
    /// The SHA-256 of the certificate's public key: the phone trusts nothing else.
    public let fingerprint: String
    public let code: String

    public init(macName: String, hosts: [String], port: UInt16, fingerprint: String, code: String) {
        self.macName = macName
        self.hosts = hosts
        self.port = port
        self.fingerprint = fingerprint
        self.code = code
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "n", value: macName),
            URLQueryItem(name: "h", value: hosts.joined(separator: ",")),
            URLQueryItem(name: "p", value: String(port)),
            URLQueryItem(name: "f", value: fingerprint),
            URLQueryItem(name: "c", value: code)
        ]
        return components.url!
    }

    public init?(string: String) {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == Self.scheme, components.host == "pair" else { return nil }
        let items = Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        let hosts = (items["h"] ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard let name = items["n"], !hosts.isEmpty, let port = items["p"].flatMap(UInt16.init), port > 0,
              let fingerprint = items["f"], !fingerprint.isEmpty, let code = items["c"], !code.isEmpty else { return nil }
        self.init(macName: name, hosts: hosts, port: port, fingerprint: fingerprint, code: code)
    }
}

public enum RemoteCrypto {
    /// The fingerprint both sides compare: SHA-256 of the public key's external representation
    /// (an uncompressed P-256 point), base64url without padding.
    public static func fingerprint(publicKey: Data) -> String {
        base64URL(Data(SHA256.hash(data: publicKey)))
    }

    /// 32 random bytes, base64url: tokens and pairing codes.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    /// What the Mac keeps instead of a device's token.
    public static func hash(token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Takes out of Herdr's frames what a plain terminal renderer gets wrong: synchronized output
/// (mode 2026), which makes SwiftTerm copy and repaint the whole screen on every frame, and OSC 8
/// hyperlinks, which SwiftTerm stretches over the cells between where a link opens and closes.
public enum RemoteFrameFilter {
    public static func clean(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.contains(27) else { return data }
        let synchronized = Array("\u{1b}[?2026".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 27 else {
                output.append(bytes[index])
                index += 1
                continue
            }
            let end = index + synchronized.count
            if end < bytes.count, bytes[end] == UInt8(ascii: "h") || bytes[end] == UInt8(ascii: "l"),
               bytes[index..<end].elementsEqual(synchronized) {
                index = end + 1
                continue
            }
            if index + 3 < bytes.count, bytes[index + 1] == UInt8(ascii: "]"), bytes[index + 2] == UInt8(ascii: "8"),
               bytes[index + 3] == UInt8(ascii: ";") {
                index = stringEnd(bytes, from: index + 4)
                continue
            }
            output.append(bytes[index])
            index += 1
        }
        return Data(output)
    }

    /// Where what follows an escape string starts: after BEL or ST (`ESC \`).
    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> Int {
        var end = start
        while end < bytes.count {
            if bytes[end] == 7 { return end + 1 }
            if bytes[end] == 27, end + 1 < bytes.count, bytes[end + 1] == UInt8(ascii: "\\") { return end + 2 }
            end += 1
        }
        return end
    }
}
