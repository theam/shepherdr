# Verification

## Letters carried out once by any Shepherdr (0.9.2)

Validated on 2026-11-01 on macOS 26.6.2 with Xcode 27 / Swift 6.4 and Herdr 0.9.3:

- **The cause,** read over SSH without changing anything. An agent on a remote Mac asked for a session on this one. That Mac ran its own Shepherdr 0.9.0, which took the letter as one of its own, as soon as the doorbell rang, and couldn't start a session on a machine it didn't know. This Mac never saw the letter. The two Shepherdrs also took turns writing the remote Mac's machine list, so the agent saw this Mac only some of the time.
- `swift test`: **323 tests passed**.
  - `AgentToolsTests` cover claims: the claimant's name in `claimed-by`, and who has a letter when the claim loses. Two claim scripts started at once over 12 letters, in opposite orders, gave each letter to exactly one of them.
  - A letter already read is only named until it's claimed, and a letter nobody claims within a week is filed as `expired`.
  - `MailboxStreamTests` cover `K` lines and claim answers after a banner or cut short.
  - `MailPlannerTests` cover letters left for another Shepherdr: a session request for a machine it doesn't keep, a `name@machine` on one, and a `spawned` child behind another machine's profile. They also cover what waits unclaimed and what is claimed at once.
  - `MailStoreTests` cover the letters a trip skips, mail kept before claims, and delivery IDs.
- `test.sh`: **21 passed** with sh, dash and bash under `en_US.UTF-8`, including several lists combined with the best route for each name, a list nobody checked in years left out, and the single older list read too. `herdr-live.sh` passed.
- **End to end**, two copies of the app with their own bundle IDs and settings, both local to one Herdr server with a temporary `HOME` and kit 6 installed:
  - Each wrote its own list in `lists/`, named after its instance ID, and `shepherdr machines` combined them.
  - Named alike and trusting their own letters, both received three session requests. Each request started exactly one workspace, marked with `shepherdr-letter`, and every letter was claimed once. Both read one of them, and it still started once.
  - Named Alpha and Beta, without trust, a request for a machine neither keeps stayed in the outbox and showed in neither. One for Alpha waited unclaimed, in Alpha only. Once another name claimed it, Alpha took its card back on its next trip.
  - `shepherdr machines` printed "write error: Broken pipe" under bash: a `head` closed its pipe early. Fixed, and checked five times.
- Not verified: pressing a mail button, since a background copy's window isn't in the accessibility tree. So the claim when you let mail through, the notice when another Shepherdr took it first, and the wait while its machine doesn't answer weren't tried by hand. Nor two Shepherdrs on different Macs over SSH.

## Slack links leave the browser (0.9.1)

Validated on 2026-10-31 on macOS 26.6.2 with Xcode 27 / Swift 6.4:

- `swift test`: **313 tests passed**. `ExternalLinksTests` cover Slack's workspace, app, file and bare links, over http and in capitals; its OAuth and OpenID pages, which stay so **Sign in with Slack** works; and look-alikes that stay, such as `notslack.com`, `slack.com.example.org`, `slack.com` in a path, and a file URL.
- **Where macOS sends them:** `NSWorkspace.urlForApplication(toOpen:)` answered the default browser, Safari, for `https://acme.slack.com/archives/…` and `https://app.slack.com/client/…`; Slack.app claims only `slack://`. So the default browser opens them, and Slack's page offers its app.
- Not verified: clicking a Slack link from each place in the running app (the terminal, a page, a new window, **Resources**, Compass and the address bar). Opening one would have brought the Mac's own browser and Slack forward.

## Splits (0.9.1)

Validated on 2026-10-29 on macOS 26.6.2 with Xcode 27 / Swift 6.4 and Herdr 0.9.3:

