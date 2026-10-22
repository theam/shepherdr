import AppKit
import SwiftUI
import ShepherdrCore
import ShepherdrTerminalUI

/// ⌘T: goes to any session, shell or Compass from a few letters of it, in a panel over the window
/// like Spotlight. What you visited last comes first, never what's on screen, so ⌘T and Return go
/// back to where you just were, as switching channels in Slack does.
struct QuickSwitcher: View {
    let model: AppModel
    @ViewState<String> private var query = ""
    @ViewState<Int> private var highlighted = 0

    private static let rowHeight: CGFloat = 46
    private static let visibleRows = 8

    var body: some View {
        let targets = model.switchTargets(matching: query)
        let current = targets.isEmpty ? nil : min(highlighted, targets.count - 1)
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .contentShape(Rectangle())
                .onTapGesture { model.closeSwitcher() }
            panel(targets, current: current)
                .padding(.top, 96)
        }
        .onChange(of: query) { highlighted = 0 }
    }

    private func panel(_ targets: [SwitchTarget], current: Int?) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("›").font(Theme.mono(18, .bold)).foregroundStyle(Theme.phosphor)
                PickerSearchField(text: $query, placeholder: model.showsMachineNames ? "Go to a session or Compass · name@machine"
                                                                                     : "Go to a session or Compass",
                                  size: 15, accessibilityLabel: "Go to a session or Compass",
                                  move: { step in
                                      guard !targets.isEmpty else { return }
                                      highlighted = max(0, min(targets.count - 1, (current ?? 0) + step))
                                  },
                                  submit: { if let current { model.switchTo(targets[current]) } },
                                  cancel: { model.closeSwitcher() })
                    .frame(height: 22)
                Text("esc").font(Theme.mono(10)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            Rectangle().fill(Theme.line).frame(height: 1)
            list(targets, current: current)
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack {
                Text("↑↓ choose · ⏎ open · esc close")
                Spacer()
                Text("last visited first")
            }
            .font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
            .padding(.horizontal, 16).padding(.vertical, 7)
        }
        .frame(width: 620)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.phosphor.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.55), radius: 32, y: 14)
    }

    @ViewBuilder private func list(_ targets: [SwitchTarget], current: Int?) -> some View {
        if targets.isEmpty {
            Text(query.isEmpty ? "nowhere else to go yet" : "nothing matches \"\(query)\"")
                .font(Theme.mono(11)).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 14)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(targets.enumerated()), id: \.element.id) { index, target in
                            SwitcherRow(target: target, isHighlighted: index == current, showsMachine: model.showsMachineNames,
                                        lastVisit: model.visits.visits[target.place],
                                        status: { if case .session(let row) = target { model.status(of: row) } else { nil } }(),
                                        background: { if case .session(let row) = target { !model.backgroundCommands(of: row).isEmpty } else { false } }()) {
                                model.switchTo(target)
                            }
                            .frame(height: Self.rowHeight)
                            .id(target.id)
                        }
                    }
                }
                .frame(height: Self.rowHeight * CGFloat(min(targets.count, Self.visibleRows)))
                .onChange(of: current) { _, new in if let new { proxy.scrollTo(targets[new].id) } }
            }
        }
    }
}

/// One place ⌘T offers: what it is, where, what it's doing, and when you last looked at it.
private struct SwitcherRow: View {
    let target: SwitchTarget
    let isHighlighted: Bool
    let showsMachine: Bool
    let lastVisit: Date?
    let status: SessionStatus?
    let background: Bool
    let choose: () -> Void
    @ViewState<Bool> private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                glyph.frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(name).font(Theme.mono(12.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                        if showsMachine, let machine { Text("@\(machine)").font(Theme.mono(10)).foregroundStyle(Theme.faint).lineLimit(1) }
                    }
                    Text(subtitle).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let lastVisit {
                    Text(Self.ago(lastVisit)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                        .help("Last visited \(lastVisit.formatted(date: .abbreviated, time: .shortened))")
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isHighlighted ? Theme.raised : hovering ? Theme.raised.opacity(0.5) : .clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.phosphor).frame(width: 2).opacity(isHighlighted ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(name)
    }

    @ViewBuilder private var glyph: some View {
        switch target {
        case .compass:
            Image(systemName: "safari").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.cyan)
        case .session:
            StateGlyph(status: status ?? .unknown, background: background)
        case .shell:
            Text("$").font(Theme.mono(12, .bold)).foregroundStyle(Theme.faint)
        }
    }

    private var name: String {
        switch target {
        case .compass: "Compass"
        case .session(let row): row.workspace
        case .shell(let shell): shell.pane.workspaceName
        }
    }

    private var machine: String? {
        switch target {
        case .compass: nil
        case .session(let row): row.machineName
        case .shell(let shell): shell.machine.name
        }
    }

    private var subtitle: String {
        switch target {
        case .compass: "the page of your day"
        case .session(let row): row.title
        case .shell: "shell"
        }
    }

    /// `now`, `5m`, `3h`, `2d`.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

/// Where the queue's filter used to be: opens ⌘T.
struct SwitcherButton: View {
    let model: AppModel

    var body: some View {
        Button { model.toggleSwitcher() } label: {
            HStack(spacing: 6) {
                Text("/").font(Theme.mono(12, .bold)).foregroundStyle(Theme.phosphor)
                Text("⌘T to search").font(Theme.mono(12)).foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Go to a session or Compass (⌘T)")
    }
}

/// A search field for pickers such as Wait For and ⌘T: it takes the keyboard as it appears, and
/// passes ↑, ↓, Return and Escape on instead of moving the cursor.
struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var size: CGFloat = 12
    var accessibilityLabel = "Find a session"
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingField()
        field.delegate = context.coordinator
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = ConsoleFonts.font(family: ConsoleFonts.defaultFamily, size: size)
        field.textColor = NSColor(hex: 0xD9E7DE)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .foregroundColor: NSColor(hex: 0x4B5E53), .font: ConsoleFonts.font(family: ConsoleFonts.defaultFamily, size: size)
        ])
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel(accessibilityLabel)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PickerSearchField
        init(_ parent: PickerSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.move(-1)
            case #selector(NSResponder.moveDown(_:)): parent.move(1)
            case #selector(NSResponder.insertNewline(_:)): parent.submit()
            case #selector(NSResponder.cancelOperation(_:)): parent.cancel()
            default: return false
            }
            return true
        }
    }

    /// Takes keyboard focus once it is in a window: sheets and popovers open with the field ready.
    private final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
