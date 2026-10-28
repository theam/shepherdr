import AppKit
import SwiftUI
import WebKit
import ShepherdrCore

/// A session's own browser. Its tabs stay open, scrolled and signed in while you move between
/// sessions. Links clicked in the terminal open here; ⌘-click opens the default browser instead.
@MainActor @Observable
final class SessionBrowser {
    private(set) var tabs: [BrowserTab] = []
    var selectedID: BrowserTab.ID? { didSet { if selectedID != oldValue { changed() } } }
    var isVisible = false { didSet { if isVisible != oldValue { changed() } } }
    /// Called whenever the tabs, their pages, the selection or the visibility change, to save them.
    @ObservationIgnored var onChange: (() -> Void)?

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.last }

    /// Shows a link, reusing a tab already on that page.
    func open(_ url: URL) {
        isVisible = true
        if let tab = tabs.first(where: { $0.url == url }) {
            selectedID = tab.id
        } else {
            add(BrowserTab(url: url, browser: self))
        }
    }

    /// Opens several links at once, each in its own tab unless one already shows it, and shows the
    /// first. The others load when you look at them.
    func open(all urls: [URL]) {
        guard let first = urls.first else { return }
        for url in urls where !tabs.contains(where: { $0.url == url }) {
            tabs.append(BrowserTab(url: url, browser: self, loadsNow: false))
        }
        isVisible = true
        selectedID = tabs.first { $0.url == first }?.id
        changed()
    }

    func newTab() {
        isVisible = true
        add(BrowserTab(url: nil, browser: self))
    }

    func add(_ tab: BrowserTab) {
        tabs.append(tab)
        selectedID = tab.id
        changed()
    }

    /// Moves a tab, such as Compass's page to the front.
    func move(_ tab: BrowserTab, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0 === tab }) else { return }
        tabs.remove(at: from)
        tabs.insert(tab, at: min(max(0, index), tabs.count))
        changed()
    }

    /// Brings back the tabs saved when Shepherdr quit. Each page loads the first time it is shown.
    func restore(_ urls: [URL], selected: Int?, visible: Bool) {
        guard tabs.isEmpty else { return }
        tabs = urls.map { BrowserTab(url: $0, browser: self, loadsNow: false) }
        selectedID = selected.flatMap { tabs.indices.contains($0) ? tabs[$0].id : nil } ?? tabs.last?.id
        isVisible = visible && !tabs.isEmpty
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.tearDown()
        tabs.remove(at: index)
        if selectedID == tab.id { selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id }
        if tabs.isEmpty { isVisible = false }
        changed()
    }

    func closeAll() {
        tabs.forEach { $0.tearDown() }
        tabs = []
        isVisible = false
        changed()
    }

    fileprivate func changed() { onChange?() }
}

/// Local files the browser shows itself; any other file opens in its default app.
enum LocalPage {
    case markdown, html

    init?(_ url: URL) {
        guard url.isFileURL else { return nil }
        let pathExtension = url.pathExtension.lowercased()
        if MarkdownRenderer.extensions.contains(pathExtension) { self = .markdown }
        else if ["html", "htm", "xhtml"].contains(pathExtension) { self = .html }
        else { return nil }
    }
}

