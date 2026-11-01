import Foundation

/// The command line and skill Shepherdr installs on each machine, so agents there can start
/// sessions and hand work back: `~/.shepherdr/bin/shepherdr`, a POSIX sh script that only needs
/// Herdr, and a skill for Claude Code and Codex. Shepherdr carries them and sends them over the
/// SSH connection it already uses; installing touches only `~/.shepherdr` and the agents' skill
/// folders. No shell startup files, no `sudo`, no `PATH` changes.
public enum AgentTools {
    /// The tools as this Shepherdr carries them.
    public struct Kit: Equatable, Sendable {
        public let version: Int
        /// Text files by path inside the kit, such as `bin/shepherdr`.
        public let files: [String: String]

        public init(version: Int, files: [String: String]) {
            self.version = version
            self.files = files
        }
    }

    /// What a machine has, as a check found it.
    public struct Check: Equatable, Sendable {
        public struct AgentHome: Equatable, Sendable {
            /// `claude` or `codex`.
            public let name: String
            /// The agent's folder exists: it is installed on that machine.
            public let isPresent: Bool
            public let hasSkill: Bool
        }

        /// The installed tools' version; nil when they aren't installed.
        public var version: Int?
        /// The revision of this Shepherdr's machine list there, if any.
        public var listRevision: String?
        /// `uname -sm`, such as `Linux x86_64`.
        public var system: String?
        public var agents: [AgentHome] = []
        /// Letters in the outbox that no Shepherdr has claimed yet.
        public var waitingLetters = 0

        /// An agent is installed without the skill, such as Codex installed after the tools.
        public var lacksSkill: Bool { agents.contains { $0.isPresent && !$0.hasSkill } }
    }

    /// The kit inside Shepherdr.
    public static func bundled() throws -> Kit {
        guard let folder = Bundle.module.url(forResource: "AgentTools", withExtension: nil) else {
            throw HerdrFailure(.notInstalled, "This build of Shepherdr doesn't carry the agent tools.")
        }
        return try kit(at: folder)
    }

