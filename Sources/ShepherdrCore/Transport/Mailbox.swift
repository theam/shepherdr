import Foundation

/// Collects the letters agents leave in `~/.shepherdr/outbox` on a machine: on this Mac directly,
/// and on other machines over the same SSH connection Shepherdr already uses. Machines never
/// connect back; Shepherdr always fetches.
///
/// A trip prints the waiting letters as one stream: `L <id>` starts a letter, and each
/// `F <bytes> <path>` line is followed by that many bytes of the file and a newline. Only regular
/// files with the names `shepherdr` writes cross. A letter too large for any trip comes as
/// `L <id>` and `T <bytes>`, without its files, so Shepherdr can set it aside. A letter this
/// Shepherdr already read comes as `K <id>` alone: it is still waiting.
///
/// Reading a letter doesn't take it: more than one Shepherdr may keep the same machine, and any of
/// them may carry it out. The one that does claims it first, moving it to `outbox/.collected` with
/// its name, and only the one whose move succeeds goes ahead. Letters nobody claims are filed
/// after a week.
public enum Mailbox {
    /// The letters of one trip, and whether more were left for the next one.
    public struct Delivery: Equatable, Sendable {
        public var letters: [Collected]
        public var hasMore: Bool
        /// Every letter the trip saw waiting, read before or not.
        public var waiting: [String] = []
    }

    /// Who claimed a letter: a Shepherdr's instance ID, and the name it goes by in the lists.
    public struct Claimant: Equatable, Sendable {
        public let instance: String
        public let name: String

        public init(instance: String, name: String) {
            self.instance = instance
            self.name = name
        }

        /// As `claimed-by` holds it: the instance ID, a space and the name.
        var line: String { "\(instance) \(name)" }

        init?(line: String) {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, AgentTools.isInstance(parts[0]) else { return nil }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            self.init(instance: parts[0], name: String(name.prefix(64)))
        }
    }

    /// What claiming a letter found.
    public enum Claim: Equatable, Sendable {
        /// It's this Shepherdr's to carry out.
        case claimed
        /// A Shepherdr claimed it already, the one named when it left its name: possibly this one,
        /// on a try whose answer was lost. Nil when nobody did, such as when it expired.
        case taken(by: Claimant?)
    }

    /// A letter as it arrived: its files by path inside it.
    public struct Collected: Equatable, Sendable {
        public let id: String
        public let contents: [String: Data]
        /// The letter's size when it was too large to bring. Its files stayed on the machine.
        public var oversize: Int? = nil
    }

    /// Bytes one trip brings at most: a letter's attachments stop at 5 MB.
    public static let tripLimit = 7 * 1_024 * 1_024
    static let lettersPerTrip = 50

    /// Prints waiting letters, oldest first, until the trip's limits, and names the ones already
    /// read, given after the limit. On the way it files letters nobody claimed within a week, and
    /// clears what was filed over a week ago. Both scripts run in the C locale: otherwise bash,
    /// /bin/sh on some Linux systems, takes ranges such as `[A-Z]` from the collation of the locale
    /// SSH passes along.
    static let collectScript = """
    export LC_ALL=C
    box="$HOME/.shepherdr/outbox"
    limit=$1
    shift
    known=" $* "
    echo 'shepherdr-mail 2'
    total=0
    count=0
    more=0
    if [ -d "$box" ]; then
      mkdir -p "$box/.collected" 2>/dev/null
      find "$box/.collected" -mindepth 1 -maxdepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null
      find "$box" -mindepth 1 -maxdepth 1 -name '.tmp-*' -mtime +1 -exec rm -rf {} + 2>/dev/null
      for letter in "$box"/*; do
        [ -d "$letter" ] || continue
        id=${letter##*/}
        case $id in '' | *[!A-Za-z0-9-]*) continue ;; esac
        if [ -n "$(find "$letter" -prune -mtime +7 2>/dev/null)" ]; then
          mv "$letter" "$box/.collected/$id" 2>/dev/null && echo expired >"$box/.collected/$id/claimed-by"
          continue
        fi
        case $known in *" $id "*) echo "K $id"; continue ;; esac
        if [ "$count" -ge \(lettersPerTrip) ]; then more=1; break; fi
        size=0
        for file in "$letter/letter.json" "$letter/message.md" "$letter"/files/*; do
          [ -f "$file" ] && [ ! -h "$file" ] || continue
          size=$((size + $(wc -c < "$file")))
        done
        # No trip could bring it: name it, so it's set aside instead of blocking the letters after it.
        if [ "$size" -gt "$limit" ]; then
          count=$((count + 1))
          echo "L $id"
          echo "T $size"
          continue
        fi
        if [ "$count" -gt 0 ] && [ $((total + size)) -gt "$limit" ]; then more=1; break; fi
        total=$((total + size))
        count=$((count + 1))
        echo "L $id"
        for file in "$letter/letter.json" "$letter/message.md" "$letter"/files/*; do
          [ -f "$file" ] && [ ! -h "$file" ] || continue
          name=${file#"$letter"/}
          case $name in letter.json | message.md | files/[A-Za-z0-9_-]*) ;; *) continue ;; esac
          case $name in files/*/* | *[!A-Za-z0-9._/-]*) continue ;; esac
          echo "F $(($(wc -c < "$file"))) $name"
          cat "$file"
          echo
        done
      done
    fi
    echo "D $more"
    """

