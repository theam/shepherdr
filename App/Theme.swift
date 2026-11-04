import AppKit
import SwiftUI
import ShepherdrCore
import ShepherdrTerminalUI

/// Phosphor-on-black. Shepherdr is a terminal client, so it always presents a dark console.
enum Theme {
    static let background = Color(hex: 0x090C0A)
    static let panel = Color(hex: 0x0E1310)
    static let raised = Color(hex: 0x141B17)
    static let line = Color(hex: 0x1F2B25)
    static let text = Color(hex: 0xD9E7DE)
    static let dim = Color(hex: 0x7E9488)
    static let faint = Color(hex: 0x4B5E53)
    static let phosphor = Color(hex: 0x4DFFA0)
    static let amber = Color(hex: 0xFFB547)
    static let cyan = Color(hex: 0x5CD6FF)
    static let red = Color(hex: 0xFF5F57)
    /// The terminal's magenta: merged pull requests, as GitHub marks them.
    static let lilac = Color(hex: 0xD77CFF)

    /// In-between shades for the pixel-art artwork (app icon, README header): the logo's amber coat
    /// and the terminal's pinks, filled out so lightness steps stay small. scripts/pixelate.swift reads
    /// every color in this file, so artwork stays in the app's palette.
    static let artworkShades: [UInt32] = [0xA16F27, 0xFFC978, 0xFFDEA6, 0xFFA99F, 0xFFC3BB]

    /// Interface text uses the bundled Fira Code; the terminal font is configurable in Settings.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(ConsoleFonts.defaultFamily, size: size).weight(weight == .heavy || weight == .black ? .bold : weight)
    }

    static func color(for state: AgentState, stale: Bool = false) -> Color {
        guard !stale else { return faint }
        return switch state {
        case .blocked: amber
        case .working: cyan
        case .done: phosphor
        case .idle: dim
        case .unknown: faint
        }
    }

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .stale, .unknown: faint
        case .needsYou: amber
        case .working, .waiting, .running: cyan
        case .done, .finished, .shell: phosphor
        case .idle: dim
        }
    }

    static func color(for connection: ConnectionState) -> Color {
        switch connection {
        case .online: phosphor
        case .loading, .disabled: faint
        default: amber
        }
    }

    static let terminal = TerminalPalette(
        background: NSColor(hex: 0x090C0A), foreground: NSColor(hex: 0xD9E7DE),
        caret: NSColor(hex: 0x4DFFA0), selection: NSColor(hex: 0x4DFFA0, alpha: 0.28),
        ansi: [0x0E1310, 0xFF5F57, 0x4DFFA0, 0xFFB547, 0x5C9DFF, 0xD77CFF, 0x5CD6FF, 0xC5D3CA,
               0x4B5E53, 0xFF8A80, 0x8CFFC2, 0xFFD37F, 0x8FBCFF, 0xE6A8FF, 0x9AE6FF, 0xF2FFF7].map { NSColor(hex: $0) })
}

extension View {
    /// A rounded surface with a thin border: what a piece of content sits in.
    func card(radius: CGFloat = 8) -> some View {
        background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.line, lineWidth: 1))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Shepherdr's 8-bit logo: a German Shepherd keeping watch over its flock, drawn crisply at any pixel size.
