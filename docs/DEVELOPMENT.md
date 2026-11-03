# Developing Shepherdr

Requires macOS 14 or later and Xcode 16 or later, with its license accepted and first-launch components installed. See [CONTRIBUTING](../CONTRIBUTING.md) for the ground rules.

## Dependencies

The native terminal renderer uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pinned to 1.10.1 (MIT). Fira Code 6.2 is bundled under the SIL Open Font License 1.1 (`Sources/ShepherdrTerminalUI/Resources/Fonts`). This AppKit version builds without an additional Metal compiler component or binary framework. SwiftPM also resolves SwiftTerm's command-line tooling dependency, ArgumentParser; it is not linked into Shepherdr.

Dictation uses [FluidAudio](https://github.com/FluidInference/FluidAudio), pinned to 0.13.4 (Apache 2.0), the engine and version [scribe](https://github.com/theam/scribe) uses, so both share one downloaded model. It has no further dependencies or binary frameworks. NVIDIA's Parakeet TDT v3 model (CC BY 4.0) is not bundled: FluidAudio downloads it from Hugging Face into `~/Library/Application Support/FluidAudio` on first use. FluidAudio's license ships in the app. Microphone access needs the `NSMicrophoneUsageDescription` key and, under the hardened runtime, the `com.apple.security.device.audio-input` entitlement in `App/Shepherdr.entitlements`, which the release script signs with. A `swift run` build has no Info.plist, so dictation reports that it is unavailable there instead of starting.

No API keys, accounts, or server-side Shepherdr service are required.

## Build and run

From this repository's root:

```sh
open Shepherdr.xcodeproj
```

Choose the shared **Shepherdr** scheme and **My Mac** destination, then press **⌘R**. No development team is needed for a local build. The application intentionally does not use App Sandbox: it must launch the user's installed Herdr executable and access Herdr's socket and SSH environment.

Or build and launch the application from Terminal:

```sh
xcodebuild -project Shepherdr.xcodeproj \
  -scheme Shepherdr -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/Shepherdr.app
```

If Xcode requests setup, open Xcode once to install its components. Review and accept Apple's license with `sudo xcodebuild -license`. If the wrong developer directory is selected, use `sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

Swift Package Manager also builds the application executable:

```sh
swift build --product shepherdr
swift run shepherdr
```

Use the Xcode-built `.app` for normal Dock/Finder use. See [releasing](RELEASING.md) for the automated Apple Silicon packages and their signing status.

## Tests and diagnostics

```sh
swift test
xcodebuild -project Shepherdr.xcodeproj \
  -scheme Shepherdr -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO test
# Read-only live transport/store smoke test; exits 1 when no machine is online:
swift run shepherdr-probe
# The agent tools' command line, against a fake herdr and then a real one in a server of its own:
sh Tests/AgentTools/test.sh
sh Tests/AgentTools/herdr-live.sh
```

The agent tools' command line is a POSIX `sh` script that runs on Linux too: check changes to it with dash or BusyBox (`docker run --rm -v "$PWD":/src -w /src alpine sh Tests/AgentTools/test.sh`) and ShellCheck, as CI does. Bump `Sources/ShepherdrCore/Resources/AgentTools/VERSION` whenever you change the kit, so machines update. See [agent tools](AGENT-TOOLS.md).

The updater (`Sources/ShepherdrCore/Resources/Updater/update.sh`) is checked by the Swift tests against a release made on the spot, signed ad hoc, which it must refuse. Its happy path needs a Developer ID release: `SHEPHERDR_LIVE_UPDATE_TEST=1 swift test --filter LiveUpdateTests` installs the published 0.8.6 over 0.8.5 in a scratch folder, without opening it. Add `--check-only` to the script to download and check a release without replacing anything. Local builds have no team, so their **Update** offers stay off.

Tests use Swift Testing, synthetic JSON fixtures, mock cluster/terminal clients, isolated preferences, an injected command runner, and bounded real subprocess tests. They cover decoding, domain joins, all states, future states, duplicate IDs, aggregation, partial failures, stale retention, recovery, catalog failures, disabled/removed profiles, incremental results, cancellation, literal arguments, pipe draining, terminal JSON streams, observation/input boundaries, detach/reconnect, priority persistence and filtered reordering. No running Herdr or SSH access is needed for the test suite.

Use **Settings → Machines** for failure details. A malformed response is **Incompatible**, never a successful empty session. Temporary failures keep cached rows visible with a stale marker and last-received timestamp. The summary counts exclude stale rows. Last-known snapshots are held in memory only; quitting clears them. The app does not collect telemetry or write snapshot/terminal contents to disk; saved priorities contain only session identifiers.

## Architecture

```text
App/                              SwiftUI presentation: queue sidebar, work area, prompt editor, browser, settings, theme
  RemoteRelay.swift               The relay Shepherdr Remote connects to: pairing, the queue for phones, their terminals and prompts
  RemoteSettings.swift            Settings → Remote
  Compass.swift                   Compass: its agent, schedule, runs, page, actions and backup, and the page's bridge
  CompassViews.swift              The mode tabs, Compass's column and work area, and its welcome screen
  ReadinessMonitor.swift          Sleep, dark wakes and the network, for agents Shepherdr starts or prompts unattended
  GitHubInbox*.swift              The overview's GitHub inbox: its sync with GitHub, its columns and suggested order
Sources/ShepherdrRemote/           The relay's wire protocol, shared with the iOS app: messages, binary frames, pairing links, fingerprints
Sources/ShepherdrCore/
  Remote/                         The relay's TLS identity (a self-signed P-256 certificate in DER), its WebSocket server and the paired phones
  Transport/                      CLI adapters, executable discovery, bounded process/stream transports, agent tools and mailbox, Compass's folder and Git
  DTO/                            JSON wire types, validation and domain mapping
  Domain/                         Machine, Workspace, Agent, lifecycle and failure models, project gathering, letters and machine lists, Compass's schedule, settings and actions, readiness to start agents, the GitHub inbox and its suggested order, how a Herdr tab lays out its panes and which shells show inside a session
  Store/                          MainActor cluster state, local priorities, groups, project headings and holds, terminal connections, agent tools and mail, the GitHub inbox's repositories
  Resources/AgentTools/           The shepherdr command and skill installed on each machine
  Resources/Updater/              The script that replaces the app with a new release
  Resources/Compass/              Compass's contract, page template, starter prompt and permissions
Sources/ShepherdrTerminalUI/       Embeddable SwiftTerm AppKit terminal surface, the holder that keeps it across sessions, palette and link handling
Sources/ShepherdrDictation/        On-device dictation: microphone capture and Parakeet transcription via FluidAudio
Sources/ShepherdrProbe/            Read-only integration diagnostic
Tests/ShepherdrCoreTests/          Protocol, transport and store regression tests
Tests/AgentTools/                  The agent tools' command line, against a fake herdr and a real one
iOS/                               Shepherdr Remote, the iPhone app: XcodeGen project, SwiftUI views, SwiftTerm's UIKit terminal, dictation
scripts/make-artwork.sh            Regenerates the icon, README header and social preview (see Artwork)
scripts/pixelate.swift             Turns art into strict pixel art in App/Theme.swift's palette
scripts/make-icon.swift            Renders App/Assets.xcassets/AppIcon.appiconset from docs/assets/icon.png
scripts/make-header-masks.py       Prepares the header's masks and cleaned art (Python, rarely needed)
```

Compass's pure parts are in Core and tested there: `CompassSchedule` (run times and missed runs, with fixed clocks), `CompassConfig` (lenient, since agents edit it), `CompassAction` (the page's buttons), `CompassFolder` (the kit and the files by owner), `CompassRepository` (Git, tested with a real Git and a bare remote when Git is installed), and `Readiness` and `AgentStartup` (when an agent may start or get its first prompt, with fixed clocks). `CompassController` in the app follows the agent through each run; `ReadinessMonitor` feeds `Readiness` from macOS.

