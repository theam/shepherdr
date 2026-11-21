// What the Mac encodes for the messages Android's RemoteProtocolTest checks: run scripts/golden-protocol.sh.
import Foundation
let enc = RemoteProtocol.encoder()
func p<T: Encodable>(_ v: T) { print(String(data: try! enc.encode(v), encoding: .utf8)!) }
let pane = RemoteSessionID(machineID: "remote:buildbox", terminalID: "term_1")
let client: [ClientMessage] = [
  .hello(deviceID: "d", token: "t", version: 1), .pair(code: "c", deviceName: "Phone", version: 1),
  .attach(channel: 3, pane: pane, columns: 52, rows: 30), .takeOver(channel: 3), .detach(channel: 3),
  .input(channel: 3, bytes: Data([27, 0, 255])), .resize(channel: 3, columns: 60, rows: 20), .scroll(channel: 3, up: true, lines: 10),
  .prompt(pane: pane, text: "fix the flaky test\nplease"), .compassRun, .compassCancel,
  .compassPage(day: nil), .compassPage(day: "2026-11-02"), .ping]
print("#CLIENT"); for m in client { p(m) }
let row = QueueRow(id: "s:1", kind: .session, session: pane, number: 1, depth: 2, title: "fix-login", status: "needsYou",
  panes: [RemotePane(pane: pane, title: "claude", isAgent: true)],
  tree: QueueTree(depth: 1, guides: [true], isLast: false, nested: 2), inGroup: true, inProject: true,
  resources: [RemoteResource(kind: .pullRequest, name: "theam/shepherdr#12", title: "Fix login", url: "https://github.com/theam/shepherdr/pull/12", state: "open", checks: "passed")])
let compass = RemoteCompass(activity: "✓ updated 09:00", needsYou: false, isRunning: false, next: "next run 14:00", problem: nil, hasNews: true,
  pageModified: Date(timeIntervalSinceReferenceDate: 800_000_000), today: "2026-11-02", days: ["2026-11-02", "2026-11-01"], agent: row)
let server: [ServerMessage] = [
  .welcome(macName: "Studio", version: 1), .paired(deviceID: "d", token: "t", macName: "Studio"), .refused(reason: "No"),
  .queue(QueueSnapshot(macName: "Studio", machines: [RemoteMachine(id: "local", name: "Local", connection: "online", isOnline: true)], rows: [row, QueueRow(id: "g:1", kind: .group, title: "Release", needsYou: 2)], compass: compass)),
  .terminal(channel: 3, state: .controlledElsewhere, message: nil), .terminal(channel: 4, state: .ended, message: "bye"), .reset(channel: 3), .failure(message: "x"),
  .compassPage(day: "2026-11-02", html: "<h1>Today</h1>"), .compassPage(day: "2026-10-30", html: nil), .pong]
print("#SERVER"); for m in server { p(m) }
let invite = PairingInvite(macName: "Javier’s MacBook Pro", hosts: ["100.101.102.103", "192.168.1.20"], port: 1337, fingerprint: "abc-_123", code: "c0de")
print("#INVITE"); print(invite.url.absoluteString)
print("#FINGERPRINT"); let point = Data([4] + (1...64).map { UInt8($0) }); print(RemoteCrypto.fingerprint(publicKey: point))