struct PixelFlock: View {
    static let sheep = [
        "...ww.ww.ww.......",
        "..wWWwWWwWWw..KK..",
        ".wWWWWWWWWWWwFFFF.",
        "wWWWwWWWWWwWwFEFFF",
        "wWWWWWWWWWWWwFFFFN",
        "wWwWWWWWwWWWw.FFF.",
        ".wWWWWWWWWWWw.....",
        "..wWWWWwWWWw......",
        "...L.L....L.L.....",
        "...L.L....L.L.....",
        "...H.H....H.H.....",
    ]
    static let shepherd = [
        "..............k.K.......",
        ".............kkKK.......",
        ".............kKTK.......",
        ".............KKTTTT.....",
        ".............KTTETTT....",
        ".............KTTTTMMMMN.",
        "............KKTTTTTTt...",
        "......SSSSSSKTTTt.......",
        "...SSSSSSSSSSSTTT.......",
        "..SSSSsSSSSSSSTTT.......",
        ".SSSSSSSSSSSSTTTT.......",
        "SS.tTTTTTTTTTTTTT.......",
        "SS..tTTTTTTTTTTt........",
        "S...TT.......TT.T.......",
        "...TT........TT.T.......",
        "..TT.........T..T.......",
        "..TT.........T..T.......",
        "..HH.........H..H.......",
    ]
    private static let frontSheep: [Character: Color] = [
        "W": Color(hex: 0x7CFFB8), "w": Color(hex: 0x36D985), "F": Color(hex: 0x1FA463), "K": Color(hex: 0x1FA463),
        "E": Color(hex: 0xF2FFF7), "N": Color(hex: 0x0F5C35), "L": Color(hex: 0x1FA463), "H": Color(hex: 0x0F5C35),
    ]
    private static let backSheep: [Character: Color] = [
        "W": Color(hex: 0x2E9E66), "w": Color(hex: 0x217A4E), "F": Color(hex: 0x15603C), "K": Color(hex: 0x15603C),
        "E": Color(hex: 0xA6E8C4), "N": Color(hex: 0x0B3F25), "L": Color(hex: 0x15603C), "H": Color(hex: 0x0B3F25),
    ]
    /// Tan and saddle in the console's amber.
    private static let dog: [Character: Color] = [
        "T": Color(hex: 0xFFB547), "t": Color(hex: 0xC98A2E), "S": Color(hex: 0x5A3E16), "s": Color(hex: 0x7A5620),
        "K": Color(hex: 0x5A3E16), "k": Color(hex: 0x3E2A0F), "M": Color(hex: 0x5A3E16), "H": Color(hex: 0x5A3E16),
        "E": Color(hex: 0xFFF4D6), "N": Color(hex: 0x1A1208),
    ]
    /// Back to front: the shepherd watching from behind, two sheep at the back (one facing left),
    /// one beside the leader, then the leader.
    private static let scene: [(sprite: [String], x: Int, y: Int, flipped: Bool, colors: [Character: Color])] = [
        (shepherd, 9, 0, true, dog),
        (sheep, 1, 13, true, backSheep), (sheep, 21, 14, false, backSheep),
        (sheep, 22, 19, false, backSheep), (sheep, 4, 20, false, frontSheep),
    ]
    static let size = (columns: 41, rows: 31)
    var pixel: CGFloat = 2

    var body: some View {
        Canvas { context, _ in
            for item in Self.scene {
                // A dark one-pixel rim first keeps overlapping animals readable.
                for outline in [true, false] {
                    for (row, line) in item.sprite.enumerated() {
                        let width = line.count
                        for (column, character) in line.enumerated() {
                            guard let color = item.colors[character] else { continue }
                            let x = item.x + (item.flipped ? width - 1 - column : column)
                            let cell = CGRect(x: CGFloat(x) * pixel, y: CGFloat(item.y + row) * pixel, width: pixel, height: pixel)
                            context.fill(Path(outline ? cell.insetBy(dx: -pixel, dy: -pixel) : cell),
                                         with: .color(outline ? Color(hex: 0x070B09) : color))
                        }
                    }
                }
            }
        }
        .frame(width: CGFloat(Self.size.columns) * pixel, height: CGFloat(Self.size.rows) * pixel)
        .shadow(color: Theme.phosphor.opacity(0.4), radius: pixel * 2)
        .accessibilityHidden(true)
    }
}

/// A pixel-art face for the lid status: a smile when this Mac may sleep, and gritted teeth with a
/// falling bead of sweat while its agents work. With coffee on, each wears wide-open eyes that
/// drift about.
struct PixelFace: View {
    enum Mood { case happy, working }
    let mood: Mood
    var caffeinated = false
    var pixel: CGFloat = 1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The face without eyes: the top two rows, then from the row under them.
    private static let happyTop = ["..GGGGG..", ".GGGGGGG."]
    private static let happyRest = ["GGGGGGGGG", "GkGGGGGkG", "GGkkkkkGG", ".GGGGGGG.", "..GGGGG.."]
    private static let workingTop = ["..AAAAA..", ".AAAAAAA."]
    private static let workingRest = ["AAAAAAAAA", "AkkkkkkkA", "AkWkWkWkA", ".AkkkkkA.", "..AAAAA.."]
    private static let colors: [Character: Color] = [
        "G": Theme.phosphor, "A": Theme.amber, "k": Theme.background, "W": Color(hex: 0xFFF4D6),
    ]
    /// Where the pupils look over the frames of the caffeinated cycle.
    private static let looks = [0, 1, 0, -1, 0, 1]

