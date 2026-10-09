Native macOS console for herding your coding agents across your Herdr machines: one prioritized queue, the real terminal of every session, a browser per session, and a notification when it's your turn.

### What's new in 0.8.4

- **Opens like any other download.** Shepherdr is now signed with The Agile Monkeys' Developer ID and notarized by Apple: no more **Open Anyway** in **Privacy & Security**.
- **See which agent works in each session.** Each session shows its agent by the mark its own interface uses: ✻ Claude Code, >_ Codex, ✦ Gemini CLI, and ◇ for the rest. It's in the queue, the session's header and the overview cards.
- **Pull request and issue states in Resources.** Merged pull requests and issues closed as completed turn lilac, as on GitHub; pull requests closed without merging and issues closed as not planned dim. The sidebar's pull request number turns lilac once the session's pull requests land.
- **More folders in New Session.** Its shortcuts also offer the folders of shells still waiting for an agent, and **File → New Session in Same Folder…** (**⇧⌘N**) starts one beside the session on screen.

### Fixed

- Renaming a session could do nothing: the new name was lost as the dialog closed.

### Download and install

- **Apple Silicon (M1 or later), macOS 14 Sonoma or later.** Xcode is not required.
- Download **Shepherdr-…-macos-arm64.dmg**, open it, and drag **Shepherdr.app** to **Applications**. A ZIP of the same app is also available.
- **Required:** install and start [Herdr](https://herdr.dev/docs/) separately. Remote machines use Herdr's saved machine profiles and a CLI with `--machine` support, such as 0.9.3.
- **Recommended:** the [GitHub CLI](https://cli.github.com), signed in with `gh auth login`, to confirm pull requests and issues, fetch their titles and watch pull requests' CI checks.
- Terminals require `terminal session observe/control` on the target machine (verified with CLI/server 0.9.3). Remote terminals, folder checks, machine load and commands left running use an already-trusted SSH host and noninteractive authentication on Unix-like hosts.
- Shepherdr is **signed with The Agile Monkeys' Developer ID and notarized by Apple**: it opens like any other download, with no trip to **Privacy & Security**.
- macOS asks for permission the first time Shepherdr notifies you or you dictate. Dictation downloads its speech model (about 460 MB) from Hugging Face once, after asking.
- `SHA256SUMS` contains checksums for both downloads. In their download directory, run `shasum -a 256 -c SHA256SUMS` after downloading both packages.

Shepherdr is an independent client for Herdr. It creates, renames or closes sessions and changes machines only when you ask; input goes only to the unlocked session you are viewing, and never replaces another client's input without an explicit Take Over.
