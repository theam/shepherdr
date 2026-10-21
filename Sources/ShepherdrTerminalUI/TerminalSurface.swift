import AppKit
import SwiftUI
import SwiftTerm
import ShepherdrCore

/// Colors for the embedded renderer. Agents mostly paint in true color; the ANSI table covers
/// shells and older tools so they match the surrounding interface.
public struct TerminalPalette: Equatable, Sendable {
    public var background: NSColor
    public var foreground: NSColor
    public var caret: NSColor
    public var selection: NSColor
    /// Sixteen ANSI colors: normal 0–7, then bright 8–15.
    public var ansi: [NSColor]

    public init(background: NSColor, foreground: NSColor, caret: NSColor, selection: NSColor, ansi: [NSColor]) {
        precondition(ansi.count == 16, "A terminal palette needs 16 ANSI colors")
        self.background = background
        self.foreground = foreground
        self.caret = caret
        self.selection = selection
        self.ansi = ansi
    }
}

/// A terminal and its view, kept while its session is out of sight: going back shows what it last
/// painted at once, and the store attaches again if it rested meanwhile. The first time it is
/// shown it connects; `close()` detaches this client for good, never the pane or its process.
@MainActor
public final class TerminalHolder {
    public let store: TerminalStore
    let view: ConsoleTerminalView
    private let delegate: TerminalSurface.Delegate
    /// Whether anyone can see the terminal, which the store rests on while nobody does.
    private var sight: TerminalSight?
    var palette: TerminalPalette
    private var isOpen = false
    /// When it was last put on screen or taken off it.
    public private(set) var lastShown = Date()

    /// Shown in the window now.
    public var isShown: Bool { view.superview != nil }

    public init(store: TerminalStore, palette: TerminalPalette, font: NSFont) {
        self.store = store
        self.palette = palette
        let view = ConsoleTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 520), font: font)
        self.view = view
        delegate = TerminalSurface.Delegate(store: store)
        TerminalSurface.apply(palette, to: view)
        // Selection and copy remain native; plain clicks reach the program through Herdr (onClick).
        view.allowMouseReporting = false
        // Option types what the keyboard layout gives it (@, #, €…), as in Terminal; the word-wise
        // and line-wise keys get their sequences from installInteractions.
        view.optionAsMetaKey = false
        view.terminalDelegate = delegate
        // Herdr keeps the history and paints whatever part of it is shown, so the view keeps none:
        // lines a resize pushed out would only be a stale copy to scroll into, hiding live output.
        view.getTerminal().changeHistorySize(0)
        view.onScroll = { [weak store] up, lines in store?.scroll(up: up, lines: lines) }
        view.onClick = { [weak store] column, row in store?.click(column: column, row: row) }
        store.display = { [weak view] frame in view?.show(frame) }
        store.resetDisplay = { [weak view] in view?.resetScreen() }
    }

    /// The view is in a window again: it reads keys and the mouse, and the store attaches if it
    /// rested meanwhile, or for the first time.
    func mounted() {
        lastShown = Date()
        view.installInteractions()
        if sight == nil {
            sight = TerminalSight(view: view) { [weak store, weak view] visible in
                store?.setVisible(visible)
                if visible { view?.scanDeferredResources() }
            }
            view.onWindowChange = { [weak sight] in sight?.update() }
        }
        guard !isOpen else { return }
        isOpen = true
        store.resize(columns: view.getTerminal().cols, rows: view.getTerminal().rows)
        store.open()
    }

    /// The view left the screen with its session: it stops reading events, and the store rests
    /// once nobody has seen it for a while, keeping what it painted.
    func unmounted() {
        lastShown = Date()
        view.removeInteractions()
    }

    /// Lets go of the terminal: detaches this client, never the pane or its process.
    public func close() {
        sight?.stop()
        sight = nil
        view.onWindowChange = nil
        view.removeInteractions()
        view.removeFromSuperview()
        store.disconnect()
        store.display = nil
        store.resetDisplay = nil
        view.terminalDelegate = nil
    }
}