    /// Claims letters for a Shepherdr, given first as its instance ID and name: moves each to
    /// `outbox/.collected`, with those in `claimed-by`, and says `C <id>` when the move was this one's. A move is a rename,
    /// which is atomic, so of two Shepherdrs claiming a letter at once only one succeeds; the other
    /// hears `X <id>` and who has it.
    static let claimScript = """
    export LC_ALL=C
    box="$HOME/.shepherdr/outbox"
    claimant=$1
    shift
    echo 'shepherdr-claims 1'
    mkdir -p "$box/.collected" 2>/dev/null
    for id in "$@"; do
      case $id in '' | *[!A-Za-z0-9-]*) continue ;; esac
      if [ ! -e "$box/.collected/$id" ] && mv "$box/$id" "$box/.collected/$id" 2>/dev/null; then
        printf '%s\\n' "$claimant" >"$box/.collected/$id/claimed-by"
        touch "$box/.collected/$id"
        echo "C $id"
      else
        by=$(head -n 1 "$box/.collected/$id/claimed-by" 2>/dev/null | tr -d '[:cntrl:]')
        echo "X $id ${by:--}"
      fi
    done
    echo shepherdr-claimed
    """

    /// Brings the letters waiting on a machine, except those already read, which it only names.
    public static func collect(from machine: Machine, skipping read: [String] = []) async throws -> Delivery {
        guard let command = machine.shell(collectScript, arguments: [String(tripLimit)] + read.filter(Letter.isValidID)) else {
            throw HerdrFailure(.incompatible, "Shepherdr can't reach \(machine.name) over SSH.")
        }
        let output = try await run(command, on: machine, action: "collect letters from")
        return try parse(output.stdout)
    }

    /// Claims letters on the machine they wait on, for a Shepherdr. A letter the answer leaves
    /// out was claimed by nobody: treat it as taken.
    public static func claim(_ ids: [String], as claimant: Claimant, on machine: Machine) async throws -> [String: Claim] {
        let ids = ids.filter(Letter.isValidID)
        guard !ids.isEmpty else { return [:] }
        guard let command = machine.shell(claimScript, arguments: [claimant.line] + ids) else {
            throw HerdrFailure(.incompatible, "Shepherdr can't reach \(machine.name) over SSH.")
        }
        let output = try await run(command, on: machine, action: "claim the letters on")
        return try parseClaims(String(decoding: output.stdout, as: UTF8.self))
    }