    /// The face's rows; `look` moves the pupils of the wide eyes a column, and is ignored for the
    /// narrow eyes of a face without coffee.
    private static func sprite(_ mood: Mood, caffeinated: Bool, look: Int) -> [String] {
        let skin: Character = mood == .happy ? "G" : "A"
        guard caffeinated else {
            return mood == .happy
                ? happyTop + ["GGkGGGkGG", "GGkGGGkGG"] + happyRest
                : workingTop + ["AkkAAAkkA", "AAkAAAkAA"] + workingRest
        }
        // Three rows of white, 3 columns wide, with a pupil in the middle row.
        let white = String(skin) + "WWW" + String(skin) + "WWW" + String(skin)
        var middle = Array(white)
        middle[2 + look] = "k"
        middle[6 + look] = "k"
        let top = mood == .happy ? happyTop : workingTop
        let rest = mood == .happy ? happyRest : workingRest
        // The wide eyes take the row the narrow ones leave empty under them.
        return top + [white, String(middle), white] + rest.dropFirst()
    }

    var body: some View {
        let size = CGSize(width: 11 * pixel, height: 9 * pixel)
        if reduceMotion || (!caffeinated && mood == .happy) {
            face(look: 0, drop: mood == .working ? 0 : nil)
        } else if caffeinated {
            // Six slow frames of 0.6 s, so it doesn't distract: the pupils drift, and the sweat of a working face falls a row every two.
            let (mood, pixel) = (mood, pixel)
            FrameCycle(count: Self.looks.count, interval: 0.6, size: size, key: "\(mood)-\(pixel)-coffee") { frame, context in
                Self.draw(mood, caffeinated: true, look: Self.looks[frame], drop: mood == .working ? frame / 2 : nil,
                          pixel: pixel, in: context)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
        } else {
            let pixel = pixel
            FrameCycle(count: 3, interval: 0.35, size: size, key: pixel) { drop, context in
                Self.draw(.working, caffeinated: false, look: 0, drop: drop, pixel: pixel, in: context)
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
        }
    }

    /// The bead of sweat runs down the side of the face, a row per step.
    private func face(look: Int, drop: Int?) -> some View {
        let sprite = Self.sprite(mood, caffeinated: caffeinated, look: look)
        return Canvas { context, _ in
            for (row, line) in sprite.enumerated() {
                for (column, character) in line.enumerated() {
                    guard let color = Self.colors[character] else { continue }
                    context.fill(Path(CGRect(x: CGFloat(column) * pixel, y: CGFloat(row) * pixel, width: pixel, height: pixel)),
                                 with: .color(color))
                }
            }
            if let drop {
                let top = CGFloat(1 + drop * 2) * pixel
                context.fill(Path(CGRect(x: 10 * pixel, y: top, width: pixel, height: pixel * 2)), with: .color(Theme.cyan))
            }
        }
        .frame(width: 11 * pixel, height: 9 * pixel)
        .accessibilityHidden(true)
    }

    private static func draw(_ mood: Mood, caffeinated: Bool, look: Int, drop: Int?, pixel: CGFloat, in context: CGContext) {
        for (row, line) in sprite(mood, caffeinated: caffeinated, look: look).enumerated() {
            for (column, character) in line.enumerated() {
                guard let color = colors[character] else { continue }
                context.setFillColor(NSColor(color).cgColor)
                context.fill(CGRect(x: CGFloat(column) * pixel, y: CGFloat(row) * pixel, width: pixel, height: pixel))
            }
        }
        if let drop {
            context.setFillColor(NSColor(Theme.cyan).cgColor)
            context.fill(CGRect(x: 10 * pixel, y: CGFloat(1 + drop * 2) * pixel, width: pixel, height: pixel * 2))
        }
    }
}

/// A pixel-art mug seen from the side, without a saucer. Lit and steaming while there is coffee,
/// dim and empty when there isn't.
struct PixelCup: View {
    let isOn: Bool
    var pixel: CGFloat = 1.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let mug = [
        "AAAAAAAA..",
        "AhAAAAAaAA",
        "AhAAAAAa.A",
        "AhAAAAAa.A",
        "AhAAAAAaAA",
        ".AAAAAAa..",
        "..aaaaa...",
    ]
    private static let steamRows = 4
    private static let columns = 10
    private static let steamFrames = 4

    /// The cells of the steam in one frame, as (column, row, strength): two wisps that sway as they
    /// climb and thin out toward the top.
    private static func steam(frame: Int) -> [(column: Int, row: Int, strength: Double)] {
        var cells: [(Int, Int, Double)] = []
        for (base, phase) in [(2, 0), (5, 1)] {
            for row in 0..<steamRows {
                let step = row + frame + phase
                guard step % 3 != 0 else { continue }
                cells.append((base + (step / 2) % 2, row, 0.25 + 0.55 * Double(row + 1) / Double(steamRows)))
            }
        }
        return cells
    }

    private var size: CGSize { CGSize(width: CGFloat(Self.columns) * pixel, height: CGFloat(Self.steamRows + Self.mug.count) * pixel) }

    var body: some View {
        if isOn && !reduceMotion {
            let pixel = pixel
            FrameCycle(count: Self.steamFrames, interval: 0.8, size: size, key: pixel) { frame, context in
                Self.draw(lit: true, steam: frame, pixel: pixel, in: context)
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: Theme.amber.opacity(0.5), radius: 3)
            .accessibilityHidden(true)
        } else {
            Canvas { context, _ in
                Self.paint(lit: isOn, steam: isOn ? 0 : nil, pixel: pixel) { rect, color, alpha in
                    context.fill(Path(rect), with: .color(color.opacity(alpha)))
                }
            }
            .frame(width: size.width, height: size.height)
            .shadow(color: isOn ? Theme.amber.opacity(0.5) : .clear, radius: 3)
            .accessibilityHidden(true)
        }
    }

    private static func draw(lit: Bool, steam: Int, pixel: CGFloat, in context: CGContext) {
        paint(lit: lit, steam: steam, pixel: pixel) { rect, color, alpha in
            context.setFillColor(NSColor(color).withAlphaComponent(alpha).cgColor)
            context.fill(rect)
        }
    }

    /// Calls `fill` for each cell: the steam on top, then the mug under it.
    private static func paint(lit: Bool, steam frame: Int?, pixel: CGFloat, fill: (CGRect, Color, Double) -> Void) {
        if let frame {
            for cell in steam(frame: frame) {
                fill(CGRect(x: CGFloat(cell.column) * pixel, y: CGFloat(cell.row) * pixel, width: pixel, height: pixel),
                     Color(hex: 0xFFF4D6), cell.strength)
            }
        }
        let colors: [Character: Color] = lit
            ? ["A": Theme.amber, "a": Color(hex: 0xC98A2E), "h": Color(hex: 0xFFD98A)]
            : ["A": Theme.dim, "a": Theme.faint, "h": Theme.dim]
        for (row, line) in mug.enumerated() {
            for (column, character) in line.enumerated() {
                guard let color = colors[character] else { continue }
                fill(CGRect(x: CGFloat(column) * pixel, y: CGFloat(steamRows + row) * pixel, width: pixel, height: pixel), color, 1)
            }
        }
    }
}

/// A TUI-style status glyph: a braille spinner while working, a blinking alert when it needs you,
/// an hourglass on hold.
struct StateGlyph: View {
    let status: SessionStatus
    /// Whether the agent left commands running, such as a watcher: a slow clock instead of its state's mark.
    var background = false
    private static let spinner = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
    private static let clock = Array("◴◷◶◵")

    var body: some View {
        let color = Theme.color(for: status)
        Group {
            switch status {
            case .stale: Text("◌")
            case .waiting: Image(systemName: "hourglass").font(.system(size: 11, weight: .semibold))
            case _ where background && !status.isBusy:
                FrameCycle(count: Self.clock.count, interval: 0.4, size: CGSize(width: 14, height: 16), key: "clock-\(status)") { tick, context in
                    FrameCycle.draw(String(Self.clock[tick]), in: context, size: CGSize(width: 14, height: 16),
                                    font: ConsoleFonts.font(family: ConsoleFonts.defaultFamily, size: 13, weight: .bold), color: NSColor(color))
                }
                .frame(height: 16)
            case .working, .running, .needsYou:
                let spins = status != .needsYou
                FrameCycle(count: spins ? Self.spinner.count : 2, interval: spins ? 0.1 : 0.5,
                           size: CGSize(width: 14, height: 16), key: "state-\(status)") { tick, context in
                    let glyph = spins ? String(Self.spinner[tick]) : "!"
                    FrameCycle.draw(glyph, in: context, size: CGSize(width: 14, height: 16),
                                    font: ConsoleFonts.font(family: ConsoleFonts.defaultFamily, size: 12, weight: .bold),
                                    color: spins || tick == 0 ? NSColor(color) : NSColor(color).withAlphaComponent(0.35))
                }
                .frame(height: 16)
            case .done, .finished: Text("✓")
            case .idle: Text("○")
            case .shell: Text("$")
            case .unknown: Text("?")
            }
        }
        .font(Theme.mono(12, .bold))
        .foregroundStyle(color)
        .frame(width: 14)
        .help(Self.help(status))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(background ? "\(status.label), with commands running" : status.label)
    }

    static func help(_ status: SessionStatus) -> String {
        switch status {
        case .stale: "Its machine isn't answering: this is the last state it reported"
        case .needsYou: "Herdr reports this agent needs attention"
        case .waiting: "On hold, waiting for other sessions"
        case .running: "Running a command"
        case .finished: "Its command finished"
        default: status.label.capitalized
        }
    }
}

/// What an agent left running, such as `◴ npm run dev +1`; its help lists every command.
struct BackgroundLabel: View {
    let commands: [BackgroundCommand]

    var body: some View {
        if let first = commands.first {
            Text("◴ \(first.command)" + (commands.count > 1 ? " +\(commands.count - 1)" : ""))
                .lineLimit(1).truncationMode(.tail)
                .help(Self.help(commands))
        }
    }

    static func help(_ commands: [BackgroundCommand]) -> String {
        let lines = commands.map { "• \($0.command)  (\(duration(Int(-$0.started.timeIntervalSinceNow))))" }
        return (["The agent isn't working, but it left these running:"] + lines).joined(separator: "\n")
    }

    static func duration(_ seconds: Int) -> String {
        switch seconds {
        case ..<60: "\(seconds) s"
        case ..<3_600: "\(seconds / 60) min"
        case ..<86_400: "\(seconds / 3_600) h \(seconds % 3_600 / 60) min"
        default: "\(seconds / 86_400) d \(seconds % 86_400 / 3_600) h"
        }
    }
}

/// `[ WORKING ]`-style status badge.
struct StateTag: View {
    let status: SessionStatus

    var body: some View {
        let color = Theme.color(for: status)
        Text(status.label.uppercased())
            .font(Theme.mono(10, .bold))
            .tracking(1)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color.opacity(0.35), lineWidth: 1))
            .help(StateGlyph.help(status))
    }
}

