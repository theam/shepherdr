Native macOS console for herding your coding agents across your Herdr machines: one prioritized queue, the real terminal of every session, a browser per session, and a notification when it's your turn.

### What's new in 0.9.2

From 0.8.7 on, Shepherdr offers this version itself, at the foot of the sidebar.

- **More than one Shepherdr.** Run Shepherdr on a Mac that another one keeps as a remote machine, and each request from an agent is carried out once, by whichever gets to it. What waits for you shows on both Macs: let it through in either. Each Shepherdr writes its own list of machines, so agents reach the machines of both. Update every Mac that runs Shepherdr: 0.9.1 and earlier take every letter they read. Your machines are offered the updated agent tools.
- **Nothing starts or arrives twice.** A session started for a request, and a pane that got a handoff, keep a note in Herdr. Letting a request through again, such as after a restart, links its session instead of starting another.

### Fixed

- A session an agent asked for on another Mac never started when the agent's own Mac also ran Shepherdr: that Shepherdr took the request and couldn't start it.

### Download and install

- **Apple Silicon (M1 or later), macOS 14 Sonoma or later.** Xcode is not required.
- Download **Shepherdr-…-macos-arm64.dmg**, open it, and drag **Shepherdr.app** to **Applications**. A ZIP of the same app is also available.
- **Required:** install and start [Herdr](https://herdr.dev/docs/) separately. Remote machines use Herdr's saved machine profiles and a CLI with `--machine` support, such as 0.9.3.
- **Recommended:** the [GitHub CLI](https://cli.github.com), signed in with `gh auth login`, to confirm pull requests and issues, fetch their titles, watch pull requests' CI checks and fill the GitHub inbox.
- Terminals require `terminal session observe/control` on the target machine (verified with CLI/server 0.9.3). Remote terminals, folder checks, machine load and commands left running use an already-trusted SSH host and noninteractive authentication on Unix-like hosts.
- The agent tools are optional. Shepherdr installs them over SSH only when you accept, writing only `~/.shepherdr` and the agents' skill folders, without `sudo`; on each machine they need only `sh` and Herdr.
- Once installed, Shepherdr offers new versions as they come out and updates itself in place, only with an app signed by the same team and notarized by Apple.
- Shepherdr is **signed with The Agile Monkeys' Developer ID and notarized by Apple**: it opens like any other download, with no trip to **Privacy & Security**.
- macOS asks for permission the first time Shepherdr notifies you or you dictate. Dictation downloads its speech model (about 460 MB) from Hugging Face once, after asking.
- `SHA256SUMS` contains checksums for both downloads. In their download directory, run `shasum -a 256 -c SHA256SUMS` after downloading both packages.

Shepherdr is an independent client for Herdr. It creates, renames or closes sessions and changes machines only when you ask; input goes only to the unlocked session you are viewing, and never replaces another client's input without an explicit Take Over.