- `swift test`: **310 tests passed**. `PaneSplitsTests` cover reading `layouts` into each pane's share of its tab, from an area that doesn't start at 0; a layout Shepherdr can't read, which leaves the rest of the snapshot; which shells show inside a session (beside an agent, or after the first shell of a tab of shells); and `pane split`'s arguments, with `--machine` and without `--cwd`, refusing option-like values.
- **What Herdr answers**, in a server of its own (a temporary `HOME`, `HERDR_*` unset): `pane split w1:p1 --direction right` and `--direction down` answer `pane_info` with the new pane; `api snapshot` carries `layouts` with each tab's `area`, the panes' `rect` and the split tree; `terminal session control` takes `--cols` and `--rows`.
- **End to end**, a copy of the app with its own bundle identifier, launched with `open -g` against that server and driven through its menus with accessibility. The tab held one pane reporting itself as `claude`:
  - **Split Right** made `w1:p4` to its right in the same folder, and the app attached both terminals in control mode. **Close Split** turned on, since the new pane had the keyboard.
  - **Split Down** split `w1:p4`, the pane with the keyboard, not the session's own, and attached the new pane at its own size (55 × 18).
  - **Close Split** closed that shell at once, at its prompt; its terminal was released, and the session's own pane took the keyboard again.
  - With `sleep 300` running in a new split, **Close Split** left it open, waiting for the confirmation.
- **Slow refreshes** (2026-10-30). On a Mac with a remote whose `api snapshot` took about 11 seconds, a split showed, and a closed one left, only after every machine answered. `ClusterStoreTests` now check that closing a pane reads only its machine, under a second while a refresh waits on a slow remote; that an answer asked for before the close doesn't bring the pane back; and that a closed pane leaves before its machine answers. End to end, with a wrapper that delays `machine list` by 8 seconds, **Split Right** took 11.6 s to show the new pane in the build before the fix and 1.4 s after it, counting the menu polling.
- **A shell that exits** (2026-10-31). In a server of its own, `exit` typed through `terminal session control` into a split's shell made Herdr send `terminal.closed` with `terminal <id> exited` and close the pane; attaching again answered `terminal target <id> not found`. Shepherdr took the first as a dropped connection, reconnected, and showed the second as an error until the next refresh. `TerminalTests` now check that neither reason is retried and that both report the end once, while a dropped connection still reconnects; `ClusterStoreTests` that a pane that ended on its own leaves before its machine answers, without asking Herdr to close anything.
- Not verified: the panes on screen (a background copy's window can't be captured), clicking a pane to work in it, **⌘W** (keys can't reach a background app's terminal), and splitting on another machine.

## Name prompts start with the current name (0.9.1)