/// The agent working in a session, by the mark its own interface shows: `✻ claude` in a row, and a
/// tag with its name in the session's header.
struct AgentMark: View {
    enum Style { case label, tag, glyph }
    let program: AgentProgram
    var style: Style = .label

    var body: some View {
        if style == .glyph {
            // Just the mark, in a fixed width so the names after it line up.
            Text(program.glyph).font(Theme.mono(11, .bold)).foregroundStyle(Self.tint(program))
                .frame(width: 18, alignment: .center)
                .help(program.name)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(program.name)
        } else {
            labelOrTag
        }
    }

    private var labelOrTag: some View {
        HStack(spacing: style == .tag ? 5 : 3) {
            Text(program.glyph).fontWeight(.bold).foregroundStyle(Self.tint(program))
            if style == .tag {
                Text(program.name.uppercased()).tracking(1).foregroundStyle(Theme.dim)
            } else {
                Text(program.label).lineLimit(1)
            }
        }
        .modifier(TagFrame(isTag: style == .tag))
        .help(program.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(program.name)
    }

    /// The agents' own accent where the palette has one close by; the rest stay neutral.
    static func tint(_ program: AgentProgram) -> Color {
        switch program.label {
        case "claude": Color(hex: 0xFFA99F)
        case "codex": Theme.text
        case "gemini": Theme.lilac
        default: Theme.dim
        }
    }

    private struct TagFrame: ViewModifier {
        let isTag: Bool

        func body(content: Content) -> some View {
            if isTag {
                content
                    .font(Theme.mono(10, .bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line, lineWidth: 1))
            } else {
                content
            }
        }
    }
}

/// `// SECTION` headers used across the console.
struct ConsoleHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("//").foregroundStyle(Theme.phosphor.opacity(0.7))
            Text(title.uppercased()).tracking(1.5).foregroundStyle(Theme.dim)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).foregroundStyle(Theme.faint) }
        }
        .font(Theme.mono(10, .semibold))
    }
}