`SessionLinks` (Core) relates sessions and the pull requests and issues they work on, many to many, from each session's resources, and the repository each session's folder is in (`FolderRepositories`, a short `sh` script run on each machine), so it can't disagree with them. `GitHubCache` keeps what GitHub and the machines answered, with when, in memory, and writes it to the user's caches folder once a minute and on quit; readers say how old an answer may be; `InboxAction` turns what it finds for an inbox item into its button. The GitHub inbox asks for everything in one GraphQL query through `gh api graphql`, with the searches as variables (`GitHubLookup.inboxQuery`), and parses the answer in Core (`GitHubLookup.parseInbox`). `GitHubInboxStore` keeps the followed repositories and what you've seen in user defaults, and `PullRequestOrder` suggests the order for its pull requests from their review state, checks, conflicts, size, age and stacking, with fixed clocks in its tests.

`HerdrClient` exposes domain snapshots and the machine catalog. `HerdrTerminalClient` exposes live terminal connections, frames and input. `CLIHerdrClient` implements both; views never execute commands or decode JSON. Agent identity combines the machine profile and terminal ID, so identical pane IDs and names on different machines remain distinct. Native Unix-socket transport and event subscriptions can replace the CLI behind these boundaries.

See [integration notes](HERDR-INTEGRATION.md) for the inspected contract, compatibility policy, event strategy and limitations.

