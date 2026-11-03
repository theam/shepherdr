import ShepherdrRemote
import SwiftTerm
import SwiftUI
import UIKit

/// A pane's live terminal, at the phone's size: the phone controls it while it shows it.
struct TerminalPanel: View {
    let client: RelayClient
    let pane: RemoteSessionID
    let fontSize: Double
    @State private var terminal: RemoteTerminal?

    /// The terminals on screen, by pane, for the keys and the composer to reach.
    @MainActor static var shown: [RemoteSessionID: RemoteTerminal] = [:]

    @MainActor static func send(_ bytes: Data, to pane: RemoteSessionID) { shown[pane]?.input(bytes) }
    @MainActor static func scroll(up: Bool, in pane: RemoteSessionID) { shown[pane]?.scroll(up: up, lines: 10) }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background
            if let terminal {
                TerminalHost(terminal: terminal, fontSize: fontSize)
                banner(terminal)
            }
        }
        .onAppear {
            let terminal = client.terminal(for: pane)
            self.terminal = terminal
            Self.shown[pane] = terminal
        }
        .onDisappear {
            if let terminal {
                client.release(terminal)
                if Self.shown[pane] === terminal { Self.shown[pane] = nil }
            }
        }
    }

    @ViewBuilder private func banner(_ terminal: RemoteTerminal) -> some View {
        switch terminal.state {
        case .connecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Attaching…").font(Theme.mono(11)) }
                .foregroundStyle(Theme.dim).padding(8).background(Theme.panel.opacity(0.9), in: Capsule()).padding(8)
        case .controlledElsewhere:
            HStack(spacing: 10) {
                Text("Another client controls this pane. You're watching.").font(Theme.mono(11)).foregroundStyle(Theme.amber)
                Button("TAKE OVER") { terminal.takeOver() }.font(Theme.mono(11, .semibold)).buttonStyle(.bordered).tint(Theme.amber)
            }
            .padding(8).background(Theme.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 8)).padding(8)
        case .ended, .failed:
            Text(terminal.message ?? "The terminal ended.").font(Theme.mono(11)).foregroundStyle(Theme.amber)
                .padding(8).background(Theme.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 8)).padding(8)
        case .control, .observing:
            EmptyView()
        }
    }
}

/// SwiftTerm's terminal view, fed with Herdr's frames.
struct TerminalHost: UIViewRepresentable {
    let terminal: RemoteTerminal
    let fontSize: Double

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: Theme.terminalFont(size: fontSize))
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = UIColor(hex: 0x090C0A)
        view.nativeForegroundColor = UIColor(hex: 0xD9E7DE)
        view.caretColor = UIColor(hex: 0x4DFFA0)
        view.selectedTextBackgroundColor = UIColor(hex: 0x4DFFA0).withAlphaComponent(0.28)
        view.installColors(Self.palette)
        view.keyboardAppearance = .dark
        view.optionAsMetaKey = true
        // Herdr keeps the history and paints whatever part of it is shown, so SwiftTerm has nothing
        // to scroll: swiping asks Herdr instead.
        view.getTerminal().changeHistorySize(0)
        view.isScrollEnabled = false
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.scroller = TerminalScroller(view: view, terminal: terminal)
        terminal.onFrame = { [weak coordinator] frame in coordinator?.show(frame) }
        terminal.onReset = { [weak view] in view?.feed(text: "\u{1b}c") }
        // SwiftTerm reports the size once it lays out; attach then, or now if it never changes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak coordinator] in coordinator?.attachIfNeeded() }
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        if abs(view.font.pointSize - fontSize) > 0.1 { view.font = Theme.terminalFont(size: fontSize) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(terminal: terminal) }

    static func dismantleUIView(_ view: TerminalView, coordinator: Coordinator) {
        coordinator.scroller?.stop()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate {
        let terminal: RemoteTerminal
        weak var view: TerminalView?
        var scroller: TerminalScroller?
        private var attached = false

        init(terminal: RemoteTerminal) { self.terminal = terminal }

        func attachIfNeeded() {
            guard !attached, let view else { return }
            let size = view.getTerminal()
            attached = true
            terminal.resize(columns: size.cols, rows: size.rows)
        }

        func show(_ frame: RemoteFrame) {
            guard let view else { return }
            let screen = view.getTerminal()
            if screen.cols != frame.columns || screen.rows != frame.rows {
                screen.resize(cols: frame.columns, rows: frame.rows)
            }
            view.feed(byteArray: [UInt8](frame.bytes)[...])
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            attached = true
            terminal.resize(columns: newCols, rows: newRows)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) { terminal.input(Data(data)) }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link), ["http", "https"].contains(url.scheme) { UIApplication.shared.open(url) }
        }
        func clipboardCopy(source: TerminalView, content: Data) {
            if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    /// The Mac's terminal palette (App/Theme.swift).
    static let palette: [SwiftTerm.Color] = [
        0x0E1310, 0xFF5F57, 0x4DFFA0, 0xFFB547, 0x5C9DFF, 0xD77CFF, 0x5CD6FF, 0xC5D3CA,
        0x4B5E53, 0xFF8A80, 0x8CFFC2, 0xFFD37F, 0x8FBCFF, 0xE6A8FF, 0x9AE6FF, 0xF2FFF7
    ].map { hex in
        SwiftTerm.Color(red: UInt16(hex >> 16 & 0xFF) * 257, green: UInt16(hex >> 8 & 0xFF) * 257, blue: UInt16(hex & 0xFF) * 257)
    }
}

