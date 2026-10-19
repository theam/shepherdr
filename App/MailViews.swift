import AppKit
import SwiftUI
import ShepherdrCore

/// Offers the agent tools on a session's machine: to install them, or to update them.
struct ToolsOfferBanner: View {
    let machineID: String
    let courier: Courier
    let machineName: String

    var body: some View {
        if let offer = courier.offer(for: machineID) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "shippingbox").font(.system(size: 11, weight: .semibold))
                Text(message(offer)).font(Theme.mono(11.5)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                buttons(offer)
            }
            .foregroundStyle(isFailure(offer) ? Theme.red : Theme.amber)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background((isFailure(offer) ? Theme.red : Theme.amber).opacity(0.08))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
        }
    }

    private var place: String { machineID == Machine.local.id ? "this Mac" : machineName }

    private func isFailure(_ offer: Courier.Offer) -> Bool { if case .failed = offer { true } else { false } }

    private func message(_ offer: Courier.Offer) -> String {
        switch offer {
        case .install:
            "Shepherdr's agent tools aren't on \(place). With them, agents there can start sessions and hand work back."
        case .update:
            "The agent tools on \(place) are older than this Shepherdr's."
        case .working(let text):
            text
        case .failed(let text):
            "Couldn't install the agent tools on \(place): \(text)"
        }
    }

    @ViewBuilder private func buttons(_ offer: Courier.Offer) -> some View {
        switch offer {
        case .install:
            Button("INSTALL") { courier.install(machineID) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.amber, prominent: true))
                .help("Copy the shepherdr command and its skill for Claude Code and Codex to \(place), over SSH. Only ~/.shepherdr and the agents' skill folders change.")
            Button("NOT NOW") { courier.tools.postpone(machineID) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
                .help("Ask again next time Shepherdr starts")
            Button("DON'T ASK HERE") { courier.tools.setDeclined(machineID, true) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                .help("Never offer them for \(place). Settings → Agents installs them later.")
        case .update:
            Button("UPDATE") { courier.install(machineID) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.amber, prominent: true))
            Button("NOT NOW") { courier.tools.postpone(machineID) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.amber))
        case .working:
            ProgressView().controlSize(.small)
        case .failed:
            Button("RETRY") { courier.install(machineID) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.red))
            Button("NOT NOW") { courier.tools.postpone(machineID) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
        }
    }
}

/// Letters waiting for you or for a session: handoffs to let through or address, sessions other
/// machines ask for, pages they suggest, and deliveries on their way. In a session it lists that
/// session's mail; on the overview, everything that needs you.
struct MailPanel: View {
    /// The session whose mail to list; nil for all mail that needs you.
    let session: Agent.ID?
    let model: AppModel

    private var courier: Courier { model.courier }
    private var items: [MailItem] {
        if let session { return courier.mail.items(for: session) }
        return courier.mail.needingUser
    }

