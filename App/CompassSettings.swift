import AppKit
import SwiftUI
import ShepherdrCore

/// Settings → Compass: when the page updates, which agent keeps it, the hours of its strip, its
/// template, and the Git remote that keeps a copy of the folder. All of it lives in
/// compass.json, which the Compass agent can also change when you ask it to.
struct CompassSettings: View {
    @Bindable var model: AppModel
    let compass: CompassController
    @ViewState<String> private var remote = ""

    private var config: CompassConfig { compass.config }

    var body: some View {
        if compass.isSetUp {
            form
        } else {
            VStack(spacing: 12) {
                Text("Compass isn't set up on this Mac yet.").font(.headline)
                Text("Open Compass in the main window (⌥⌘1) to start it or restore it from a backup.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Compass") {
                    model.mode = .compass
                    model.showMainWindow()
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var form: some View {
        Form {
            Section("Schedule") {
                Toggle("Update the page on schedule", isOn: binding(\.enabled))
                Picker("Runs", selection: binding(\.schedule.kind)) {
                    Text("Only when I run it").tag(CompassSchedule.Kind.manual)
                    Text("Once a day").tag(CompassSchedule.Kind.daily)
                    Text("Every so often").tag(CompassSchedule.Kind.interval)
                }
                .disabled(!config.enabled)
                switch config.schedule.kind {
                case .manual:
                    EmptyView()
                case .daily:
                    timePicker("At", binding(\.schedule.at))
                    days
                case .interval:
                    Picker("Every", selection: binding(\.schedule.every)) {
                        ForEach(Self.intervals(including: config.schedule.every), id: \.self) { minutes in
                            Text(minutes % 60 == 0 ? (minutes == 60 ? "hour" : "\(minutes / 60) hours") : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    timePicker("From", binding(\.schedule.from))
                    timePicker("To", binding(\.schedule.to))
                    days
                }
                Text("Shepherdr must be open to run Compass. A missed run happens once, later the same day.")
                    .help("A run also waits while you're typing to the agent.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Agent") {
                Picker("Agent", selection: binding(\.agent)) {
                    ForEach(NewSessionRequest.agentKinds, id: \.self) { kind in Text(AgentProgram(label: kind).name).tag(kind) }
                }
                Text("Takes effect the next day, when a fresh agent starts.")
                    .help("Claude Code reads its permissions from .claude/settings.json in the folder; other agents ask as they usually do.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Folder") {
                    HStack(spacing: 8) {
                        Text((compass.folder.root.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary)
                        Button("Open") { NSWorkspace.shared.open(compass.folder.root) }
                        Button("Edit prompt.md") { NSWorkspace.shared.open(compass.folder.promptURL) }
                    }
                }
            }
            Section("Page") {
                timePicker("Page shows hours from", binding(\.strip.from))
                timePicker("Page shows hours to", binding(\.strip.to))
                LabeledContent("Template") {
                    HStack(spacing: 8) {
                        Text(compass.templateIsCustomized ? "Yours: Shepherdr doesn't update it" : "Shepherdr's").foregroundStyle(.secondary)
                        if compass.templateIsCustomized {
                            Button("Restore Shepherdr's") { compass.restoreTemplate() }
                        }
                    }
                }
                Text("Each day starts from a fresh copy of the template; earlier pages keep their look.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Backup") {
                if compass.hasGit {
                    TextField("Git remote", text: $remote, prompt: Text("git@github.com:you/compass.git"))
                        .onSubmit(saveRemote)
                    HStack {
                        Button("Save") { saveRemote() }
                            .disabled(remote.trimmingCharacters(in: .whitespaces) == (config.backup ?? ""))
                        Button("Back Up Now") { compass.backUpNow() }
                            .disabled(compass.backup == .working)
                        Spacer()
                        backupStatus
                    }
                    if compass.remoteIsPublic {
                        Text("⚠︎ This repository is public. Your Compass pages summarize your day: make it private on GitHub.")
                            .font(.caption).foregroundStyle(Theme.amber)
                    }
                    Text("Every run is saved in Git, and pushed to the remote if you set one, so a new Mac can restore your pages. Use a private remote, with its SSH key loaded in your agent: Git never asks for a password.")
                        .help("For HTTPS, use a credential helper instead.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Backups need Git. Install it with xcode-select --install, or with Homebrew.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { remote = config.backup ?? "" }
    }

    @ViewBuilder private var backupStatus: some View {
        switch compass.backup {
        case .none: EmptyView()
        case .working: Text("Backing up…").font(.caption).foregroundStyle(.secondary)
        case .done(let date): Text("Done at \(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        case .failed(let message): Text(message).font(.caption).foregroundStyle(Theme.amber).lineLimit(3).textSelection(.enabled)
        }
    }

    private var days: some View {
        LabeledContent("On") {
            HStack(spacing: 4) {
                ForEach(Weekday.allCases, id: \.self) { day in
                    let on = config.schedule.days.contains(day)
                    Button(day.rawValue.capitalized) {
                        compass.update { config in
                            var days = config.schedule.days
                            if on { days.removeAll { $0 == day } } else { days.append(day) }
                            config.schedule.days = Weekday.allCases.filter(days.contains)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(on ? Theme.phosphor : nil)
                    .controlSize(.small)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private func saveRemote() {
        let trimmed = remote.trimmingCharacters(in: .whitespaces)
        compass.update { $0.backup = trimmed.isEmpty ? nil : trimmed }
    }

    private func binding<Value: Equatable>(_ path: WritableKeyPath<CompassConfig, Value>) -> Binding<Value> {
        Binding { compass.config[keyPath: path] } set: { value in compass.update { $0[keyPath: path] = value } }
    }

    /// Times every half hour, plus the one already set.
    private func timePicker(_ label: String, _ selection: Binding<ClockTime>) -> some View {
        let times = (0..<48).map { ClockTime(hour: $0 / 2, minute: $0 % 2 * 30) }
        let all = times.contains(selection.wrappedValue) ? times : (times + [selection.wrappedValue]).sorted()
        return Picker(label, selection: selection) {
            ForEach(all, id: \.self) { time in Text(time.description).tag(time) }
        }
    }

    private static func intervals(including current: Int) -> [Int] {
        CompassSchedule.everyChoices.contains(current) ? CompassSchedule.everyChoices : (CompassSchedule.everyChoices + [current]).sorted()
    }
}