/// A live Herdr terminal embedded in the window's work area: it shows a `TerminalHolder`'s view,
/// which outlives it, so leaving the session keeps the terminal and what it painted.
@MainActor
public struct TerminalSurface: NSViewRepresentable {
    let holder: TerminalHolder
    let palette: TerminalPalette
    let font: NSFont
    /// Changing this gives the terminal keyboard focus.
    let focusRequest: Int
    /// Opens a clicked link or file; `external` asks for the default browser or app instead of Shepherdr's own.
    let openLink: (_ url: URL, _ external: Bool) -> Void
    /// The existing local file a printed path names, if any.
    let resolveFile: (_ path: String) -> URL?
    /// A link to the session or pane that the text at a column of a row names, if any.
    let resolveSession: (_ row: [Character], _ column: Int) -> URL?
    /// Pull requests, issues and Claude artifacts seen on screen.
    let onResources: (_ found: [SessionResource]) -> Void
    /// Files and images dropped on the terminal; nil refuses drops.
    let onDropFiles: ((_ files: [URL]) -> Void)?

    public init(holder: TerminalHolder, palette: TerminalPalette, font: NSFont, focusRequest: Int = 0,
                resolveFile: @escaping (_ path: String) -> URL? = { _ in nil },
                resolveSession: @escaping (_ row: [Character], _ column: Int) -> URL? = { _, _ in nil },
                onResources: @escaping (_ found: [SessionResource]) -> Void = { _ in },
                onDropFiles: ((_ files: [URL]) -> Void)? = nil,
                openLink: @escaping (_ url: URL, _ external: Bool) -> Void = { url, _ in NSWorkspace.shared.open(url) }) {
        self.holder = holder
        self.palette = palette
        self.font = font
        self.focusRequest = focusRequest
        self.resolveFile = resolveFile
        self.resolveSession = resolveSession
        self.onResources = onResources
        self.onDropFiles = onDropFiles
        self.openLink = openLink
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> TerminalContainer { TerminalContainer() }

    public func updateNSView(_ container: TerminalContainer, context: Context) {
        let view = holder.view
        view.openLink = openLink
        view.resolveFile = resolveFile
        view.resolveSession = resolveSession
        view.onResources = onResources
        view.onDropFiles = onDropFiles
        if holder.palette != palette {
            holder.palette = palette
            Self.apply(palette, to: view)
        }
        if view.font != font { view.font = font }
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            container.addSubview(view)
            container.needsLayout = true
            context.coordinator.holder = holder
            holder.mounted()
        }
        // Shown, it takes the keyboard, as it does when asked to.
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak view] in view?.window?.makeFirstResponder(view) }
        }
    }

    public static func dismantleNSView(_ container: TerminalContainer, coordinator: Coordinator) {
        guard let holder = coordinator.holder, holder.view.superview === container else { return }
        holder.view.removeFromSuperview()
        holder.unmounted()
    }

    static func apply(_ palette: TerminalPalette, to view: SwiftTerm.TerminalView) {
        view.nativeBackgroundColor = palette.background
        view.nativeForegroundColor = palette.foreground
        view.caretColor = palette.caret
        view.selectedTextBackgroundColor = palette.selection
        view.installColors(palette.ansi.map(Self.terminalColor))
        view.layer?.backgroundColor = palette.background.cgColor
    }

    private static func terminalColor(_ color: NSColor) -> SwiftTerm.Color {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        return SwiftTerm.Color(red: UInt16(rgb.redComponent * 65_535), green: UInt16(rgb.greenComponent * 65_535),
                               blue: UInt16(rgb.blueComponent * 65_535))
    }

    /// What one showing of the terminal remembers: the holder it shows, and the focus request it
    /// last answered.
    @MainActor public final class Coordinator {
        weak var holder: TerminalHolder?
        var focusRequest: Int?
    }

    /// What SwiftTerm tells the terminal: sizes and keys go to the store.
    @MainActor final class Delegate: NSObject, @preconcurrency TerminalViewDelegate {
        let store: TerminalStore
        init(store: TerminalStore) { self.store = store }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
            if (source as? ConsoleTerminalView)?.applyingFrame != true { store.resize(columns: newCols, rows: newRows) }
        }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { store.send(.bytes(Data(data))) }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
        func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
        /// SwiftTerm calls this for ⌘-clicks on links agents mark up explicitly (OSC 8).
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased()) else { return }
            (source as? ConsoleTerminalView)?.openLink?(url, true)
        }
        func bell(source: SwiftTerm.TerminalView) {}
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    }
}