@MainActor @Observable
final class BrowserTab: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    /// Replaced by a fresh one when the tab lets go of its page.
    private(set) var webView: WKWebView
    private(set) var title = ""
    private(set) var url: URL?
    private(set) var isLoading = false
    /// A restored or unloaded page waiting to be shown before it loads.
    @ObservationIgnored private var pending: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private weak var browser: SessionBrowser?
    @ObservationIgnored private let configuration: WKWebViewConfiguration
    /// Whether its web view holds a page: not a tab waiting to load, nor an empty one.
    @ObservationIgnored private(set) var holdsPage = false
    /// On screen now, and when it last was, or was opened if it never was.
    @ObservationIgnored private(set) var isShown = false
    @ObservationIgnored private(set) var lastShown = Date()
    /// A tab that can't be closed, such as Compass's page.
    var isPinned = false
    /// Links clicked in the page go here instead of loading in this tab, such as Compass's page,
    /// which stays put while its links open in tabs of their own.
    @ObservationIgnored var opensLink: ((URL) -> Void)?

    /// Shared by every session: one persistent cookie store, so signing in once is enough.
    static let configuration: WKWebViewConfiguration = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Identify as Safari: some sign-in pages refuse browsers they do not recognize.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        configuration.preferences.isElementFullscreenEnabled = true
        return configuration
    }()

    init(url: URL?, browser: SessionBrowser, configuration: WKWebViewConfiguration = BrowserTab.configuration, loadsNow: Bool = true) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.configuration = configuration
        self.browser = browser
        self.url = url
        super.init()
        attach(webView)
        if let url { if loadsNow { load(url) } else { pending = url } }
    }

    /// Becomes the web view's delegate and follows its title, address, loading and history.
    private func attach(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        observations = [
            view.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            view.observe(\.url) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let url = view.url, url != self.url else { return }
                    self.url = url
                    self.browser?.changed()
                }
            },
            view.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            view.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            view.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
    }

    /// Whether the tab may let go of its page while out of sight. Compass's page and pages
    /// opened as another page's window keep theirs, and so does a page still loading.
    var canUnload: Bool { !isPinned && opensLink == nil && configuration === Self.configuration && !isLoading }

    /// The tab is on screen, or has just left it.
    func shown(_ isShown: Bool) {
        self.isShown = isShown
        lastShown = Date()
    }

    /// Lets go of the page, and of everything it keeps running, for a fresh web view that loads
    /// the same address when the tab is shown again. Its scroll position, history and anything
    /// typed in it are lost.
    func unload() {
        guard holdsPage, !isShown, canUnload else { return }
        let address = url
        tearDown()
        webView = WKWebView(frame: .zero, configuration: configuration)
        attach(webView)
        holdsPage = false
        canGoBack = false
        canGoForward = false
        pending = address
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        if url?.isFileURL == true { return url?.lastPathComponent ?? "File" }
        return url?.host() ?? "New Tab"
    }

    /// Loads a restored page the first time its tab is shown.
    func activate() {
        guard let pending else { return }
        self.pending = nil
        load(pending)
    }

    /// Web pages load as usual. Markdown files are rendered, and HTML files may read their folder.
    func load(_ url: URL) {
        self.url = url
        pending = nil
        holdsPage = true
        switch LocalPage(url) {
        case .markdown:
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? "*Could not read \(url.lastPathComponent).*"
            // The base URL lets relative images and links resolve, and WebKit read that folder.
            webView.loadHTMLString(MarkdownRenderer.page(markdown: text, file: url), baseURL: url)
        case .html:
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        case nil:
            webView.load(URLRequest(url: url))
        }
    }

    /// Markdown is rendered again from the file, so edits show up.
    func reload() {
        if let url, LocalPage(url) == .markdown { load(url) } else { webView.reload() }
    }

    func tearDown() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// Where ⌘-clicked links go: your default browser.
    static var openOutside: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// A ⌘-click on a link, which opens it in your default browser instead.
    private static func isCommandClick(_ action: WKNavigationAction) -> Bool {
        action.navigationType == .linkActivated && action.modifierFlags.contains(.command)
    }

    // Links that ask for a new window open as a tab in the same session's browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if Self.isCommandClick(navigationAction), let url = navigationAction.request.url {
            Self.openOutside(url)
            return nil
        }
        guard let browser else { return nil }
        let tab = BrowserTab(url: nil, browser: browser, configuration: configuration)
        browser.add(tab)
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.close(self)
    }

    // Mail, app and other non-web links go to the system. Rendered Markdown runs no scripts, and a
    // link from it to another local file opens that file the way a terminal click would.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else { return (.allow, preferences) }
        if Self.isCommandClick(navigationAction) {
            Self.openOutside(url)
            return (.cancel, preferences)
        }
        if let opensLink, navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false,
           ["http", "https", "file"].contains(scheme), url.removingFragment != self.url?.removingFragment {
            opensLink(url)
            return (.cancel, preferences)
        }
        if url.isFileURL, navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false {
            let file = url.removingFragment
            if LocalPage(file) != nil, file != self.url?.removingFragment { load(file) }
            else if LocalPage(file) == nil { NSWorkspace.shared.open(file) }
            else { return (.allow, preferences) } // An anchor in the same page.
            return (.cancel, preferences)
        }
        if url.isFileURL, LocalPage(url) == .markdown { preferences.allowsContentJavaScript = false }
        guard ["http", "https", "about", "blob", "data", "file"].contains(scheme) else {
            NSWorkspace.shared.open(url)
            return (.cancel, preferences)
        }
        return (.allow, preferences)
    }
}

/// Loads pages out of sight with the session browsers' sign-ins, to tell whether a link exists and
/// read its title. One page at a time.
@MainActor
final class PageProbe: NSObject, WKNavigationDelegate {
    struct Page {
        /// The main page's HTTP status, if it answered.
        let status: Int?
        /// Where it ended up after redirects, such as a sign-in page.
        let url: URL?
        let title: String?
        /// The host doesn't exist: the link is made up.
        let hostMissing: Bool
    }