/// Bordered monospaced button: `[ LABEL ]`.
struct ConsoleButtonStyle: ButtonStyle {
    var tint: Color = Theme.phosphor
    var prominent = false
    /// Smaller, to sit in a list's row.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.mono(compact ? 9 : 11, .semibold))
            .foregroundStyle(prominent ? Theme.background : tint)
            .padding(.horizontal, compact ? 6 : 9).padding(.vertical, compact ? 2 : 4)
            .background(prominent ? tint.opacity(configuration.isPressed ? 0.7 : 1)
                                  : tint.opacity(configuration.isPressed ? 0.22 : 0.08),
                        in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(prominent ? 0 : 0.4), lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }
}

/// A console checkbox: `[✓] LABEL` lit when on, `[ ] LABEL` dimmed when off.
struct ConsoleCheckboxStyle: ToggleStyle {
    var tint: Color = Theme.phosphor

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 5) {
                Text(configuration.isOn ? "[✓]" : "[ ]")
                configuration.label
            }
        }
        .buttonStyle(ConsoleButtonStyle(tint: configuration.isOn ? tint : Theme.dim))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct ConnectionDot: View {
    let state: ConnectionState
    var body: some View {
        Rectangle().fill(Theme.color(for: state)).frame(width: 6, height: 6)
            .shadow(color: Theme.color(for: state).opacity(state == .online ? 0.8 : 0), radius: 3)
            .accessibilityHidden(true)
    }
}