/// Where a terminal's view is shown. It takes the container's size only once the container has
/// one: until then it keeps the size it had, so Herdr isn't told to shrink the terminal to nothing
/// on its way back to the screen.
public final class TerminalContainer: NSView {
    public override func layout() {
        super.layout()
        guard bounds.width > 1, bounds.height > 1 else { return }
        for view in subviews where view.frame != bounds { view.frame = bounds }
    }
}

/// SwiftTerm's view with Shepherdr's interactions: clicking a link opens it (⌘-click: in the
/// default browser), other clicks reach programs that read the mouse, Shift-Return inserts a new
/// line in agent TUIs instead of submitting, ⌘ and ⌥ with the arrows and delete keys edit the
/// line as in macOS text fields, and selecting text copies it.
public final class ConsoleTerminalView: SwiftTerm.TerminalView {
    var openLink: ((_ url: URL, _ external: Bool) -> Void)?
    var resolveFile: ((_ path: String) -> URL?)?
    var resolveSession: ((_ row: [Character], _ column: Int) -> URL?)?
    var onResources: ((_ found: [SessionResource]) -> Void)?
    var onDropFiles: ((_ files: [URL]) -> Void)?
    /// Scrolls Herdr's history: up toward earlier output, by whole lines.
    var onScroll: ((_ up: Bool, _ lines: Int) -> Void)?
    /// Passes a click on a cell to the program, for programs that read the mouse.
    var onClick: ((_ column: Int, _ row: Int) -> Void)?
    /// The view joined or left a window: whether it can be seen may have changed.
    var onWindowChange: (() -> Void)?
    /// Lines the wheel turned that are not sent yet; fractions wait for more turning.
    private var pendingScroll: CGFloat = 0
    private var scrollSendScheduled = false
    private var cellMetrics: (font: NSFont, size: CGSize)?
    private var scanPending = false
    /// A scan put off while the window couldn't be seen, done when it shows again.
    private var scanDeferred = false
    /// Bumped by every frame, so the menu found under the pointer is reused until the screen changes.
    private var screenGeneration = 0
    private var menuCache: (generation: Int, row: Int, moves: Int?)?
    private var hoverCache: (generation: Int, row: Int, column: Int, clickable: Bool, at: TimeInterval)?
    /// A click that chose a menu option is not a selection to copy.
    private var clickWasConsumed = false
    /// Set while a Herdr frame resizes the view, so that resize is not reported back as the user's.
    private(set) var applyingFrame = false
    private var linkTracker: LinkTracker?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    /// Frames that arrived while the mouse button is down in the terminal. SwiftTerm drops the
    /// selection whenever output arrives, so a busy agent would otherwise make text impossible to select.
    private var heldFrames: [TerminalFrame]?
    private var selectedWithMouse = false
    private var pressedCell: (row: Int, column: Int)?
    /// The hyperlink being written, as SwiftTerm stores it: `params;URI`.
    private var link: String?
    /// One atom per link. SwiftTerm has room for 65,535 and never frees them on its own, while Herdr
    /// writes a busy screen's links again in every frame.
    private static var linkAtoms: [String: TinyAtom] = [:]

    func show(_ frame: TerminalFrame) {
        if heldFrames != nil {
            // A press whose mouse up went elsewhere (another app took it) must not freeze the terminal.
            if NSEvent.pressedMouseButtons & 1 != 0 { heldFrames?.append(frame); return }
            pressedCell = nil
            endMousePress()
        }
        applyingFrame = true
        if getTerminal().cols != frame.columns || getTerminal().rows != frame.rows {
            resize(cols: frame.columns, rows: frame.rows)
        }
        for piece in Self.pieces(frame.bytes) {
            switch piece {
            case .link(let payload): link = payload
            case .bytes(let bytes):
                if let link { feed(bytes, linking: link) } else { feed(byteArray: bytes[...]) }
            }
        }
        applyingFrame = false
        paintChangedRows()
    }

