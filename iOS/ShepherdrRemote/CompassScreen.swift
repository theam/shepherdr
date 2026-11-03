import ShepherdrRemote
import SwiftUI
import UIKit
import WebKit

/// Compass on the phone: what its agent is doing, a run now, any day's page, and the agent's
/// terminal. The page's buttons stay on the Mac, which fills them in.
struct CompassScreen: View {
    @Bindable var client: RelayClient
    /// The day shown; nil for today.
    @State private var day: String?

    private var compass: RemoteCompass? { client.queue?.compass }

    var body: some View {
        VStack(spacing: 0) {
            if let compass {
                status(compass)
                page(compass)
            } else {
                ContentUnavailableView("Compass isn't set up", systemImage: "safari",
                                       description: Text("Set it up on the Mac, in Shepherdr's COMPASS tab."))
                    .foregroundStyle(Theme.dim)
                    .frame(maxHeight: .infinity)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(day.map { "COMPASS · \($0)" } ?? "COMPASS").font(Theme.mono(13, .semibold)).foregroundStyle(Theme.text).tracking(2)
            }
            if let compass, !compass.days.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Today") { day = nil }
                        ForEach(compass.days.filter { $0 != compass.today }, id: \.self) { other in
                            Button(other) { day = other }
                        }
                    } label: { Image(systemName: "calendar") }
                    .accessibilityLabel("Show another day")
                }
            }
        }
        .task(id: PageKey(day: day, modified: day == nil ? compass?.pageModified : nil, connected: client.phase == .connected)) {
            if client.phase == .connected { client.requestCompassPage(day) }
        }
    }

    private func status(_ compass: RemoteCompass) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(compass.activity).font(Theme.mono(12)).foregroundStyle(Self.color(of: compass))
            Text(compass.next).font(Theme.mono(11)).foregroundStyle(Theme.dim)
            if let problem = compass.problem {
                Text(problem).font(Theme.mono(11)).foregroundStyle(Theme.amber).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button { client.runCompass() } label: {
                    Label("RUN", systemImage: "play.fill").font(Theme.mono(12, .semibold))
                }
                .buttonStyle(.borderedProminent).tint(Theme.phosphor).foregroundStyle(Theme.background)
                .disabled(compass.isRunning)
                if compass.isRunning, !compass.needsYou {
                    Button("Cancel Run") { client.cancelCompassRun() }
                        .font(Theme.mono(12)).buttonStyle(.bordered).tint(Theme.dim)
                }
                Spacer()
                if let agent = compass.agent, let session = agent.session {
                    NavigationLink(value: SessionLink(row: agent, session: session)) {
                        Label("Agent", systemImage: "terminal").font(Theme.mono(12, .medium))
                    }
                    .buttonStyle(.bordered).tint(compass.needsYou ? Theme.amber : Theme.dim)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
    }

    @ViewBuilder private func page(_ compass: RemoteCompass) -> some View {
        let wanted = day ?? compass.today
        if let page = client.compassPage, page.day == wanted {
            if let html = page.html {
                CompassPageView(html: html)
            } else {
                ContentUnavailableView(day == nil ? "No page yet today" : "No page that day", systemImage: "doc",
                                       description: Text(day == nil ? "Run Compass to write today's page." : ""))
                    .foregroundStyle(Theme.dim)
                    .frame(maxHeight: .infinity)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static func color(of compass: RemoteCompass) -> Color {
        if compass.needsYou { return Theme.amber }
        if compass.activity.hasPrefix("✓") { return Theme.phosphor }
        if compass.activity.hasPrefix("●") || compass.activity.hasPrefix("○") { return Theme.cyan }
        return Theme.dim
    }

    /// What the page depends on: the day, today's last change, and being connected.
    private struct PageKey: Equatable {
        let day: String?
        let modified: Date?
        let connected: Bool
    }
}

/// The page as HTML, fitted to the phone. Links open in Safari; the page's own buttons need the
/// Mac and do nothing here.
struct CompassPageView: UIViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // A page written for the Mac's column may not say how wide it is.
        let viewport = """
        if (!document.querySelector('meta[name=viewport]')) {
          const meta = document.createElement('meta');
          meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1';
          document.head.appendChild(meta);
        }
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: viewport, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = UIColor(hex: 0x090C0A)
        view.scrollView.backgroundColor = UIColor(hex: 0x090C0A)
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else { return .allow }
            if ["http", "https"].contains(url.scheme?.lowercased()) { await UIApplication.shared.open(url) }
            return .cancel
        }
    }
}