/// Still frames shown in turn by Core Animation, in the window server. A SwiftUI timeline would lay
/// out the whole window on every tick: a tenth of a core for one spinner, for as long as agents work.
struct FrameCycle: NSViewRepresentable {
    let count: Int
    /// How long each frame shows. Frames follow the clock, so every cycle of this pace is in step.
    let interval: TimeInterval
    let size: CGSize
    /// Changing it draws the frames again.
    let key: AnyHashable
    /// Draws one frame, with the origin at the top left.
    let draw: (_ frame: Int, _ context: CGContext) -> Void

    func makeNSView(context: Context) -> FrameCycleView { FrameCycleView(cycle: self) }

    func updateNSView(_ view: FrameCycleView, context: Context) {
        guard view.cycle.key != key || view.cycle.count != count || view.cycle.size != size else { return }
        view.cycle = self
        view.render()
    }

    /// A glyph centered in a frame.
    static func draw(_ text: String, in context: CGContext, size: CGSize, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let bounds = string.size()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class FrameCycleView: NSView {
    var cycle: FrameCycle

    init(cycle: FrameCycle) {
        self.cycle = cycle
        super.init(frame: CGRect(origin: .zero, size: cycle.size))
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { cycle.size }
    override var wantsUpdateLayer: Bool { true }
    override func viewDidMoveToWindow() { render() }
    override func viewDidChangeBackingProperties() { render() }

    func render() {
        guard let layer, let window else { return }
        let scale = window.backingScaleFactor
        let frames = (0..<cycle.count).compactMap { image($0, scale: scale) }
        layer.contentsScale = scale
        layer.contentsGravity = .center
        layer.contents = frames.first
        layer.removeAnimation(forKey: "frames")
        guard frames.count > 1 else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.keyTimes = (0...frames.count).map { NSNumber(value: Double($0) / Double(frames.count)) }
        animation.calculationMode = .discrete
        animation.duration = cycle.interval * Double(frames.count)
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        animation.beginTime = now - now.truncatingRemainder(dividingBy: animation.duration)
        layer.add(animation, forKey: "frames")
    }

    private func image(_ frame: Int, scale: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(ceil(cycle.size.width * scale)),
                                      height: Int(ceil(cycle.size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        cycle.draw(frame, context)
        return context.makeImage()
    }
}