    /// A frame as Shepherdr feeds it: terminal bytes, and where a hyperlink (OSC 8) opens or closes.
    enum FramePiece: Equatable {
        case bytes([UInt8])
        /// A link's `params;URI`, or nil where links close.
        case link(String?)
    }

    /// Takes two things out of a frame.
    ///
    /// Herdr wraps every frame in synchronized output (mode 2026), but a frame arrives whole and is fed
    /// at once, so the screen never shows half of one anyway. Left in, it makes SwiftTerm copy the whole
    /// screen as each frame begins and repaint every row as it ends, even for a spinner's single cell.
    ///
    /// Links are set on cells by Shepherdr instead: SwiftTerm marks every cell from where a link opens
    /// to where the cursor is when it closes, and Herdr closes a link after moving to its next change,
    /// so blank cells all over the screen would show the link's dashed underline.
    static func pieces(_ data: Data) -> [FramePiece] {
        let bytes = [UInt8](data)
        let synchronized = Array("\u{1b}[?2026".utf8)
        var pieces: [FramePiece] = []
        var run: [UInt8] = []
        run.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 27 else {
                run.append(bytes[index])
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
                let close = stringEnd(bytes, from: index + 4)
                let payload = String(decoding: bytes[(index + 4)..<close.content], as: UTF8.self)
                if !run.isEmpty { pieces.append(.bytes(run)); run = [] }
                let uri = payload.firstIndex(of: ";").map { payload[payload.index(after: $0)...] } ?? ""
                pieces.append(.link(uri.isEmpty ? nil : payload))
                index = close.next
                continue
            }
            run.append(bytes[index])
            index += 1
        }
        if !run.isEmpty { pieces.append(.bytes(run)) }
        return pieces
    }

    /// Where an escape string's content ends, at BEL or ST (`ESC \`), and where what follows it starts.
    private static func stringEnd(_ bytes: [UInt8], from start: Int) -> (content: Int, next: Int) {
        var end = start
        while end < bytes.count {
            if bytes[end] == 7 { return (end, end + 1) }
            if bytes[end] == 27, end + 1 < bytes.count, bytes[end + 1] == UInt8(ascii: "\\") { return (end, end + 2) }
            end += 1
        }
        return (end, end)
    }

    /// Feeds bytes written inside a link, one piece at a time, and links exactly the cells its text lands on.
    private func feed(_ bytes: [UInt8], linking payload: String) {
        guard let atom = Self.linkAtoms[payload] ?? TinyAtom.lookup(value: payload) else {
            feed(byteArray: bytes[...])
            return
        }
        Self.linkAtoms[payload] = atom
        let terminal = getTerminal()
        var index = 0
        while index < bytes.count {
            let end = Self.tokenEnd(bytes, from: index)
            let isText = bytes[index] >= 0x20 && bytes[index] != 0x7F
            let start = terminal.getCursorLocation()
            feed(byteArray: bytes[index..<end])
            if isText { setLink(atom, from: start, to: terminal.getCursorLocation()) }
            index = end
        }
    }

    /// Where a run of text, an escape sequence or a control character that starts at `start` ends.
    static func tokenEnd(_ bytes: [UInt8], from start: Int) -> Int {
        let first = bytes[start]
        if first == 27 {
            guard start + 1 < bytes.count else { return bytes.count }
            switch bytes[start + 1] {
            case UInt8(ascii: "["):
                var end = start + 2
                while end < bytes.count, !(0x40...0x7E).contains(bytes[end]) { end += 1 }
                return min(end + 1, bytes.count)
            case UInt8(ascii: "]"), UInt8(ascii: "P"), UInt8(ascii: "^"), UInt8(ascii: "_"):
                return stringEnd(bytes, from: start + 2).next
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "#"),
                 UInt8(ascii: "%"), UInt8(ascii: " "):
                return min(start + 3, bytes.count)
            default:
                return start + 2
            }
        }
        if first < 0x20 || first == 0x7F { return start + 1 }
        var end = start + 1
        while end < bytes.count, bytes[end] >= 0x20, bytes[end] != 0x7F { end += 1 }
        return end
    }

    /// Links the cells text was written to, from where the cursor was to where it is, across a wrap.
    /// The terminal keeps no history, so the cursor's rows are the screen's rows.
    private func setLink(_ atom: TinyAtom, from start: (x: Int, y: Int), to end: (x: Int, y: Int)) {
        let terminal = getTerminal()
        guard end.y >= start.y else { return }
        for row in start.y...end.y {
            guard let line = terminal.getLine(row: row) else { continue }
            let first = row == start.y ? start.x : 0
            let last = row == end.y ? min(end.x, terminal.cols) : terminal.cols
            guard first < last else { continue }
            for column in first..<last {
                var cell = line[column]
                cell.setPayload(atom: atom)
                line[column] = cell
            }
        }
    }

    func resetScreen() {
        heldFrames = heldFrames.map { _ in [] }
        feed(text: "\u{1b}c")
        paintChangedRows()
    }

    /// SwiftTerm paints new output a sixtieth of a second after it arrives. Painting the changed rows
    /// right away saves that wait on every keystroke's echo; SwiftTerm's own pass then finds nothing
    /// left to paint and only moves the caret.
    private func paintChangedRows() {
        let terminal = getTerminal()
        guard let (first, last) = terminal.getUpdateRange() else { return }
        terminal.clearUpdateRange()
        let height = cellSize.height
        var region = CGRect(x: 0, y: bounds.height - CGFloat(last + 1) * height,
                            width: bounds.width, height: CGFloat(last - first + 1) * height)
        // As SwiftTerm does: the last row also repaints the leftover strip below it.
        if last == terminal.rows - 1 { region = CGRect(x: 0, y: 0, width: bounds.width, height: region.maxY) }
        setNeedsDisplay(region)
        NSAccessibility.post(element: self, notification: .valueChanged)
        screenGeneration += 1
        scheduleResourceScan()
    }

    /// Looks for links worth keeping at most once a second while output flows, and only while the
    /// window can be seen: a scan put off meanwhile happens when it shows again.
    private func scheduleResourceScan() {
        guard !scanPending, onResources != nil else { return }
        scanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.scanPending = false
            guard self.window?.occlusionState.contains(.visible) == true else {
                self.scanDeferred = true
                return
            }
            let terminal = self.getTerminal()
            var found = SessionResources.find(onScreen: self.screenRows())
            // Links agents mark up explicitly keep their whole URL in every cell, however they wrap.
            for row in 0..<terminal.rows {
                for column in 0..<terminal.cols {
                    guard let payload = terminal.getCharData(col: column, row: row)?.getPayload() as? String,
                          let separator = payload.firstIndex(of: ";"),
                          let url = URL(string: String(payload[payload.index(after: separator)...])),
                          let resource = SessionResource(url: url), !found.contains(resource) else { continue }
                    found.append(resource)
                }
            }
            if !found.isEmpty { self.onResources?(found) }
        }
    }

    /// Does the scan put off while the window couldn't be seen.
    func scanDeferredResources() {
        guard scanDeferred else { return }
        scanDeferred = false
        scheduleResourceScan()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }

    /// The visible screen, one character per column.
    func screenRows(_ rows: ClosedRange<Int>? = nil) -> [[Character]] {
        let terminal = getTerminal()
        let range = rows ?? 0...max(0, terminal.rows - 1)
        return range.map { index -> [Character] in
            guard let line = terminal.getLine(row: index) else { return Array(repeating: " ", count: terminal.cols) }
            return (0..<terminal.cols).map { column in
                guard column < line.count else { return " " }
                let cell = line[column]
                // The second half of a wide character, and empty cells, read as blanks.
                let character = cell.getCharacter()
                return cell.width == 0 || character == "\u{0}" ? " " : character
            }
        }
    }

    /// Chooses the menu option at a point by moving the menu's highlight there with the arrow keys;
    /// a double click also confirms it. Returns whether the click was on a menu option.
    func chooseMenuOption(at point: NSPoint, clickCount: Int) -> Bool {
        guard let moves = menuMoves(at: point) else { return false }
        clickWasConsumed = true
        if clickCount >= 2 {
            send(data: [13][...])
        } else if moves != 0 {
            let applicationCursor = getTerminal().applicationCursor
            let key: [UInt8] = moves < 0 ? (applicationCursor ? [27, 79, 65] : [27, 91, 65])
                                         : (applicationCursor ? [27, 79, 66] : [27, 91, 66])
            send(data: Array(Array(repeating: key, count: abs(moves)).joined())[...])
        }
        return true
    }

    /// How far the highlight of the agent menu under a point must move to reach it, if there is one.
    func menuMoves(at point: NSPoint) -> Int? {
        guard let row = cell(at: point)?.row else { return nil }
        if let cache = menuCache, cache.generation == screenGeneration, cache.row == row { return cache.moves }
        let lines = screenRows().map { String($0).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
        let moves = TerminalMenus.moves(in: lines, clicked: row)
        menuCache = (screenGeneration, row, moves)
        return moves
    }

    /// Whether a click at a point opens something or chooses a menu option. The pointer moves many
    /// times within a cell, so the answer holds until it leaves the cell, or the screen changes and a
    /// tenth of a second has passed.
    func isClickable(at point: NSPoint) -> Bool {
        guard let cell = cell(at: point) else { return false }
        // A working agent repaints the screen many times a second; within a cell, an answer a tenth
        // of a second old is still good, and saves reading the screen on every move.
        let now = ProcessInfo.processInfo.systemUptime
        if let hover = hoverCache, hover.row == cell.row, hover.column == cell.column,
           hover.generation == screenGeneration || now - hover.at < 0.1 {
            return hover.clickable
        }
        let clickable = link(at: point) != nil || menuMoves(at: point) != nil
        hoverCache = (screenGeneration, cell.row, cell.column, clickable, now)
        return clickable
    }

    private func cell(at point: NSPoint) -> (row: Int, column: Int)? {
        let terminal = getTerminal(), size = cellSize
        let column = Int(point.x / size.width), row = Int((bounds.height - point.y) / size.height)
        guard point.x >= 0, point.y <= bounds.height, (0..<terminal.cols).contains(column),
              (0..<terminal.rows).contains(row) else { return nil }
        return (row, column)
    }

    /// SwiftTerm's own cell metrics: the width of "W" and the font's line height.
    var cellSize: CGSize {
        let font = font
        if let cellMetrics, cellMetrics.font === font { return cellMetrics.size }
        let size = CGSize(width: max(1, font.advancement(forGlyph: font.glyph(withName: "W")).width),
                          height: max(1, ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))))
        cellMetrics = (font, size)
        return size
    }

    /// The wheel and the trackpad scroll Herdr's history. Returns whether the event was the terminal's.
    private func handleScroll(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard event.window === window, !isHiddenOrHasHiddenAncestor, bounds.contains(point), onScroll != nil else { return false }
        // A trackpad reports points; a mouse wheel reports notches, three lines each.
        scroll(lines: event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellSize.height : event.scrollingDeltaY * 3,
               startsGesture: event.phase == .began)
        return true
    }

    /// Turns the history by some lines, toward earlier output when positive.
    func scroll(lines: CGFloat, startsGesture: Bool = false) {
        guard lines != 0 else { return }
        // A new gesture, or a turn the other way, starts counting afresh.
        if startsGesture || (lines > 0) != (pendingScroll > 0) { pendingScroll = 0 }
        pendingScroll += lines
        if !scrollSendScheduled { sendScroll() }
    }

    /// Sends the whole lines turned so far, at most once a frame however fast the wheel turns.
    private func sendScroll() {
        let lines = Int(pendingScroll)
        guard lines != 0 else { return }
        pendingScroll -= CGFloat(lines)
        onScroll?(lines > 0, abs(lines))
        scrollSendScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            self?.scrollSendScheduled = false
            self?.sendScroll()
        }
    }

    public override func selectionChanged(source: Terminal) {
        super.selectionChanged(source: source)
        if heldFrames != nil { selectedWithMouse = true }
    }

    /// Mouse down in the terminal holds output; mouse up copies what the mouse selected, then lets output in.
    private func handleMouse(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.type == .leftMouseDown {
            guard event.window === window, !isHiddenOrHasHiddenAncestor, bounds.contains(point) else { return }
            // A double click's second press can come before the first one is wrapped up.
            if heldFrames == nil {
                heldFrames = []
                selectedWithMouse = false
            }
            pressedCell = cell(at: point)
        } else if let pressed = pressedCell {
            // Released in the cell it was pressed in: a click rather than a selection drag.
            let click = cell(at: point).map { $0 == pressed } == true
                ? (point: point, count: event.clickCount, modifiers: event.modifierFlags.intersection([.shift, .control, .option, .command]))
                : nil
            pressedCell = nil
            // After SwiftTerm has handled this mouse up.
            DispatchQueue.main.async { [weak self] in
                if let click { self?.clicked(at: click.point, count: click.count, modifiers: click.modifiers) }
                self?.endMousePress()
            }
        }
    }

    /// A click opens the link or file under it (⌘: in the default browser or app), or the session
    /// named there, or chooses the option of an agent's menu under it. Any other plain click goes to the program, which Herdr
    /// drops unless the program reads the mouse.
    func clicked(at point: NSPoint, count: Int, modifiers: NSEvent.ModifierFlags) {
        let command = modifiers.contains(.command)
        if let link = link(at: point) {
            // SwiftTerm already opens explicit links on ⌘-click, through requestOpenLink. A double click
            // opens a link once.
            guard count == 1, !(command && link.explicit) else { return }
            clickWasConsumed = true
            openLink?(link.url, command)
        } else if !command, !chooseMenuOption(at: point, clickCount: count), modifiers.isEmpty, let cell = cell(at: point) {
            onClick?(cell.column, cell.row)
        }
    }

    /// Copies what the mouse selected and lets the held output in, unless another press has begun;
    /// that one finishes the job.
    private func endMousePress() {
        guard pressedCell == nil, let frames = heldFrames else { return }
        defer { clickWasConsumed = false }
        if selectedWithMouse, !clickWasConsumed, let text = getSelection(), !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        heldFrames = nil
        frames.forEach(show)
    }

    /// SwiftTerm's mouse and key handlers are not overridable, so local event monitors add these
    /// around them; selection keeps working.
    func installInteractions() {
        guard linkTracker == nil else { return }
        registerForDraggedTypes([.fileURL, .png, .tiff])
        let tracker = LinkTracker(view: self)
        linkTracker = tracker
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                                       owner: tracker))
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window, self.window?.firstResponder === self,
                  let bytes = Self.sequence(for: event) else { return event }
            self.terminalDelegate?.send(source: self, data: bytes[...])
            return nil
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handleScroll(event) == true ? nil : event
        }
    }

    func removeInteractions() {
        for monitor in [keyMonitor, mouseMonitor, scrollMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
        mouseMonitor = nil
        scrollMonitor = nil
        for area in trackingAreas where area.owner === linkTracker { removeTrackingArea(area) }
        linkTracker = nil
        unregisterDraggedTypes()
    }

    /// Keys that edit the line as they do in macOS text fields, sent as the Meta (Escape-prefixed)
    /// and Control keys that agents and shells read; Option otherwise types characters. SwiftTerm
    /// would move a word on ⌘← and ⌘→, and send nothing on ⌘⌫ or Shift-arrows.
    static func sequence(for event: NSEvent) -> [UInt8]? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        switch (event.keyCode, flags) {
        // Claude Code, Codex and Gemini read ESC-Return (Alt-Return) as a new line; Return submits.
        case (36, .shift), (76, .shift), (36, .option), (76, .option): return [27, 13]
        case (123, .option): return EscapeSequences.emacsBack // a word back
        case (124, .option): return EscapeSequences.emacsForward // a word forward
        case (51, .option): return [27, 127] // delete the previous word
        case (123, .command): return [1] // Control-A: the start of the line
        case (124, .command): return [5] // Control-E: the end of the line
        case (51, .command): return [21] // Control-U: delete to the start of the line
        case (117, .command): return [11] // Control-K: delete to the end of the line
        // Shift-arrows, as xterm sends them, which Codex asks for in its questions. SwiftTerm reads
        // them as selection commands and sends nothing.
        case (126, .shift): return Array("\u{1b}[1;2A".utf8)
        case (125, .shift): return Array("\u{1b}[1;2B".utf8)
        case (124, .shift): return Array("\u{1b}[1;2C".utf8)
        case (123, .shift): return Array("\u{1b}[1;2D".utf8)
        default: return nil
        }
    }

    /// The link at a point in this view: one an agent marked up explicitly, a plain-text URL, the
    /// path of an existing local file, or another session or pane named in the text.
    func link(at point: NSPoint) -> (url: URL, explicit: Bool)? {
        let terminal = getTerminal()
        guard let (row, column) = cell(at: point) else { return nil }
        if let payload = terminal.getCharData(col: column, row: row)?.getPayload() as? String {
            // SwiftTerm keeps OSC 8 links as "parameters;url".
            guard let separator = payload.firstIndex(of: ";"),
                  let url = URL(string: String(payload[payload.index(after: separator)...])),
                  ["https", "http"].contains(url.scheme?.lowercased()) else { return nil }
            return (url, true)
        }
        let first = max(0, row - 8), last = min(terminal.rows - 1, row + 8)
        let rows = screenRows(first...last)
        if let url = TerminalLinks.url(in: rows, row: row - first, column: column) { return (url, false) }
        if let file = TerminalPaths.path(in: rows, row: row - first, column: column).flatMap({ resolveFile?($0) }) {
            return (file, false)
        }
        return resolveSession?(rows[row - first], column).map { ($0, false) }
    }
}