    /// Reads a kit from a folder: every file in it, and its version.
    static func kit(at folder: URL) throws -> Kit {
        let manager = FileManager.default
        guard let walker = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw HerdrFailure(.notInstalled, "The agent tools are missing from Shepherdr.")
        }
        var files: [String: String] = [:]
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let path = String(full.dropFirst(base.count))
            guard !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            files[path] = try String(contentsOf: url, encoding: .utf8)
        }
        guard let version = files["VERSION"].flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              files["bin/shepherdr"] != nil else {
            throw HerdrFailure(.notInstalled, "The agent tools in Shepherdr are incomplete.")
        }
        return Kit(version: version, files: files)
    }

    // MARK: Checking a machine

    /// One quick trip: the installed version, the revision of the machine list of the Shepherdr
    /// given first, the system, which agents are installed with or without the skill, and how
    /// many letters wait. It touches that list too: lists nobody checked in a week are left out,
    /// for a Shepherdr that no longer runs.
    static let checkScript = """
    root="$HOME/.shepherdr"
    version=$(head -n 1 "$root/VERSION" 2>/dev/null)
    echo "shepherdr-tools ${version:--}"
    revision=
    case ${1:-} in
    '' | *[!0123456789abcdef]*) ;;
    *)
      if [ -f "$root/lists/$1" ]; then
        revision=$(head -n 1 "$root/lists/$1" | awk '{ print $6 }')
        touch "$root/lists/$1"
      fi
      ;;
    esac
    echo "shepherdr-list ${revision:--}"
    echo "shepherdr-system $(uname -sm 2>/dev/null)"
    home() {
      if [ -d "$2" ]; then present=yes; else present=no; fi
      if [ -f "$2/skills/shepherdr/SKILL.md" ]; then skill=yes; else skill=no; fi
      echo "shepherdr-agent $1 $present $skill"
    }
    home claude "$HOME/.claude"
    home codex "${CODEX_HOME:-$HOME/.codex}"
    waiting=0
    for letter in "$root"/outbox/*; do [ -d "$letter" ] && waiting=$((waiting + 1)); done
    echo "shepherdr-outbox $waiting"
    """

    /// Checks a machine for the Shepherdr with that instance ID.
    public static func check(_ machine: Machine, instance: String) async throws -> Check {
        guard let command = machine.shell(checkScript, arguments: isInstance(instance) ? [instance] : []) else {
            throw HerdrFailure(.incompatible, "Shepherdr can't reach \(machine.name) over SSH.")
        }
        let output = try await Mailbox.run(command, on: machine, action: "check the agent tools on")
        return try parseCheck(String(decoding: output.stdout, as: UTF8.self))
    }

    static func parseCheck(_ output: String) throws -> Check {
        var check = Check()
        var sawTools = false
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard fields.count == 2 else { continue }
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            switch fields[0] {
            case "shepherdr-tools":
                sawTools = true
                check.version = Int(value)
            case "shepherdr-list":
                check.listRevision = value.range(of: #"^[0-9a-f]{6,64}$"#, options: .regularExpression) != nil ? value : nil
            case "shepherdr-system":
                check.system = value.isEmpty ? nil : String(value.prefix(80))
            case "shepherdr-agent":
                let parts = value.split(separator: " ").map(String.init)
                guard parts.count == 3, ["claude", "codex"].contains(parts[0]) else { continue }
                check.agents.append(.init(name: parts[0], isPresent: parts[1] == "yes", hasSkill: parts[2] == "yes"))
            case "shepherdr-outbox":
                check.waitingLetters = max(0, Int(value) ?? 0)
            default:
                continue
            }
        }
        guard sawTools else { throw HerdrFailure(.incompatible, "The machine's answer didn't describe the agent tools.") }
        return check
    }

    // MARK: Installing

    /// A script that installs the kit from itself, so it travels as one file on standard input.
    /// Files go into a folder beside the tools first and then into place, the version file last:
    /// a half-finished install never looks complete. The skill is copied into each agent's own
    /// skills folder, for the agents installed there. The machine list goes in on the same trip.
    static func installScript(_ kit: Kit, list: String?, instance: String) throws -> String {
        let fence = "SHEPHERDR_END_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let contents = Array(kit.files.values) + [list ?? ""]
        guard !contents.contains(where: { $0.contains(fence) }) else {
            throw HerdrFailure(.incompatible, "The agent tools could not be packed for installing.")
        }
        var script = """
        set -e
        umask 077
        root="$HOME/.shepherdr"
        stage="$root/.install-$$"
        rm -rf "$stage"
        mkdir -p "$stage" "$root/outbox"

        """
        for path in kit.files.keys.sorted() where path != "VERSION" {
            guard path.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil,
                  !path.contains("..") else { continue }
            let folder = (path as NSString).deletingLastPathComponent
            if !folder.isEmpty { script += "mkdir -p \"$stage/\(folder)\"\n" }
            script += file(kit.files[path] ?? "", at: "$stage/\(path)", fence: fence)
            if path.hasPrefix("bin/") { script += "chmod 700 \"$stage/\(path)\"\n" }
        }
        script += """
        for part in bin skills; do
          rm -rf "$root/$part.old"
          if [ -e "$root/$part" ]; then mv "$root/$part" "$root/$part.old"; fi
          if [ -e "$stage/$part" ]; then mv "$stage/$part" "$root/$part"; fi
          rm -rf "$root/$part.old"
        done
        printf '%s\\n' \(kit.version) > "$root/VERSION"
        rm -rf "$stage"
        skill() {
          [ -d "$2" ] || return 0
          mkdir -p "$2/skills"
          rm -rf "$root/.skill-$$"
          cp -R "$root/skills/shepherdr" "$root/.skill-$$"
          rm -rf "$2/skills/shepherdr"
          mv "$root/.skill-$$" "$2/skills/shepherdr"
          echo "shepherdr-skill $1"
        }
        skill claude "$HOME/.claude"
        skill codex "${CODEX_HOME:-$HOME/.codex}"

        """
        if let list { script += try writeListLines(list, instance: instance, fence: fence) }
        script += "echo \"shepherdr-installed \(kit.version)\"\n"
        return script
    }

    /// Instance IDs name files on every machine: twelve hex digits, nothing else.
    static func isInstance(_ id: String) -> Bool { id.range(of: "^[0-9a-f]{12}$", options: .regularExpression) != nil }

    private static func file(_ contents: String, at path: String, fence: String) -> String {
        let body = contents.hasSuffix("\n") || contents.isEmpty ? contents : contents + "\n"
        return "cat > \"\(path)\" <<'\(fence)'\n\(body)\(fence)\n"
    }

    /// Each Shepherdr keeps its own list, `lists/<instance>`, so two that keep the same machine
    /// don't overwrite each other's; the command line reads them all. `machines`, the one list
    /// version 5 and earlier read, gets a copy too.
    private static func writeListLines(_ list: String, instance: String, fence: String) throws -> String {
        guard isInstance(instance) else { throw HerdrFailure(.incompatible, "This Shepherdr's instance ID is invalid.") }
        return "mkdir -p \"$root/lists\"\n" + file(list, at: "$root/lists/.list-$$", fence: fence)
            + "mv \"$root/lists/.list-$$\" \"$root/lists/\(instance)\"\n"
            + "cp \"$root/lists/\(instance)\" \"$root/.machines-$$\"\n" + "mv \"$root/.machines-$$\" \"$root/machines\"\n"
    }

    public static func install(_ kit: Kit, list: String?, instance: String, on machine: Machine) async throws {
        let output = try await runScript(try installScript(kit, list: list, instance: instance), on: machine, action: "install the agent tools on")
        guard String(decoding: output.stdout, as: UTF8.self).contains("shepherdr-installed \(kit.version)") else {
            let detail = String(decoding: output.stderr.prefix(2_048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrFailure(.unreachable, "Could not install the agent tools on \(machine.name).", detail: detail.isEmpty ? nil : detail)
        }
    }

    /// Writes this Shepherdr's machine list on a machine that has the tools.
    public static func writeList(_ list: String, instance: String, on machine: Machine) async throws {
        let fence = "SHEPHERDR_END_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let script = "set -e\numask 077\nroot=\"$HOME/.shepherdr\"\n" + (try writeListLines(list, instance: instance, fence: fence))
            + "echo shepherdr-list-written\n"
        let output = try await runScript(script, on: machine, action: "write the machine list on")
        guard String(decoding: output.stdout, as: UTF8.self).contains("shepherdr-list-written") else {
            throw HerdrFailure(.unreachable, "Could not write the machine list on \(machine.name).")
        }
    }

    /// Removes the tools and their skills. Letters stay in `~/.shepherdr` until you delete it.
    static let uninstallScript = """
    root="$HOME/.shepherdr"
    rm -rf "$root/bin" "$root/skills" "$root/VERSION" "$root/machines" "$root/lists" \\
      "$HOME/.claude/skills/shepherdr" "${CODEX_HOME:-$HOME/.codex}/skills/shepherdr"
    echo shepherdr-removed
    """

    public static func uninstall(from machine: Machine) async throws {
        guard let command = machine.shell(uninstallScript) else {
            throw HerdrFailure(.incompatible, "Shepherdr can't reach \(machine.name) over SSH.")
        }
        let output = try await Mailbox.run(command, on: machine, action: "remove the agent tools from")
        guard String(decoding: output.stdout, as: UTF8.self).contains("shepherdr-removed") else {
            throw HerdrFailure(.unreachable, "Could not remove the agent tools from \(machine.name).")
        }
    }

    /// Runs a script that is too long for a command line, from standard input.
    private static func runScript(_ script: String, on machine: Machine, action: String) async throws -> CommandOutput {
        guard let command = machine.shellReadingStandardInput() else {
            throw HerdrFailure(.incompatible, "Shepherdr can't reach \(machine.name) over SSH.")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("shepherdr-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let output: CommandOutput
        do {
            output = try await ProcessRunner().run(executable: command.executable, arguments: command.arguments, timeout: 60, input: file)
        } catch CommandError.timedOut {
            throw HerdrFailure(.unreachable, "\(machine.name) took too long to answer.")
        }
        guard output.exitCode == 0 else {
            let detail = String(decoding: output.stderr.prefix(2_048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrFailure(.unreachable, "Could not \(action) \(machine.name).", detail: detail.isEmpty ? nil : detail)
        }
        return output
    }
}