    var body: some View {
        let notices = session == nil ? courier.notices : []
        if !items.isEmpty || !notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in row(item) }
                ForEach(Array(notices.enumerated()), id: \.offset) { index, notice in
                    HStack(spacing: 8) {
                        Image(systemName: "envelope.badge").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.red)
                        Text(notice).font(Theme.mono(10.5)).foregroundStyle(Theme.text.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        Spacer(minLength: 8)
                        Button("OK") { courier.dismissNotice(at: index) }.buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    }
                }
            }
            .padding(.horizontal, session == nil ? 14 : 16).padding(.vertical, 8)
            .background(Theme.amber.opacity(0.05), in: RoundedRectangle(cornerRadius: session == nil ? 6 : 0))
            .overlay {
                if session == nil { RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.amber.opacity(0.3), lineWidth: 1) }
            }
            .overlay(alignment: .bottom) { if session != nil { Rectangle().fill(Theme.line).frame(height: 1) } }
        }
    }

    private func tint(_ item: MailItem) -> Color {
        switch item.status {
        case .needsApproval, .needsRecipient: Theme.amber
        case .queued: Theme.cyan
        case .failed: Theme.red
        }
    }

    private func row(_ item: MailItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: item.kind == .spawnRequest ? "plus.rectangle.on.rectangle" : item.kind == .openPage ? "safari"
                              : item.kind == .close ? "xmark.rectangle" : "envelope.fill")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(tint(item)).frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title(item)).font(Theme.mono(9.5, .bold)).tracking(1).foregroundStyle(tint(item))
                    Text(origin(item)).font(Theme.mono(10)).foregroundStyle(Theme.faint)
                    Text(item.received.formatted(date: .omitted, time: .shortened)).font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
                }
                if let detail = detail(item) {
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.text.opacity(0.85)).lineLimit(2)
                        .textSelection(.enabled)
                }
                if let status = status(item) {
                    Text(status).font(Theme.mono(10)).foregroundStyle(Theme.dim).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            actions(item)
        }
    }

    private func title(_ item: MailItem) -> String {
        switch item.kind {
        case .handoff: "HANDOFF"
        case .prompt: "FIRST PROMPT"
        case .spawnRequest: "SESSION REQUEST"
        case .openPage: "PAGE"
        case .close: "CLOSE REQUEST"
        }
    }

    private func origin(_ item: MailItem) -> String {
        let from = [item.senderName, "on \(item.originName)"].compactMap { $0 }.joined(separator: " ")
        guard session == nil || item.recipient != session || item.kind == .openPage else { return "from \(from)" }
        if let recipient = item.recipient, let row = model.row(for: recipient), item.kind != .openPage {
            return "from \(from) → \(row.workspace)"
        }
        return "from \(from)"
    }

    private func detail(_ item: MailItem) -> String? {
        switch item.kind {
        case .handoff, .prompt:
            let files = item.files.isEmpty ? nil : item.files.count == 1 ? "1 file" : "\(item.files.count) files"
            return [item.headline, files].compactMap { $0 }.joined(separator: " · ").nonEmpty
        case .spawnRequest:
            guard let request = item.request else { return nil }
            let what = request.agent ?? "a shell"
            return "\(what) on \(request.machine), in \(request.directory)" + (item.hasMessage ? " · with a prompt" : "")
        case .openPage:
            return item.url?.absoluteString
        case .close:
            let target = item.recipient.flatMap { model.row(for: $0) }.map(\.workspace) ?? item.addressedTo ?? "a session"
            return "Close \(target): its pane and its agent end."
        }
    }

    private func status(_ item: MailItem) -> String? {
        switch item.status {
        case .needsApproval:
            switch item.kind {
            case .handoff: return "It comes from another machine: let it through to deliver it."
            case .close:
                let who = item.sender == item.recipient ? "Its own agent" : "An agent"
                return "\(who) asked for this. It closes only when you press CLOSE."
            default: return nil
            }
        case .needsRecipient:
            return item.problem ?? "Choose the session it goes to."
        case .queued:
            if item.kind == .spawnRequest { return "Starting…" }
            let who = item.recipient.flatMap { model.row(for: $0) }.map(\.workspace) ?? "its session"
            return "Shepherdr delivers it when \(who) is free."
        case .failed:
            return item.problem
        }
    }

    @ViewBuilder private func actions(_ item: MailItem) -> some View {
        HStack(spacing: 6) {
            if item.hasMessage || !item.files.isEmpty, item.kind == .handoff || item.kind == .prompt || item.kind == .spawnRequest {
                Button("VIEW") { view(item) }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
                    .help("Read the message and its files before letting it through")
            }
            switch item.status {
            case .needsApproval:
                Button(item.kind == .spawnRequest ? "START" : item.kind == .openPage ? "OPEN" : item.kind == .close ? "CLOSE" : "LET THROUGH") {
                    courier.approve(item)
                }
                    .buttonStyle(ConsoleButtonStyle(tint: Theme.amber, prominent: true))
            case .needsRecipient:
                Menu {
                    ForEach(model.rankedRows.filter { $0.id != item.sender }) { row in
                        Button(model.showsMachineNames ? "\(row.workspace) @\(row.machineName)" : row.workspace) {
                            courier.send(item, to: row.id)
                        }
                    }
                } label: {
                    Text("SEND TO ▾").font(Theme.mono(11, .semibold))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .tint(Theme.background)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Theme.amber, in: RoundedRectangle(cornerRadius: 4))
                .help("Choose the session it goes to")
            case .failed:
                if item.kind != .openPage, item.kind != .close {
                    Button("RETRY") { courier.approve(item) }.buttonStyle(ConsoleButtonStyle(tint: Theme.red))
                }
            case .queued:
                EmptyView()
            }
            Button("DISCARD") { courier.discard(item) }
                .buttonStyle(ConsoleButtonStyle(tint: Theme.dim))
        }
    }

    /// Opens the message in the session's browser when it is on this Mac's screen, else in its app.
    private func view(_ item: MailItem) {
        let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
        let file = item.hasMessage ? folder.appendingPathComponent("message.md") : folder.appendingPathComponent(item.files[0])
        if let session {
            model.openLink(file, from: session, external: false)
        } else {
            NSWorkspace.shared.open(file)
        }
    }
}

/// An envelope beside a session in the queue: amber when its mail waits for you, cyan when a
/// delivery waits for it to be free.
struct MailMark: View {
    let session: Agent.ID
    let courier: Courier

    var body: some View {
        let items = courier.mail.items(for: session)
        if items.contains(where: \.needsUser) {
            Image(systemName: "envelope.fill").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.amber)
                .help("Mail waits for you here")
        } else if !items.isEmpty {
            Image(systemName: "envelope").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.cyan)
                .help("Shepherdr delivers mail here once the session is free")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
