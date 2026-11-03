import AppKit
import ShepherdrCore
import SwiftUI

/// Settings → Remote: the relay Shepherdr Remote on iPhone connects to.
struct RemoteSettings: View {
    @Bindable var relay: RemoteRelay
    @State private var enabled = UserDefaults.standard.bool(forKey: RemoteRelay.enabledKey)
    @State private var portText = ""
    @State private var throughServe = UserDefaults.standard.bool(forKey: RemoteRelay.throughServeKey)
    @State private var confirmsRegenerate = false
    @State private var blocksIncoming = false

    var body: some View {
        Form {
            Section {
                Toggle("Let Shepherdr Remote connect", isOn: $enabled)
                    .onChange(of: enabled) { relay.setEnabled(enabled) }
                Text("Shepherdr Remote on your iPhone shows this Mac's queue, terminals and prompts, through Tailscale. Only phones you pair here can connect, over TLS, with this Mac's own certificate.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("", text: $portText, prompt: Text(String(RemoteProtocol.defaultPort)))
                            .frame(width: 70).multilineTextAlignment(.trailing)
                            .onSubmit(applyPort)
                        Button("Apply", action: applyPort).disabled(UInt16(portText) == nil || UInt16(portText) == relay.port)
                    }
                }
                Toggle("Through Tailscale Serve", isOn: $throughServe)
                    .onChange(of: throughServe) { relay.setThroughServe(throughServe) }
                Text(throughServe
                     ? "The relay listens on this Mac only, and Tailscale Serve forwards your tailnet's connections to it. Use this when the firewall blocks incoming connections."
                     : "The relay listens on every network but only answers Tailscale addresses.")
                    .font(.caption).foregroundStyle(.secondary)
                if blocksIncoming && !throughServe {
                    Text("This Mac's firewall blocks all incoming connections, so phones can't reach the relay directly. Turn on Through Tailscale Serve.")
                        .font(.caption).foregroundStyle(Theme.amber)
                }
                if throughServe, let command = relay.serveCommand {
                    LabeledContent("Command") {
                        Text(command).font(Theme.mono(11)).textSelection(.enabled).lineLimit(2)
                    }
                }
                if throughServe, let message = relay.serveMessage {
                    Text(message).font(.caption).foregroundStyle(message.hasPrefix("Tailscale Serve:") ? Theme.amber : .secondary)
                }
                status
            }

            Section("Paired phones") {
                if relay.devices.devices.isEmpty {
                    Text("No phones yet.").foregroundStyle(.secondary)
                }
                ForEach(relay.devices.devices) { device in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                            Text(seen(device)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if relay.connectedDevices.contains(where: { $0.id == device.id }) {
                            Text("CONNECTED").font(Theme.mono(10, .semibold)).foregroundStyle(Theme.phosphor)
                        }
                        Button("Remove") { relay.devices.remove(device.id) }
                    }
                }
                HStack {
                    Button("Pair iPhone…") { relay.beginPairing() }.disabled(!relay.isListening)
                    Spacer()
                    Button("New Certificate…") { confirmsRegenerate = true }.disabled(relay.fingerprint == nil)
                }
                if let fingerprint = relay.fingerprint {
                    Text("Certificate \(fingerprint.prefix(16))…").font(Theme.mono(10)).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            portText = String(relay.port)
            Task { blocksIncoming = await Self.firewallBlocksIncoming() }
        }
        .sheet(item: Binding(get: { relay.invite.map(InviteBox.init) }, set: { if $0 == nil { relay.endPairing() } })) { box in
            PairingSheet(invite: box.invite, relay: relay)
        }
        .confirmationDialog("Make a new certificate?", isPresented: $confirmsRegenerate) {
            Button("New Certificate", role: .destructive) { relay.regenerateCertificate() }
        } message: {
            Text("Every paired phone is forgotten and must pair again.")
        }
    }

    @ViewBuilder private var status: some View {
        switch relay.state {
        case .stopped: Text("Off.").font(.caption).foregroundStyle(.secondary)
        case .starting: Text("Starting…").font(.caption).foregroundStyle(.secondary)
        case .listening(let port):
            let hosts = RelayAddress.local(includingLAN: false).map(\.description)
            Text(hosts.isEmpty ? "Listening on port \(port). Tailscale isn't connected on this Mac."
                 : "Listening on port \(port) · Tailscale \(hosts.joined(separator: ", "))")
                .font(.caption).foregroundStyle(hosts.isEmpty ? Theme.amber : Theme.phosphor)
        case .failed(let message): Text(message).font(.caption).foregroundStyle(Theme.amber)
        }
    }

    private func applyPort() {
        guard let port = UInt16(portText), port > 0 else { return }
        relay.setPort(port)
    }

    private func seen(_ device: RelayDevice) -> String {
        let paired = "Paired \(device.paired.formatted(date: .abbreviated, time: .omitted))"
        guard let last = device.lastSeen else { return paired }
        return paired + " · last seen \(last.formatted(.relative(presentation: .named)))"
    }

    /// Whether the application firewall blocks every incoming connection, as some companies set it.
    static func firewallBlocksIncoming() async -> Bool {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
            process.arguments = ["--getblockall"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("blocking all")
        }.value
    }
}

private struct InviteBox: Identifiable {
    let invite: PairingInvite
    var id: String { invite.code }
}

/// The QR code a phone scans to pair, with the link to paste instead.
private struct PairingSheet: View {
    let invite: PairingInvite
    let relay: RemoteRelay
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair iPhone").font(Theme.mono(16, .semibold))
            Text("In Shepherdr Remote, tap Pair and scan this code. It works once, for five minutes.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let image = RemoteRelay.qrImage(for: invite) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 240, height: 240)
                    .padding(12).background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(invite.hosts.map { "\($0):\(invite.port)" }.joined(separator: " · "))
                .font(Theme.mono(11)).foregroundStyle(.secondary)
            HStack {
                Button(copied ? "Copied" : "Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(invite.url.absoluteString, forType: .string)
                    copied = true
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onChange(of: relay.invite) { if relay.invite == nil { dismiss() } }
    }
}