/// Files and images dropped on the terminal reach the agent: their paths are typed into its prompt,
/// as other macOS terminals do, so Claude Code and Codex attach dropped images.
extension ConsoleTerminalView {
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onDropFiles != nil, Self.canTakeFiles(from: sender.draggingPasteboard) else { return [] }
        showDropTarget(true)
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        onDropFiles != nil && Self.canTakeFiles(from: sender.draggingPasteboard) ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) { showDropTarget(false) }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        showDropTarget(false)
        let files = Self.files(from: sender.draggingPasteboard)
        guard let onDropFiles, !files.isEmpty else { return false }
        window?.makeFirstResponder(self)
        onDropFiles(files)
        return true
    }

    private func showDropTarget(_ shown: Bool) {
        layer?.borderWidth = shown ? 2 : 0
        layer?.borderColor = caretColor.cgColor
    }

    static func canTakeFiles(from pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || NSImage.canInit(with: pasteboard)
    }

    /// Dropped files, or an image dragged without one (from a web page, say) saved as a PNG first.
    static func files(from pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shepherdr-drops", isDirectory: true)
        let file = folder.appendingPathComponent("image-\(Int(Date().timeIntervalSince1970 * 1000)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: file)
            return [file]
        } catch {
            return []
        }
    }
}