/// Swiping the terminal up and down scrolls through the history Herdr keeps, line by line as the
/// finger moves; a flick carries on and slows down, as a list does. Sideways swipes, and drags that
/// extend a selection, stay SwiftTerm's.
@MainActor
final class TerminalScroller: NSObject, UIGestureRecognizerDelegate {
    private weak var view: TerminalView?
    private let terminal: RemoteTerminal
    private let pan: UIPanGestureRecognizer
    /// Points moved and not yet sent as whole lines; positive goes back in history.
    private var pending: CGFloat = 0
    /// Points per second while coasting after a flick.
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval = 0
    private var lastSent: CFTimeInterval = 0

    /// At most this many scroll messages a second, so a fast flick doesn't flood the relay.
    static let sendsPerSecond: Double = 30
    /// UIScrollView's normal deceleration: what's left of the speed after each millisecond.
    static let deceleration: Double = 0.998

    init(view: TerminalView, terminal: RemoteTerminal) {
        self.view = view
        self.terminal = terminal
        pan = UIPanGestureRecognizer()
        super.init()
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    /// The height of a row on screen.
    private var lineHeight: CGFloat {
        guard let view else { return 17 }
        let rows = view.getTerminal().rows
        return rows > 0 && view.bounds.height > 0 ? view.bounds.height / CGFloat(rows) : view.font.lineHeight
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stop()
        case .changed:
            pending += gesture.translation(in: gesture.view).y
            gesture.setTranslation(.zero, in: gesture.view)
            send(force: false)
        case .ended:
            send(force: true)
            velocity = gesture.velocity(in: gesture.view).y
            if abs(velocity) > 300 { coast() } else { pending = 0 }
        default:
            stop()
        }
    }

    /// Sends the whole lines moved so far, unless one went out a moment ago.
    private func send(now: CFTimeInterval = CACurrentMediaTime(), force: Bool) {
        let height = lineHeight
        let lines = Int(pending / height)
        guard lines != 0, force || now - lastSent >= 1 / Self.sendsPerSecond else { return }
        pending -= CGFloat(lines) * height
        lastSent = now
        // A finger moving down brings back older lines.
        terminal.scroll(up: lines > 0, lines: abs(lines))
    }

    private func coast() {
        lastStep = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = max(0, link.timestamp - lastStep)
        lastStep = link.timestamp
        pending += velocity * elapsed
        velocity *= pow(Self.deceleration, elapsed * 1000)
        send(now: link.timestamp, force: false)
        if abs(velocity) < 40 {
            send(force: true)
            stop()
        }
    }

    /// Stops a flick that's still coasting.
    func stop() {
        link?.invalidate()
        link = nil
        velocity = 0
        pending = 0
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan, let view else { return true }
        if view.selectionActive { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }

    /// SwiftTerm's own drags, such as the one that sends the mouse to programs that read it, wait
    /// to see whether this is a scroll.
    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gesture === pan && other is UIPanGestureRecognizer && other.view === view
    }
}
