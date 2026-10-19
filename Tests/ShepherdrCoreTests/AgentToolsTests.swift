import CryptoKit
import Foundation
import Testing
@testable import ShepherdrCore

/// A scratch home with the tools installed the way Shepherdr installs them, and a fake herdr.
private struct ScratchHome {
    let url: URL
    let herdr: URL
    var path: String { url.path }

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("shepherdr-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // The fake herdr lives beside the shell tests, in the source tree.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentTools/fake-herdr")
        herdr = url.appendingPathComponent("herdr")
        try FileManager.default.copyItem(at: source, to: herdr)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: herdr.path)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }

    /// Runs sh with this home, as Shepherdr's scripts run on a machine.
    @discardableResult
    func sh(_ arguments: [String], input: String? = nil, environment: [String: String] = [:]) throws -> (out: String, data: Data, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = arguments
        var env = ["HOME": path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HERDR_BIN_PATH": herdr.path,
                   "FAKE_HERDR_LOG": url.appendingPathComponent("herdr.log").path, "TMPDIR": path]
        env.merge(environment) { _, new in new }
        process.environment = env
        process.currentDirectoryURL = url
        let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: out, as: UTF8.self), out, String(decoding: err, as: UTF8.self), process.terminationStatus)
    }

    /// Runs the installed CLI as an agent in pane w1:p1.
    func shepherdr(_ arguments: [String], input: String? = nil) throws -> (out: String, data: Data, err: String, status: Int32) {
        try sh([path + "/.shepherdr/bin/shepherdr"] + arguments, input: input, environment: ["HERDR_ENV": "1", "HERDR_PANE_ID": "w1:p1"])
    }
}

struct AgentToolsTests {
    private let remote = Machine(profileID: "3c9e10aa", name: "buildbox", target: "box", session: "agents", isEnabled: true)
    private let other = Machine(profileID: "7b2d55f0", name: "Homelab", target: "micro", session: "default", isEnabled: true)

    @Test func shepherdrCarriesTheCommandLineAndTheSkill() throws {
        let kit = try AgentTools.bundled()
        #expect(kit.version >= 1)
        #expect(kit.files["bin/shepherdr"]?.hasPrefix("#!/bin/sh") == true)
        let skill = try #require(kit.files["skills/shepherdr/SKILL.md"])
        #expect(skill.hasPrefix("---\nname: shepherdr\ndescription: "))
        // The skill never names machines: they change, the skill only changes with the tools.
        #expect(!skill.contains("Homelab"))
    }