Validated on 2026-10-28 on macOS 26.6.2 with Xcode 27 / Swift 6.4, for [#7](https://github.com/theam/shepherdr/issues/7):

- **The cause, in a minimal app** with the same alert as **Rename Session**: an `@Observable` model with an optional prompt, and an alert whose `TextField` binds to the prompt's name. The app presented ten prompts in a row and closed each one by pressing its **Rename** or **Cancel** button in process, with no HID events. It read the field as each prompt opened. Some presentations focused or edited the field first. The field often came up empty after an earlier prompt was dismissed; one alert didn't show at all. And when an empty field was edited, **Rename** took only the typed text, which would have renamed a session to it.
- **The fix:** the same app with `.id(prompt.id)` on the field. All ten prompts showed their names, the edits were committed as typed, and every alert appeared. **Rename Group** and **New Group** use the same pattern and got the same fix.
- `xcodebuild … build` built the app.
- Not verified: the alerts inside Shepherdr itself. SwiftUI alerts aren't in the accessibility tree, so a background scratch copy can't read their field.

## Agents wait for a fully awake Mac (0.9.0)

Validated on 2026-10-20 on an Apple Silicon MacBook with macOS 26.6.2, Xcode 27 / Swift 6.4 and Herdr 0.9.3:

- **The cause.** On 19 and 20 October, Compass's agent started inside dark wakes of about two seconds, which `pmset -g log` lists as `DarkWake … [CDNP]`, without graphics or audio; the full wake that followed reads `[CDNVAP]`. Fully awake, `System Capabilities` in `IOPMrootDomain` reads 15, graphics included.
- `swift test`: **258 tests in 52 suites passed**, and `xcodebuild … build` built the app. New tests in `ReadinessTests` cover a dark wake, which is never ready; a sleep notice, which holds until the wake, or for a minute when macOS reports graphics; a wake, after which the host is looked up again and answers asked before it are ignored; a missing path and a host that doesn't resolve, with retries after 10 seconds, fresh answers for a minute and a new lookup on a new network; and sleeps and lost networks as disruptions. `AgentStartupTests` cover the first prompt waiting 15 seconds, and an agent started across a sleep or a lost network starting again: never once you typed to it, at most twice, and not for a disruption from before it began.
- **The monitor**, in a separate harness compiled in Swift 6 mode from the same `ReadinessMonitor` and `Readiness` sources, which posts `NSWorkspace`'s sleep and wake notifications in its own process. All 16 checks passed: the path answered; the first check looked `api.anthropic.com` up, told the handlers and then allowed agents; a sleep notice held every agent and counted as a disruption; the wake allowed agents with no host at once and looked the host up again; the screens waking ended a sleep too; `untilReady` waited while asleep, returned after the wake, and stopped waiting once its request was no longer wanted, as when you discard a session request.
- **End to end, in a scratch home**, as for Compass below: a Herdr server of its own (`HOME=/tmp/shep-wake`), a stand-in `claude` that reports itself with `pane report-agent` and writes the day's page, and a copy of the app with its own bundle identifier, launched with `open -g` at 12:42:51. The 12:00 run, the day's first, was due. The monitor logged a path, then `api.anthropic.com` being looked up, then agents allowed 6 ms later. The agent started at 12:42:53 and was ready at 12:42:56; the prompt came at 12:43:13, the 15 seconds plus the next refresh. The page changed and the run ended `updated`, with its copy `days/2026-10-20/12-00.html`. The user's `default` session and app were never touched.
- Not verified: a real dark wake, which can't be caused without putting the Mac to sleep, and a sleep or a lost network while the app starts an agent. The restart before the first prompt is covered by the tests and the harness only. The Courier's waits (deliveries to agents on this Mac, sessions requested on it, a request discarded meanwhile not starting) and typing in Compass's terminal counting once you leave it were checked by reading the code only.

## Compass (0.8.6)

Validated on 2026-10-15 on Apple Silicon with Xcode 27 / Swift 6.4 and Herdr 0.9.3:

- `swift test` — **173 tests in 35 suites passed**, plus the agent tools' 9; `xcodebuild … test` passed, building the app. New tests cover run times, missed runs (the Mac asleep from 10:20 to 14:40, a daily run missed in the morning, a Friday run not made up on Saturday, a run missed at 18:00 made up at 21:00), lenient settings written by an agent, the page's actions and the values they refuse, the kit by owner (an update rewrites the contract and leaves your prompt and your template alone), copies per run, marks, and `startAgent` with `agent_not_ready` and `agent_name_taken`. With Git installed, a folder is committed, pushed to a bare remote and restored from it.
- **End to end, in a scratch home.** A Herdr server of its own (`HOME=/tmp/shep-e2e/home`), a stand-in `claude` on its `PATH` that reports itself with `pane report-agent` and answers each run by writing the day's page, and a copy of the app with its own bundle identifier, launched with `open -g` against that server. The user's `default` session was never touched.
  - Launched at 21:17 with an empty `compass.json`, Compass prepared its folder, made up the 18:00 run once (kind `first`), started its agent in a `compass` workspace, sent the prompt when the agent was idle, saw the page change, kept `days/2026-10-15/18-00.html` and committed the folder. `context/run.json` and `context/sessions.json` read as documented; the queue's only other session was there, Compass's agent wasn't.
  - **Run Compass Now**, pressed through the menu bar with accessibility, sent an `update` with "Since 21:17" and left a second copy and commit.
  - In Agents, the queue, the overview and the shells listed only the other session. In Compass, the column, the page in its pinned tab, the agent's terminal and the live state badge on the page's `data-session` rendered as intended (window captures).
  - With yesterday's runs and agent in `state.json`, the next launch closed the old agent's panes, started a fresh agent named `compass`, and ran the day's first run. A first attempt showed two bugs, now fixed and checked again the same way: deciding before Herdr's first answer that there was no agent, and an agent left as a shell when the name `compass` was taken.
  - A `backup` remote written to `compass.json` by hand, as the agent would, was configured on the next check and pushed the whole history to a bare repository.
- **The page's bridge**, in a separate offscreen web view with the same script and world: a click made through the web view passed the spawn button's fields on; a page script's `click()` was ignored; page scripts saw neither the handler nor the bridge; decorations marked a session's state, a done item and a started session.
- Not verified: a real Claude Code or Codex run (the trust question and permissions in `.claude/settings.json`), clicking the page's buttons inside the app and the New Session sheet they open, Settings → Compass, the welcome screen and restoring from it, the notification when the agent needs you, and the warning for a public GitHub remote. Background launches kept the window from rendering in later captures.

## Session console redesign (0.4.0)

Validated on 2026-10-04 on Apple Silicon with Xcode 27 / Swift 6.4:

- `swift test` and the README's `xcodebuild … test` command — **45 tests in 6 suites passed**, including the native application build. The built bundle contains `AppIcon.icns` and `CFBundleIconName = AppIcon`.
- New tests cover drag-and-drop offsets within filtered queues, the explicit `--takeover` flag, prompt encoding (bracketed paste, escape stripping, separate Return), prompt submission order, conflict fallback to watching, user takeover, and returning to watching when another client takes over.
- A separate Herdr 0.9.3 session (`--session shptest`) held demo workspaces running a small mock agent, with lifecycle states set through `pane report-agent`. A wrapper routed a SwiftPM build of the app to that session; the user's default session was never connected to. A temporary in-process harness (not committed) drove the UI and rendered window images:
  - Overview counts and cards, sidebar queue with states, shells section, Settings → General and Settings → Machines rendered as intended.
  - Selecting a session embedded its live terminal in the work area in LIVE mode. A single-line prompt typed into the composer and submitted with Return arrived as one line in the agent (`pane read` confirmed).
  - A multi-line prompt submitted to a zsh pane ran both lines, confirming bracketed paste plus a separate Return against a real bracketed-paste consumer.
  - With another control client attached, opening that session fell back to WATCH, showed the conflict notice and offered TAKE OVER. A CLI check confirmed Herdr's `--takeover` gives the new client frames and closes the old one with `terminal attach taken over`.
  - Moving a session to the top and down one place from the sidebar updated the saved ranking; filtering kept movement relative to visible rows.
- Creating and closing (same day, later): 51 tests pass. New tests cover the exact `workspace create` / `agent start` / `pane close` / `machine add|enable|disable|remove` arguments, remote `--machine` routing, `agent_not_ready` as a waiting agent, option-like values rejected before running Herdr, preserved SSH diagnostics, and store refresh after a change. Against the isolated session, Herdr 0.9.3 behaviour was checked first: `workspace create` returns the root pane and terminal; `agent start --kind claude` resolves the real agent executable and reports `agent_not_ready` while Claude Code asks to trust the folder (that test agent was closed immediately, without a prompt); `pane close` on a workspace's only pane also closes the workspace. Through the app, a shell-only session was created, opened in the work area, then closed; the queue and shells list updated. The New Session sheet, Fira Code interface and terminal, font settings (monospaced families only) and the logo and app icon (later redrawn as a German Shepherd watching the flock, and a German Shepherd in Matrix sunglasses) were inspected in rendered images. Adding, disabling and removing machines were not run against a real SSH host, to avoid changing the user's Herdr catalog.
- Not verified: prompts against a real Claude Code (or other) agent, keyboard shortcuts delivered through real key events, drag gestures with a pointer, and remote SSH terminals. Screenshots of the real screen were unavailable; images were rendered in-process.

## Session priorities (0.3.0)

Validated on 2026-10-03:

- `swift test` and the README's Xcode test command — **40 tests in 6 suites passed**, including the native application build.
- Five new tests cover relaunch persistence, identical terminal IDs on different machines, late arrivals, missing sessions, filtered movement, boundaries, invalid preferences, duplicate identifiers, and aggregation through a mock Herdr client during failures and recovery.
- A disposable app copy with a separate bundle identifier and synthetic local/remote machines displayed eight sessions with priorities. Via native accessibility automation, selecting the last remote session and clicking **Raise Priority** moved it from position 8 to 7; **⌥⌘↑** then moved it to 6. Selection and the enabled/disabled movement controls updated correctly.
- Sorting by State kept saved priority numbers and disabled movement; sorting Priority ascending restored **My order** and its controls. In the remote machine view, moving that session to its first visible slot changed its global priority to 5 and disabled further upward movement. Returning to All Agents confirmed that the four hidden local sessions retained positions 1–4.
- The GUI launch was slow and screenshot capture was unavailable. These checks verified accessibility state and control behavior; they do not claim a screenshot-based layout review. Preference reload and hidden-slot preservation were verified by automated tests.
- This feature's GUI tests use a fixture executable, not the user's Herdr installation or active sessions.

## Interactive terminals (0.2.0)

Validated on 2026-10-03 on the same Apple Silicon host with Xcode 27 / Swift 6.4:

- `swift test` and the README's `xcodebuild … test` command — **35 tests in 5 suites passed**, including the native application build.
- Terminal tests cover structured frames and binary input, malformed frames, explicit local routing, safe quoting of SSH arguments, no forced takeover, shell panes without agents, streaming subprocess input/output, startup timeout, connection failure, observation/input isolation, mode changes, detach and reconnect.
- A separate real Herdr 0.9.3 instance used temporary configuration/state and a newly created test workspace. A disposable app copy displayed its workspace and the live shell prompt in a native **Observing** window.
- A live harness using the actual `CLIHerdrClient` attached in control mode, sent a shell command, detached and reattached twice. It verified the same terminal ID and shell PID on both passes. The running shell survived each client disconnect.
- Release packaging — **passed**: optimized arm64 build, ZIP extraction/signature check, bundled SwiftTerm license comparison, DMG verification and SHA-256 checksums.
- The user's normal local server and active remote sessions were not changed. No authenticated remote terminal was available. SSH quoting and failure behavior are tested locally; real multi-host terminal transport remains unverified.
- Automated GUI access became unavailable after verifying observation. Enabling input through the button and typing through the native view still need a manual end-to-end check; input/detach/reconnect are verified through the real transport and mocked store.

## Dashboard (0.1.0)

Validated on 2026-09-30 on macOS 26.6.2 (Apple Silicon), using Xcode 27.0 / Swift 6.4. Deployment target is macOS 14; an actual macOS 14 runtime has not been tested.

## Automated and live checks

- `xcodebuild -project Shepherdr.xcodeproj -scheme Shepherdr -configuration Debug -destination 'platform=macOS' -derivedDataPath build CODE_SIGNING_ALLOWED=NO test` — **passed**, building the native application and running 27 tests in 3 suites.
- `swift test` — **passed**, the same 27 tests.
- `shepherdr-probe` against the real local installation — **passed**: executable discovered, Herdr 0.9.0 / protocol 22 decoded, one real workspace, no detected agents at verification time.
- Repeated the live probe on 2026-10-01 after updating the CLI to 0.9.3 — **passed** against the existing 0.9.0 server. Structured server status reported `compatible: true` and `restart_needed: false`; no server restart or session changes were performed.
- Xcode scheme XML, project plist and synthetic JSON fixtures — valid.
- Multiple machines, same IDs across machines, partial failures, recovery and stale retention — covered by the mock-client tests. No saved remote machine was available for real SSH verification.

## UI verification

The built native application was opened and inspected interactively:

- **Real installation:** All Agents showed Local as online and the expected empty agent state. Selecting Local displayed its actual workspace, directory, tab and pane counts, Herdr version and default session.
- **Synthetic cluster:** a separate disposable app copy used `SHEPHERDR_HERDR_PATH` to query an isolated fixture executable. Local and a remote profile supplied agents; another profile reported Herdr not running; a disabled profile stayed visible. No real Herdr configuration was changed.
- **Navigation and inspection:** checked All Agents, machine selection, workspace filtering, search by machine, the Blocked filter, and the metadata inspector. Machine/workspace ownership and routing identifiers matched the fixtures. Blocked agents appeared first with restrained orange emphasis.
- **Partial failure:** after a remote became unreachable, its four cached agents remained visible and marked stale while Local continued updating. The machine view exposed the error and last-received timestamp; summary counts excluded stale data.
- **Refresh and recovery:** pausing automatic refresh preserved the displayed snapshot. Manual refresh then recovered the remote and replaced cached rows, clearing stale markers.
- **Scale and layout:** checked 60 aggregate agents across two reachable machines, including unknown and future lifecycle values displayed as Unknown. Inspected a roughly 900 × 550 window with the inspector open: native horizontal table scrolling and vertical inspector scrolling kept content accessible.

The synthetic cluster validates application behavior, not a real SSH connection. No saved remote machine or real running coding agent was available during the initial verification. The updated CLI 0.9.3 supports `--machine`; real multi-host forwarding still needs successful SSH authentication and a saved profile targeting an existing remote session.