/// Shows a pointing hand over links, files, sessions and menu options.
@MainActor private final class LinkTracker: NSResponder {
    weak var view: ConsoleTerminalView?

    init(view: ConsoleTerminalView) {
        self.view = view
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func mouseMoved(with event: NSEvent) {
        guard let view else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        guard view.isClickable(at: point) else { return }
        NSCursor.pointingHand.set()
    }
}

/// Whether anyone can see a terminal: its window is on screen and not covered, minimized or on
/// another Space, and the screens are awake, unlocked and this user's. Says so on every change.
@MainActor final class TerminalSight {
    private weak var view: NSView?
    private let changed: (Bool) -> Void
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var screensAway = false
    private var locked = false
    private var visible: Bool?

    init(view: NSView, changed: @escaping (Bool) -> Void) {
        self.view = view
        self.changed = changed
        let workspace = NSWorkspace.shared.notificationCenter
        let away: [(Notification.Name, Bool)] = [
            (NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false),
            (NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false),
        ]
        for (name, isAway) in away {
            observe(workspace, name) { $0.screensAway = isAway }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification) { _ in }
        update()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping @MainActor (TerminalSight) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.update()
            }
        }
        observers.append((center, token))
    }

    /// Works out whether the terminal can be seen, and says so when that changed.
    func update() {
        let now = view?.window?.occlusionState.contains(.visible) == true && !screensAway && !locked
        guard now != visible else { return }
        // Until it is in a window, it can't be seen, but it isn't hidden either: say nothing yet.
        if visible == nil, view?.window == nil { return }
        visible = now
        changed(now)
    }

    func stop() {
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
    }
}