    @Test func installingPutsTheToolsTheSkillsAndTheListInPlace() throws {
        let home = try ScratchHome()
        defer { home.remove() }
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        let kit = try AgentTools.bundled()
        let list = MachineList.render(MachineList.entries(for: remote, machines: [.local, remote, other], macName: "Studio"))
        let script = try AgentTools.installScript(kit, list: list)

        let installed = try home.sh(["-s"], input: script)
        #expect(installed.status == 0, "\(installed.err)")
        #expect(installed.out.contains("shepherdr-skill claude"))
        #expect(!installed.out.contains("shepherdr-skill codex"))
        #expect(installed.out.contains("shepherdr-installed \(kit.version)"))
        let root = home.url.appendingPathComponent(".shepherdr")
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("bin/shepherdr").path))
        #expect(try String(contentsOf: root.appendingPathComponent("bin/shepherdr"), encoding: .utf8) == kit.files["bin/shepherdr"])
        #expect(try String(contentsOf: root.appendingPathComponent("machines"), encoding: .utf8) == list)
        let skill = home.url.appendingPathComponent(".claude/skills/shepherdr/SKILL.md")
        #expect(try String(contentsOf: skill, encoding: .utf8) == kit.files["skills/shepherdr/SKILL.md"])
        let permissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        // Nothing half-installed is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".") }
        #expect(leftovers.isEmpty)

        // A check sees what was installed; Codex arriving later lacks the skill.
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let check = try AgentTools.parseCheck(home.sh(["-c", AgentTools.checkScript]).out)
        #expect(check.version == kit.version)
        #expect(check.listRevision == MachineList.revision(of: MachineList.entries(for: remote, machines: [.local, remote, other], macName: "Studio")))
        #expect(check.system?.isEmpty == false)
        #expect(check.agents == [.init(name: "claude", isPresent: true, hasSkill: true), .init(name: "codex", isPresent: true, hasSkill: false)])
        #expect(check.lacksSkill)
        #expect(check.waitingLetters == 0)

        // Installing again replaces the tools in place, and adds the missing skill.
        #expect(try home.sh(["-s"], input: AgentTools.installScript(kit, list: nil)).status == 0)
        #expect(try AgentTools.parseCheck(home.sh(["-c", AgentTools.checkScript]).out).lacksSkill == false)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("machines").path))

        // The CLI reads the list as written.
        let machines = try home.shepherdr(["machines"])
        #expect(machines.out.contains("You are on buildbox."))
        #expect(machines.out.contains("Studio                   shepherdr  asks the user to approve it in Shepherdr"))

        // Removing leaves only letters behind.
        #expect(try home.sh(["-c", AgentTools.uninstallScript]).out.contains("shepherdr-removed"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("bin").path))
        #expect(!FileManager.default.fileExists(atPath: skill.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("outbox").path))
        #expect(try AgentTools.parseCheck(home.sh(["-c", AgentTools.checkScript]).out).version == nil)
    }

    /// Machines only update their tools when this Shepherdr's version is greater than theirs, so
    /// every change to the command or the skill needs a new `VERSION`. Each version keeps its
    /// fingerprint here: after bumping it, add the new one this test prints.
    @Test func changingTheToolsTakesANewVersion() throws {
        // 3, with `shepherdr run`, only reached test builds; 4 replaces it on their machines.
        let fingerprints = [1: "421ecfaa5c879c75", 2: "6e89f6a3e43a9be2", 4: "7ced138f11461d6a", 5: "67acf304fec8b032"]
        let kit = try AgentTools.bundled()
        var hash = SHA256()
        for path in kit.files.keys.sorted() where path != "VERSION" {
            hash.update(data: Data((path + "\n" + (kit.files[path] ?? "") + "\n").utf8))
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined().prefix(16)
        #expect(fingerprints[kit.version] == String(fingerprint),
                "The agent tools don't match version \(kit.version)'s fingerprint. If you changed them, bump AgentTools/VERSION, then add the new version with \"\(fingerprint)\".")
    }

    @Test func checksAreReadLineByLineAfterAnyBanner() throws {
        let check = try AgentTools.parseCheck("""
        Welcome to box!
        shepherdr-tools 3
        shepherdr-list 3f2a9c1b7e04
        shepherdr-system Linux x86_64
        shepherdr-agent claude yes yes
        shepherdr-agent codex no no
        shepherdr-agent other yes yes
        shepherdr-outbox 2
        """)
        #expect(check.version == 3)
        #expect(check.listRevision == "3f2a9c1b7e04")
        #expect(check.system == "Linux x86_64")
        #expect(check.agents.map(\.name) == ["claude", "codex"])
        #expect(check.waitingLetters == 2)
        let missing = try AgentTools.parseCheck("shepherdr-tools -\nshepherdr-list -\n")
        #expect(missing.version == nil && missing.listRevision == nil)
        #expect(throws: HerdrFailure.self) { try AgentTools.parseCheck("bash: sh: command not found") }
    }

    @Test func eachMachineGetsItsOwnViewOfTheOthers() {
        let disabled = Machine(profileID: "off", name: "attic", target: "attic", session: "default", isEnabled: false)
        let all: [Machine] = [.local, remote, other, disabled]
        let mac = MachineList.entries(for: .local, machines: all, macName: "Studio")
        #expect(mac == [.init(name: "Studio", route: .here, profile: nil),
                        .init(name: "buildbox", route: .direct, profile: "3c9e10aa"),
                        .init(name: "Homelab", route: .direct, profile: "7b2d55f0")])
        let box = MachineList.entries(for: remote, machines: all, macName: "Studio")
        #expect(box == [.init(name: "buildbox", route: .here, profile: nil),
                          .init(name: "Studio", route: .shepherdr, profile: nil),
                          .init(name: "Homelab", route: .shepherdr, profile: nil)])
        #expect(MachineList.entries(for: remote, machines: all, macName: "Studio", shares: false) == [.init(name: "buildbox", route: .here, profile: nil)])

        // Revisions follow the content, not the time it was written.
        #expect(MachineList.revision(of: box) == MachineList.revision(of: MachineList.entries(for: remote, machines: all, macName: "Studio")))
        #expect(MachineList.revision(of: box) != MachineList.revision(of: MachineList.entries(for: remote, machines: all, macName: "Desk")))
        let text = MachineList.render(box, at: Date(timeIntervalSince1970: 1_760_523_302))
        #expect(text == "# shepherdr machines 1 rev \(MachineList.revision(of: box)) 2025-10-15T10:15:02Z\nbuildbox\there\t-\nStudio\tshepherdr\t-\nHomelab\tshepherdr\t-\n")
    }

    @Test func namesInTheListAreOneLineAndUnique() {
        let twin = Machine(profileID: "twin", name: "BUILDBOX", target: "t", session: "default", isEnabled: true)
        let tabbed = Machine(profileID: "tab", name: "a\tb\nc", target: "t", session: "default", isEnabled: true)
        let names = MachineList.uniqueNames([.local, remote, twin, tabbed], macName: "  ")
        #expect(names == ["local": "machine", remote.id: "buildbox", twin.id: "BUILDBOX 2", tabbed.id: "a b c"])
    }

    @Test func installingQuotesNothingAndTravelsAsOneScript() throws {
        let kit = AgentTools.Kit(version: 7, files: ["VERSION": "7\n", "bin/shepherdr": "#!/bin/sh\necho \"$HOME\" `x` $(y)\n",
                                                    "skills/shepherdr/SKILL.md": "no trailing newline"])
        let home = try ScratchHome()
        defer { home.remove() }
        #expect(try home.sh(["-s"], input: AgentTools.installScript(kit, list: nil)).status == 0)
        let cli = try String(contentsOfFile: home.path + "/.shepherdr/bin/shepherdr", encoding: .utf8)
        #expect(cli == "#!/bin/sh\necho \"$HOME\" `x` $(y)\n")
        #expect(try String(contentsOfFile: home.path + "/.shepherdr/VERSION", encoding: .utf8) == "7\n")
    }

    @Test func remoteScriptsRunOverSSHWithoutForwardingAndLongOnesReadStandardInput() throws {
        let command = try #require(remote.shellReadingStandardInput())
        #expect(command.executable.path == "/usr/bin/ssh")
        #expect(command.arguments.contains("BatchMode=yes") && command.arguments.contains("ForwardAgent=no"))
        #expect(Array(command.arguments.suffix(3)) == ["--", "box", "sh -s"])
        #expect(Machine.local.shellReadingStandardInput()?.arguments == ["-s"])
    }
}

