import SwiftUI
import ShepherdrCore

/// Chooses the repositories the home screen's GitHub inbox follows. GitHub confirms each one
/// before it joins, under the name it gives it now.
struct GitHubRepositoriesSheet: View {
    @Bindable var model: AppModel
    @ViewState<String> private var text = ""
    @ViewState<Bool> private var isValidating = false
    @ViewState<GitHubSyncError?> private var failure: GitHubSyncError? = nil
    @ViewState private var gitHub = GitHubLookup()
    @FocusState private var focused: Bool

    private var store: GitHubInboxStore { model.githubInbox }
    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidating }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                PixelFlock(pixel: 1.5)
                VStack(alignment: .leading, spacing: 3) {
                    Text("GITHUB REPOSITORIES").font(Theme.mono(15, .bold)).tracking(2).foregroundStyle(Theme.text)
                    Text("issues and pull requests that ask something of you").font(Theme.mono(10.5))
                        .foregroundStyle(Theme.dim).lineLimit(1)
                }
            }

            field("Add repository") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        consoleTextField("owner/repo or a github.com link", text: $text)
                            .focused($focused)
                            .onSubmit { add() }
                        Button("ADD") { add() }
                            .buttonStyle(ConsoleButtonStyle())
                            .disabled(!canAdd)
                    }
                    if isValidating {
                        HStack(spacing: 0) {
                            Text("asking GitHub…").font(Theme.mono(10.5)).foregroundStyle(Theme.phosphor)
                            BlinkingCursor()
                        }
                    } else if let failure {
                        let reason = Self.reason(failure)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("✗ \(reason.message)").font(Theme.mono(11)).foregroundStyle(Theme.red)
                            if let detail = reason.detail {
                                Text(detail).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(4).textSelection(.enabled)
                            }
                        }
                    }
                }
            }

            field("Following") {
                if store.repositories.isEmpty {
                    Text("No repositories yet. Add one above.").font(Theme.mono(11)).foregroundStyle(Theme.faint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(store.repositories) { watched in row(watched) }
                        }
                    }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
                }
            }

            HStack {
                Spacer()
                Button("DONE") { model.showsGitHubRepositoriesSheet = false }
                    .buttonStyle(ConsoleButtonStyle(prominent: true))
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.panel)
        .onAppear { focused = true }
    }

    private func row(_ watched: WatchedRepository) -> some View {
        HStack(spacing: 8) {
            Text(watched.repository.displayName).font(Theme.mono(11.5, .medium))
                .foregroundStyle(watched.isPaused ? Theme.faint : Theme.text).lineLimit(1).truncationMode(.middle)
            if watched.isPaused {
                Text("PAUSED").font(Theme.mono(9, .semibold)).tracking(1).foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 4)
            Button(watched.isPaused ? "RESUME" : "PAUSE") {
                store.setPaused(watched.repository, !watched.isPaused)
            }
            .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
            .help(watched.isPaused ? "Ask GitHub about it again" : "Keep it on the list without asking GitHub about it")
            Button("REMOVE") { store.remove(watched.repository) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.red))
                .help("Stop following it and forget which of its items you saw")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func add() {
        guard canAdd else { return }
        let typed = text
        isValidating = true
        failure = nil
        Task {
            let result = await gitHub.validate(repository: typed)
            isValidating = false
            switch result {
            case .success(let repository):
                store.add(repository)
                if text == typed { text = "" }
            case .failure(let error):
                failure = error
            }
            focused = true
        }
    }

    /// Why a repository couldn't be added: the reason itself, not a sync headline.
    private static func reason(_ error: GitHubSyncError) -> (message: String, detail: String?) {
        if case .failed(let message) = error { return (message, nil) }
        let notice = error.notice
        return (notice.title, notice.detail ?? notice.message)
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased()).font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.faint)
            content()
        }
    }

    private func consoleTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain).font(Theme.mono(12)).foregroundStyle(Theme.text)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.line, lineWidth: 1))
    }
}