    static func parseClaims(_ output: String) throws -> [String: Claim] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let start = lines.firstIndex(of: "shepherdr-claims 1"), lines[start...].contains("shepherdr-claimed") else {
            throw HerdrFailure(.unreachable, "The machine didn't say which letters were claimed.")
        }
        var claims: [String: Claim] = [:]
        for line in lines[start...] {
            let fields = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard fields.count >= 2, Letter.isValidID(fields[1]) else { continue }
            switch fields[0] {
            case "C": claims[fields[1]] = .claimed
            case "X":
                claims[fields[1]] = .taken(by: fields.count == 3 ? Claimant(line: fields[2]) : nil)
            default: continue
            }
        }
        return claims
    }

    static func run(_ command: (executable: URL, arguments: [String]), on machine: Machine, action: String) async throws -> CommandOutput {
        let output: CommandOutput
        do {
            output = try await ProcessRunner().run(executable: command.executable, arguments: command.arguments, timeout: 60)
        } catch CommandError.timedOut {
            throw HerdrFailure(.unreachable, "\(machine.name) took too long to answer.")
        } catch CommandError.outputTooLarge {
            throw HerdrFailure(.incompatible, "The letters from \(machine.name) are over the limit.")
        }
        guard output.exitCode == 0 else {
            let detail = String(decoding: output.stderr.prefix(2_048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrFailure(.unreachable, "Could not \(action) \(machine.name).", detail: detail.isEmpty ? nil : detail)
        }
        return output
    }

    /// Reads a trip's stream. Anything out of place ends it as incompatible: the stream comes
    /// from a script Shepherdr wrote, so a surprise means something else answered.
    static func parse(_ data: Data) throws -> Delivery {
        let bytes = [UInt8](data)
        var index = 0
        func line() throws -> String {
            guard let end = bytes[index...].firstIndex(of: 0x0A) else { throw incompatible }
            defer { index = end + 1 }
            return String(decoding: bytes[index..<end], as: UTF8.self)
        }
        let incompatible = HerdrFailure(.incompatible, "The machine's answer wasn't a list of letters.")
        // Login banners and shell startup output may come first.
        while try line() != "shepherdr-mail 2" {}
        var letters: [Collected] = []
        var waiting: [String] = []
        var current: Collected?
        func isID(_ text: String) -> Bool { text.range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil }
        while index < bytes.count {
            let header = try line()
            let fields = header.split(separator: " ", maxSplits: 2).map(String.init)
            switch fields.first {
            case "K":
                guard fields.count == 2, isID(fields[1]) else { throw incompatible }
                if let finished = current { letters.append(finished) }
                current = nil
                waiting.append(fields[1])
            case "L":
                guard fields.count == 2, isID(fields[1]) else { throw incompatible }
                if let current { letters.append(current) }
                current = Collected(id: fields[1], contents: [:])
                waiting.append(fields[1])
            case "F":
                guard fields.count == 3, let letter = current, letter.oversize == nil, let size = Int(fields[1]), size >= 0, size <= tripLimit,
                      fields[2] == "letter.json" || fields[2] == "message.md" || Letter.isValidFile(fields[2]),
                      index + size < bytes.count, bytes[index + size] == 0x0A else { throw incompatible }
                var contents = letter.contents
                contents[fields[2]] = Data(bytes[index..<(index + size)])
                current = Collected(id: letter.id, contents: contents)
                index += size + 1
            case "T":
                guard fields.count == 2, current?.contents.isEmpty == true, let size = Int(fields[1]), size > 0 else { throw incompatible }
                current?.oversize = size
            case "D":
                guard fields.count == 2 else { throw incompatible }
                if let current { letters.append(current) }
                return Delivery(letters: letters, hasMore: fields[1] == "1", waiting: waiting)
            default:
                throw incompatible
            }
        }
        throw incompatible
    }

    // MARK: Letters kept on this Mac

    /// Where collected letters are kept: `~/.shepherdr/inbox/<machine>/<id>`. Handoffs point
    /// agents on this Mac at their files there. The home folder is the one the tools' scripts
    /// see, `$HOME`, so both agree on where `~/.shepherdr` is.
    public static func inbox(home: URL? = nil) -> URL {
        let home = home ?? ProcessInfo.processInfo.environment["HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".shepherdr/inbox", isDirectory: true)
    }

    /// The folder of a machine's letters: its name, made safe for a path.
    public static func folderName(for machine: Machine) -> String {
        machine.isLocal ? "local" : FileDrop.safeName(machine.name)
    }

    /// Keeps a letter's files on this Mac, readable only by you. Returns its folder.
    public static func keep(_ letter: Collected, from machine: Machine, in inbox: URL) throws -> URL {
        let folder = inbox.appendingPathComponent(folderName(for: machine), isDirectory: true)
            .appendingPathComponent(letter.id, isDirectory: true)
        let manager = FileManager.default
        try? manager.removeItem(at: folder)
        try manager.createDirectory(at: folder.appendingPathComponent("files"), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        for (path, data) in letter.contents {
            // The stream's parser already allowed only these names; check again before writing.
            guard path == "letter.json" || path == "message.md" || Letter.isValidFile(path) else { continue }
            let url = folder.appendingPathComponent(path)
            guard url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else { continue }
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return folder
    }

    /// Clears letters kept for over a month, except those that mail still waiting refers to.
    public static func tidy(_ inbox: URL, keeping kept: Set<String> = [], olderThan age: TimeInterval = 30 * 86_400, now: Date = Date()) {
        let manager = FileManager.default
        guard let machines = try? manager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for machine in machines {
            guard let letters = try? manager.contentsOfDirectory(at: machine, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for letter in letters where Letter.isValidID(letter.lastPathComponent) && !kept.contains(letter.lastPathComponent) {
                let date = (try? letter.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if now.timeIntervalSince(date) > age { try? manager.removeItem(at: letter) }
            }
        }
    }
}