    private lazy var webView: WKWebView = {
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: BrowserTab.configuration)
        view.navigationDelegate = self
        return view
    }()
    private var status: Int?
    private var waiting: CheckedContinuation<Page, Never>?
    private var deadline: Task<Void, Never>?

    func load(_ url: URL) async -> Page {
        await withCheckedContinuation { continuation in
            waiting = continuation
            status = nil
            webView.load(URLRequest(url: url))
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finish(nil)
            }
        }
    }

    /// Whether the browsers are signed in to GitHub, which hides private repositories from visitors.
    static func isSignedIntoGitHub() async -> Bool {
        await BrowserTab.configuration.websiteDataStore.httpCookieStore.allCookies()
            .contains { $0.name == "logged_in" && $0.value == "yes" && $0.domain.hasSuffix("github.com") }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse {
            status = response.statusCode
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Single-page apps set their titles, or move to a sign-in page, just after loading.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        guard let waiting else { return }
        self.waiting = nil
        deadline?.cancel()
        let code = (error as NSError?)?.code
        waiting.resume(returning: Page(status: status, url: webView.url, title: webView.title,
                                       hostMissing: code == NSURLErrorCannotFindHost || code == NSURLErrorDNSLookupFailed))
        webView.stopLoading()
    }
}

/// The browser column: tabs, navigation and the selected page.
struct BrowserPanel: View {
    let browser: SessionBrowser
    @ViewState<String> private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            toolbar
            Rectangle().fill(Theme.line).frame(height: 1)
            if let tab = browser.selected {
                WebViewHost(webView: tab.webView)
                    .onAppear {
                        tab.shown(true)
                        tab.activate()
                    }
                    .onDisappear { tab.shown(false) }
                    .id(tab.id)
            } else {
                Text("no pages open").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.background)
        .onChange(of: browser.selected?.url, initial: true) {
            if !addressFocused { address = browser.selected?.url?.absoluteString ?? "" }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(browser.tabs) { tab in tabChip(tab) }
                Button {
                    browser.newTab()
                    address = ""
                    addressFocused = true
                } label: {
                    Text("+").font(Theme.mono(13, .bold)).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.phosphor)
                .help("New tab")
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
        }
        .background(Theme.panel)
    }

    private func tabChip(_ tab: BrowserTab) -> some View {
        let selected = tab.id == browser.selected?.id
        return HStack(spacing: 6) {
            if tab.isLoading { Text("◌").foregroundStyle(Theme.phosphor) }
            if tab.isPinned { Text("◈").foregroundStyle(Theme.phosphor) }
            Text(tab.displayTitle).lineLimit(1).truncationMode(.tail)
            if !tab.isPinned {
                Button { browser.close(tab) } label: { Text("×").font(Theme.mono(12)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.dim)
                    .help("Close tab")
            }
        }
        .font(Theme.mono(10.5))
        .foregroundStyle(selected ? Theme.text : Theme.dim)
        .frame(maxWidth: 180, alignment: .leading)
        .padding(.horizontal, 10).frame(height: 26)
        .background(selected ? Theme.raised : Theme.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Theme.phosphor.opacity(0.7) : Theme.line, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { browser.selectedID = tab.id }
        .help(tab.url?.absoluteString ?? tab.displayTitle)
    }

    private var toolbar: some View {
        let tab = browser.selected
        return HStack(spacing: 6) {
            navButton("‹", help: "Back", enabled: tab?.canGoBack == true) { tab?.webView.goBack() }
            navButton("›", help: "Forward", enabled: tab?.canGoForward == true) { tab?.webView.goForward() }
            if tab?.isLoading == true {
                navButton("×", help: "Stop", enabled: true) { tab?.webView.stopLoading() }
            } else {
                navButton("↻", help: "Reload", enabled: tab != nil) { tab?.reload() }
            }
            TextField("address", text: $address)
                .textFieldStyle(.plain).font(Theme.mono(11)).foregroundStyle(Theme.text)
                .focused($addressFocused)
                .onSubmit(go)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(addressFocused ? Theme.phosphor.opacity(0.6) : Theme.line, lineWidth: 1))
            navButton("⧉", help: "Open in your default browser", enabled: tab?.url != nil) {
                if let url = tab?.url { NSWorkspace.shared.open(url) }
            }
            navButton("⇥", help: "Hide the browser (⌘B). Its tabs stay open.", enabled: true) { browser.isVisible = false }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Theme.panel)
    }

    private func navButton(_ glyph: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(Theme.mono(13, .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.phosphor : Theme.faint.opacity(0.5))
        .disabled(!enabled)
        .help(help)
    }

    /// Loads what was typed: a full URL, or a host such as `github.com/owner/repo`.
    private func go() {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return }
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate), url.host() != nil else { return }
        if let tab = browser.selected { tab.load(url) } else { browser.open(url) }
        addressFocused = false
    }
}

/// Hosts a tab's web view. The view belongs to the tab, not to SwiftUI, so leaving a session
/// detaches it without unloading the page; only the tabs of the sessions you go back to least
/// let it go, when there are too many or macOS is short of memory (`AppModel.trimCaches`).
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
    }

    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

private extension URL {
    var removingFragment: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.fragment = nil
        return components.url ?? self
    }
}
