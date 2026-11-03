import ShepherdrRemote
import SwiftUI

@main
struct ShepherdrRemoteApp: App {
    @State private var client = RelayClient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(client: client)
                .preferredColorScheme(.dark)
                .tint(Theme.phosphor)
                .onOpenURL { url in
                    if let invite = PairingInvite(string: url.absoluteString) { client.pair(with: invite) }
                    else if let session = SessionLink.session(from: url) { client.pendingSession = session }
                }
        }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .active: client.start()
            case .background: client.suspend()
            default: break
            }
        }
    }
}

struct RootView: View {
    @Bindable var client: RelayClient
    @State private var path = NavigationPath()

    var body: some View {
        Group {
            if client.mac == nil {
                PairView(client: client)
            } else {
                NavigationStack(path: $path) { QueueView(client: client) }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            // Launch arguments, for tests in the Simulator, where nobody taps: `-pairInvite <link>`
            // pairs, `-openSession <machine>/<terminal>` opens that session once the queue shows it,
            // `-openCompass YES` opens Compass.
            let arguments = UserDefaults.standard
            if client.mac == nil, let link = arguments.string(forKey: "pairInvite"), let invite = PairingInvite(string: link) {
                client.pair(with: invite)
            } else {
                client.start()
            }
            if let open = arguments.string(forKey: "openSession"), let slash = open.firstIndex(of: "/") {
                client.pendingSession = RemoteSessionID(machineID: String(open[..<slash]), terminalID: String(open[open.index(after: slash)...]))
            }
            if arguments.bool(forKey: "openCompass") { path.append(CompassLink()) }
        }
        .onChange(of: client.pendingSession) { openPending() }
        .onChange(of: client.queue) { openPending() }
    }

    /// A session a link asked for opens once the queue shows it.
    private func openPending() {
        guard let session = client.pendingSession, let row = client.queue?.rows.first(where: { $0.session == session }) else { return }
        client.pendingSession = nil
        path = NavigationPath([SessionLink(row: row, session: session)])
    }
}