## Shepherdr Remote (iOS)

The iPhone companion lives in `iOS/`. Its Xcode project is generated from `iOS/project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`, then `xcodegen` in `iOS/`); it depends on this package's `ShepherdrRemote` library and on SwiftTerm 1.10.1, whose UIKit view it uses. It needs iOS 26 or later, for SpeechAnalyzer.

Put your signing team in `iOS/Config/Local.xcconfig`, which git ignores:

```text
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_SUFFIX = .dev
```

The suffix keeps a personal build's bundle identifier apart from the published one. Then open `iOS/ShepherdrRemote.xcodeproj`, choose your iPhone and press **⌘R**, or build from Terminal with Xcode signed in to your Apple account (Xcode → Settings → Accounts):

```sh
xcodebuild -project iOS/ShepherdrRemote.xcodeproj -scheme ShepherdrRemote -destination 'id=<your iPhone UDID>' \
  -derivedDataPath build-ios -allowProvisioningUpdates build
xcrun devicectl device install app --device <UDID> "build-ios/Build/Products/Debug-iphoneos/Shepherdr Remote.app"
```

`xcrun devicectl list devices` lists the UDIDs. Once Xcode has made a profile with your iPhone in it, by pressing **⌘R** once, Terminal builds can leave out `-allowProvisioningUpdates` and use that profile: `xcodebuild` in Terminal may not see the account Xcode signed in with. After adding or removing a file under `iOS/ShepherdrRemote`, run `xcodegen` again. Crash reports from the iPhone are a `xcrun devicectl device info files --domain-type systemCrashLogs` away, and `xcrun devicectl device process launch --console` shows the app's output. For the Simulator, sign to run locally (`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`): without a signature the keychain refuses the pairing token.

**The relay.** One WebSocket over TLS 1.3 (`Network.framework` on both sides). The phone doesn't use URLSession: its App Transport Security refuses a self-signed certificate at a Tailscale address (`NSURLErrorDomain -1200`), though not at `127.0.0.1`, so the Simulator never shows it. `RelaySocket` checks the fingerprint in the TLS handshake itself, with `sec_protocol_options_set_verify_block`. Control messages are JSON text (`ClientMessage`, `ServerMessage`); terminal frames are binary, a 9-byte header and Herdr's ANSI bytes (`RemoteFrame`), with synchronized output and OSC 8 links taken out (`RemoteFrameFilter`). The phone pins the SHA-256 of the certificate's public key, which the pairing link carries; the Mac keeps a SHA-256 of each phone's token in user defaults. Each copy of the app keeps its own identity in the keychain, named after its bundle identifier, so test builds never touch the real one's. Through Tailscale Serve, the relay listens on a free port of 127.0.0.1 and Serve forwards the relay's port to it. That's because Tailscale holds the relay's port on the Mac's tailnet addresses, and while it does, `NWListener` refuses that port at any address with `EADDRINUSE`, even with `allowLocalEndpointReuse`; a BSD socket bound to 127.0.0.1 doesn't. Serve commands run one after another, so that turning forwarding off and on again ends on.

**What the phone gets.** Every second, when it changed, a `QueueSnapshot`: the rows `remoteQueue()` builds in the sidebar's order, each with its group and project lines (`inGroup`, `inProject`), its place in a tree of holds (`QueueTree`, from `WaitForest`), its panes and its resources (`remoteResources(for:)`, ten of each kind, with the state and checks `status(of:)` gives Compass's page too), and Compass's status (`RemoteCompass`, in the words of its column). A row from a Mac that sends none of these still reads. Compass pages travel only on request, `compassPage(day:)`, which reads only a file named like a day. `compassRun` and `compassCancel` do what the column's buttons do, and typing to Compass's agent from the phone holds its runs back as typing on the Mac does. Searching runs on the phone (`QueueSearch`).