/// The CLI writes letters and Shepherdr reads them: both ends of the format, end to end.
struct LetterContractTests {
    private func installed() throws -> ScratchHome {
        let home = try ScratchHome()
        let list = MachineList.render(MachineList.entries(for: .local, machines: [.local], macName: "Studio"))
        #expect(try home.sh(["-s"], input: AgentTools.installScript(AgentTools.bundled(), list: list)).status == 0)
        return home
    }

    private func collect(_ home: ScratchHome) throws -> Mailbox.Delivery {
        let output = try home.sh(["-c", Mailbox.collectScript, "sh", String(Mailbox.tripLimit)])
        #expect(output.status == 0, "\(output.err)")
        // Attachments may be binary: read the stream as bytes.
        return try Mailbox.parse(output.data)
    }

    @Test func aHandoffArrivesWithItsMessageAndFiles() throws {
        let home = try installed()
        defer { home.remove() }
        try "# Report\nAll green.\n".write(toFile: home.path + "/REPORT.md", atomically: true, encoding: .utf8)
        try Data([0, 1, 2, 255]).write(to: home.url.appendingPathComponent("trace.bin"))
        let sent = try home.shepherdr(["handoff", "--file", "REPORT.md", "--file", "trace.bin", "PR opened: theam/api#41"])
        #expect(sent.status == 0, "\(sent.err)")

        let delivery = try collect(home)
        #expect(delivery.hasMore == false)
        let collected = try #require(delivery.letters.first)
        let letter = try Letter(id: collected.id, contents: collected.contents)
        #expect(letter.content == .handoff(to: nil))
        #expect(letter.sender == .init(paneID: "w1:p1", terminalID: "term_caller1"))
        #expect(letter.message == "PR opened: theam/api#41\n")
        #expect(letter.files == ["files/REPORT.md", "files/trace.bin"])
        #expect(collected.contents["files/trace.bin"] == Data([0, 1, 2, 255]))
        // The doorbell rang with the letter's ID.
        let log = try String(contentsOfFile: home.path + "/herdr.log", encoding: .utf8)
        #expect(log.contains("shepherdr-mail=\(letter.id)"))

        // Filing it moves it aside; the next trip finds nothing.
        let filed = try home.sh(["-c", Mailbox.acknowledgeScript, "sh", letter.id, "../escape"])
        #expect(filed.out.contains("shepherdr-acknowledged"))
        #expect(FileManager.default.fileExists(atPath: home.path + "/.shepherdr/outbox/.collected/\(letter.id)/letter.json"))
        #expect(try collect(home).letters.isEmpty)
    }

