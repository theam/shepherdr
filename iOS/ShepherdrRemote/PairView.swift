import ShepherdrRemote
import SwiftUI
import VisionKit

/// Pairing: scan the code Settings → Remote shows on the Mac, or paste its link.
struct PairView: View {
    @Bindable var client: RelayClient
    var dismissible = false
    @Environment(\.dismiss) private var dismiss
    @State private var scanning = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer()
            Text("SHEPHERDR").font(Theme.mono(13, .semibold)).foregroundStyle(Theme.faint).tracking(3)
            Text("Remote").font(Theme.mono(40, .medium)).foregroundStyle(Theme.phosphor)
            Text("Your Mac's queue, terminals and prompts, through Tailscale. On the Mac, open Shepherdr → Settings → Remote, turn it on and choose Pair iPhone.")
                .font(.callout).foregroundStyle(Theme.dim)
            if case .connecting = client.phase {
                HStack(spacing: 10) { ProgressView(); Text("Pairing…").font(Theme.mono(13)).foregroundStyle(Theme.dim) }
            }
            if case .failed(let message) = client.phase {
                Text(message).font(.callout).foregroundStyle(Theme.amber)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Theme.amber) }
            VStack(spacing: 12) {
                Button { scanning = true } label: {
                    Label("Scan Pairing Code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!DataScannerViewController.isSupported)
                Button { paste() } label: {
                    Label("Paste Pairing Link", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            Spacer()
        }
        .padding(28)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $scanning) {
            ScannerView { text in
                scanning = false
                use(text)
            }
            .ignoresSafeArea()
        }
        .onChange(of: client.mac?.id) { if dismissible, client.mac != nil, client.phase == .connected { dismiss() } }
        .onChange(of: client.phase) { if dismissible, client.phase == .connected { dismiss() } }
    }

    private func paste() {
        guard let text = UIPasteboard.general.string else {
            problem = "The clipboard is empty. On the Mac, choose Copy Link in the pairing window."
            return
        }
        use(text)
    }

    private func use(_ text: String) {
        guard let invite = PairingInvite(string: text) else {
            problem = "That isn't a Shepherdr pairing code."
            return
        }
        problem = nil
        client.pair(with: invite)
    }
}

/// The camera, looking for a QR code.
struct ScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void) { self.found = found }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in items {
                guard !done, case .barcode(let code) = item, let text = code.payloadStringValue,
                      text.hasPrefix(PairingInvite.scheme) else { continue }
                done = true
                scanner.stopScanning()
                found(text)
            }
        }
    }
}