The relay logs each connection under the subsystem `com.theagilemonkeys.Shepherdr`, category `relay`: `log stream --predicate 'category == "relay"' --level info`.

**Testing with the Simulator.** The Simulator shares the Mac's network, so it can reach a relay on `127.0.0.1` without exposing anything:

- Start a Herdr server of its own in a scratch home, as in [the agent tools' live test](../Tests/AgentTools/herdr-live.sh), with fake agents that report themselves with `herdr pane report-agent`.
- Run a copy of the app with a bundle identifier of its own and `CFFIXED_USER_HOME` pointing at the scratch home, which moves `NSHomeDirectory()`, `~` and the caches there. It has no default keychain there, so make one first with `CFFIXED_USER_HOME=<home> security create-keychain -p <password> <home>/Library/Keychains/login.keychain-db`.
- Pass the settings as arguments: `open -g -n --env CFFIXED_USER_HOME=<home> --env HOME=<home> --env SHEPHERDR_HERDR_PATH=<wrapper> <copy>.app --args -remoteEnabled YES -remotePort 18437 -remoteLoopbackForTesting YES -notifySessions NO`. `remoteLoopbackForTesting`, which isn't in Settings, listens on `127.0.0.1` without asking Tailscale for anything and writes the pairing link to `~/.shepherdr/remote-invite.txt`.
- Launch the app with `xcrun simctl launch <device> com.theagilemonkeys.ShepherdrRemote.dev -pairInvite "<link>"` to pair, and later with `-openSession <machine>/<terminal>` to open a session or `-openCompass YES` to open Compass, since nobody taps in a headless Simulator. `-pairInvite` only pairs an app that has no Mac yet: `xcrun simctl uninstall` it to start over.
- Groups, holds and resources live in the copy's user defaults (`sessionOrder.v2`, `sessionWaits.v1`, `sessionState.v1`, all JSON). Quit the copy, edit them with `defaults export` and `defaults import`, and open it again. A folder at `~/.shepherdr/compass` with a `compass.json` of `{"enabled": false}` and pages in `days/` gives it a Compass that never starts an agent.

`RelayServerTests` run a real TLS WebSocket on loopback with the identity in a temporary keychain, a client pinning the right fingerprint and one pinning another.

## Artwork

The app icon, the README header and the social preview are strict pixel art: every art pixel is a square of the same size, in a color from `App/Theme.swift`. `scripts/pixelate.swift` reads every hex color in that file, divides an image into a grid, averages each cell in linear light and picks the theme color nearest in CIE L\*a\*b\*. `Theme.artworkShades` adds in-between shades that only the artwork uses.

```sh
bash iOS/                               Shepherdr Remote, the iPhone app: XcodeGen project, SwiftUI views, SwiftTerm's UIKit terminal, dictation
scripts/make-artwork.sh
```

regenerates everything from `docs/assets/source`:

- **Icon:** `source/icon.png` becomes 206×206 art pixels (`docs/assets/icon.png`). That fills the macOS icon grid's 824-point body exactly, 4 pixels per art pixel at 1024 and 1 at 256, so `make-icon.swift` keeps hard edges down to 256 and smooths only the smaller sizes.
- **Header:** 480×270 art pixels at 3 px, shown 720 points wide in the README, so each art pixel is exactly 3 pixels on Retina screens. Sheep, title and code stay in the phosphor greens. Regions recolor the dog into the logo's amber shepherd and the tongue into the terminal's pinks, matched by lightness, and turn the glowing outlines into single lines, brown around the dog and green elsewhere. Lone high-contrast flecks inside the dog are cleaned, and `touchups.txt` holds hand edits in art pixels, such as the fangs.
- **Social preview:** the header at 2 px on a 1280×640 canvas. Upload `docs/assets/social-preview.png` in the repository's **Settings → General → Social preview**.

The header's masks and `clean.png`, the original with the code digits erased from the dog's coat, come from `scripts/make-header-masks.py` and are committed. Rerun it (it needs Pillow and NumPy) only after changing the hand-placed regions in `docs/assets/source/header/regions.json`: the dog's outline, eyes, tongue, the title's ascender between the paws and the columns of digits, in the original's pixels.