    @Test func everyKindOfLetterReadsBack() throws {
        let home = try installed()
        defer { home.remove() }
        let commands: [[String]] = [
            ["spawn", "--name", "api-fix", "--prompt", "Fix it"],
            ["wait-for", "reviewer", "test runner"],
            ["resume"],
            ["pin", "https://example.com/docs", "--title", "Docs \"v2\""],
            ["open", "http://localhost:3000"],
            ["notify", "Migration finished"],
            ["handoff", "--to", "planner@Studio", "Done"],
            ["close"],
            ["close", "--force", "reviewer", "test runner@buildbox"],
        ]
        for command in commands {
            let result = try home.shepherdr(command)
            #expect(result.status == 0, "\(command): \(result.err)")
        }
        let delivery = try collect(home)
        let letters = try delivery.letters.map { try Letter(id: $0.id, contents: $0.contents) }
        #expect(letters.count == commands.count)
        #expect(letters.contains { if case .spawned(let spawned) = $0.content {
            spawned == .init(machine: .here, paneID: "w9:p1", terminalID: "term_child", name: "api-fix", agent: "claude", wait: true, promptPending: false)
        } else { false } })
        #expect(letters.contains { $0.content == .wait(["reviewer", "test runner"]) })
        #expect(letters.contains { $0.content == .resume([]) })
        #expect(letters.contains { $0.content == .pin(URL(string: "https://example.com/docs")!, title: "Docs \"v2\"") })
        #expect(letters.contains { $0.content == .open(URL(string: "http://localhost:3000")!) })
        #expect(letters.contains { $0.content == .notify && $0.message == "Migration finished\n" })
        #expect(letters.contains { $0.content == .handoff(to: "planner@Studio") })
        #expect(letters.contains { $0.content == .close([], force: false) })
        #expect(letters.contains { $0.content == .close(["reviewer", "test runner@buildbox"], force: true) })
    }

    @Test func aTripStopsAtItsLimitsAndSaysMoreAreWaiting() throws {
        let home = try installed()
        defer { home.remove() }
        for index in 0..<3 { #expect(try home.shepherdr(["notify", "Letter \(index)"]).status == 0) }
        let first = try #require(try outbox(of: home).first)
        let output = try home.sh(["-c", Mailbox.collectScript, "sh", String(try size(of: first))])
        let delivery = try Mailbox.parse(Data(output.out.utf8))
        // The first letter fills the trip; the next would pass the limit.
        #expect(delivery.letters.map(\.id) == [first.lastPathComponent])
        #expect(delivery.hasMore)
    }

    @Test func aLetterTooLargeForAnyTripIsSetAsideNotStreamed() throws {
        let home = try installed()
        defer { home.remove() }
        for index in 0..<2 { #expect(try home.shepherdr(["notify", "Letter \(index)"]).status == 0) }
        let letters = try outbox(of: home)
        try FileManager.default.createDirectory(at: letters[0].appendingPathComponent("files"), withIntermediateDirectories: true)
        try Data(count: 4_000).write(to: letters[0].appendingPathComponent("files/huge.bin"))
        let output = try home.sh(["-c", Mailbox.collectScript, "sh", "1000"])
        let delivery = try Mailbox.parse(Data(output.out.utf8))
        // It doesn't hold up the letter after it.
        #expect(delivery.letters.map(\.id) == letters.map(\.lastPathComponent))
        #expect(delivery.letters[0].oversize == (try size(of: letters[0])) && delivery.letters[0].contents.isEmpty)
        #expect(delivery.letters[1].oversize == nil && delivery.letters[1].contents["letter.json"] != nil)
        #expect(!output.out.contains("huge.bin"))
    }

    private func outbox(of home: ScratchHome) throws -> [URL] {
        let outbox = home.url.appendingPathComponent(".shepherdr/outbox")
        return try FileManager.default.contentsOfDirectory(atPath: outbox.path).filter { !$0.hasPrefix(".") }.sorted()
            .map { outbox.appendingPathComponent($0) }
    }

    private func size(of letter: URL) throws -> Int {
        let files = try FileManager.default.subpathsOfDirectory(atPath: letter.path)
        return try files.reduce(0) { total, path in
            let attributes = try FileManager.default.attributesOfItem(atPath: letter.appendingPathComponent(path).path)
            return total + (attributes[.type] as? FileAttributeType == .typeRegular ? (attributes[.size] as? Int ?? 0) : 0)
        }
    }

    @Test func onlyTheFilesTheCLIWritesCross() throws {
        let home = try installed()
        defer { home.remove() }
        #expect(try home.shepherdr(["notify", "hello"]).status == 0)
        let outbox = home.url.appendingPathComponent(".shepherdr/outbox")
        let letter = try #require(try FileManager.default.contentsOfDirectory(atPath: outbox.path).first { !$0.hasPrefix(".") })
        let folder = outbox.appendingPathComponent(letter)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true)
        try "secret".write(to: home.url.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("files/link.txt"), withDestinationURL: home.url.appendingPathComponent("secret"))
        try "x".write(to: folder.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try "y".write(to: folder.appendingPathComponent("files/.hidden"), atomically: true, encoding: .utf8)
        let delivery = try collect(home)
        #expect(Set(delivery.letters.first?.contents.keys.map { $0 } ?? []) == ["letter.json", "message.md"])
    }
}

struct MailboxStreamTests {
    @Test func streamsSurviveBannersAndRejectSurprises() throws {
        let stream = "Last login: today\nshepherdr-mail 1\nL 20261015T101502Z-7f3a9c\nF 2 letter.json\n{}\nF 3 files/a.md\nab\n\nD 1\n"
        let delivery = try Mailbox.parse(Data(stream.utf8))
        #expect(delivery.hasMore)
        #expect(delivery.letters == [.init(id: "20261015T101502Z-7f3a9c", contents: ["letter.json": Data("{}".utf8), "files/a.md": Data("ab\n".utf8)])])
        for bad in ["shepherdr-mail 1\nF 2 letter.json\n{}\nD 0\n",               // a file outside a letter
                    "shepherdr-mail 1\nL x\nF 9 letter.json\n{}\nD 0\n",          // shorter than announced
                    "shepherdr-mail 1\nL x\nF 2 ../../etc/passwd\nab\nD 0\n",     // a path outside the letter
                    "shepherdr-mail 1\nL x\n",                                    // cut short
                    "nothing here\n"] {
            #expect(throws: HerdrFailure.self) { try Mailbox.parse(Data(bad.utf8)) }
        }
        #expect(try Mailbox.parse(Data("shepherdr-mail 1\nD 0\n".utf8)).letters.isEmpty)
    }

    @Test func aLetterTooLargeComesWithoutItsFiles() throws {
        let stream = "shepherdr-mail 1\nL 20261015T101502Z-7f3a9c\nT 9000000\nL 20261015T101503Z-7f3a9c\nF 2 letter.json\n{}\nD 0\n"
        let delivery = try Mailbox.parse(Data(stream.utf8))
        #expect(delivery.letters == [.init(id: "20261015T101502Z-7f3a9c", contents: [:], oversize: 9_000_000),
                                     .init(id: "20261015T101503Z-7f3a9c", contents: ["letter.json": Data("{}".utf8)])])
        for bad in ["shepherdr-mail 1\nL x\nT 9\nF 2 letter.json\n{}\nD 0\n",   // files after all
                    "shepherdr-mail 1\nL x\nF 2 letter.json\n{}\nT 9\nD 0\n",   // too large after its files
                    "shepherdr-mail 1\nT 9\nD 0\n",                              // outside a letter
                    "shepherdr-mail 1\nL x\nT big\nD 0\n"] {
            #expect(throws: HerdrFailure.self) { try Mailbox.parse(Data(bad.utf8)) }
        }
    }

    @Test func lettersAreKeptPrivatelyOnThisMac() throws {
        let inbox = FileManager.default.temporaryDirectory.appendingPathComponent("inbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: inbox) }
        let machine = Machine(profileID: "p", name: "build box!", target: "f", session: "default", isEnabled: true)
        let letter = Mailbox.Collected(id: "20261015T101502Z-7f3a9c", contents: ["letter.json": Data("{}".utf8), "files/a.md": Data("a".utf8)])
        let folder = try Mailbox.keep(letter, from: machine, in: inbox)
        #expect(folder.path.hasSuffix("/build_box_/20261015T101502Z-7f3a9c"))
        #expect(try Data(contentsOf: folder.appendingPathComponent("files/a.md")) == Data("a".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("files/a.md").path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        // Mail still waiting keeps its letter however old it gets.
        Mailbox.tidy(inbox, keeping: [letter.id], now: Date().addingTimeInterval(31 * 86_400))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        Mailbox.tidy(inbox, now: Date().addingTimeInterval(31 * 86_400))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
