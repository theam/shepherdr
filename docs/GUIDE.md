# Shepherdr guide

A native macOS console for the coding agents running in your [Herdr](https://herdr.dev/) workspaces, locally and over SSH.

The sidebar is your prioritized queue of sessions. Pick one and its live terminal opens in the work area, with a status bar underneath that opens the prompt editor for the next prompt. Shepherdr is an independent, open-source client; it is not an official Herdr application and is not affiliated with the Herdr project.

A bilingual (English/Spanish) quick guide with the same content comes with the app: **Help → Shepherdr Guide** (**⌘?**) opens it in the built-in browser. It is also [visual-guide.html](visual-guide.html) here.

## Features

- **Session queue:** every agent session in your own priority order, one line each: a mark for what the agent is doing, the session's name, its machine when you have several, and an envelope when it has mail, plus a red **✗** when checks failed on its pull request. Point at a row to see what the session is doing, with the branch it works on under it, and rest the pointer for a moment to see the same details as the **ⓘ** in the session's header (agent, state, machine, folder, branch, what it left running and its pane ID), and **Open Pull Requests** in the row's context menu opens its pull requests in the session's browser. Overview cards show the agent as well, by the mark its own interface shows (✻ Claude Code, >_ Codex, ✦ Gemini CLI, ◇ the rest). An agent that isn't working but left commands running, such as a dev server or a watcher, shows a turning clock **◴** instead of its state's mark. Drag to reorder, use the ▲▼ controls, **⌥⌘↑ / ⌥⌘↓**, or jump with **⌘1…⌘9**; a row's position is its priority. Gather sessions into **groups** that you prioritize like a single session, each with its own internal order, and optionally gather each project's sessions under a heading, from the **⋯** menu of the queue header.
- **Go anywhere with ⌘T:** a panel like Spotlight lists your sessions and Compass, the one you visited last first; type a few letters to narrow it.
- **Work area:** the selected session's live terminal, embedded in the main window like Herdr's own client. Switching sessions keeps the previous one as you left it, so going back shows it at once; the pane keeps running in Herdr either way.
- **Type in the terminal:** work in the agent's own TUI; **⇧⏎** adds a line instead of sending. Drop files or images on it to paste their paths, so Claude Code and Codex attach them. The terminal takes every key itself, so Escape, Control-C, Tab, the arrows and Return need no menu.
- **Optional prompt editor:** open it (**⌘L**) for long prompts you want to think through and edit with the mouse. **⏎** sends, **⇧⏎** adds a line, **↑/↓** recall this session's prompts.
- **Status bar:** across the bottom of the session, under the terminal, its browser and Resources, the prompt editor and dictation on the left, followed by where you are: the agent (Claude Code, Codex, Terminal…) with the model and effort that session runs with, such as `Claude Code · Sonnet 5.5 · high`. On the right, under a Claude Code or Codex session, your subscription: for the five-hour and weekly limits, a line for what is used and a thinner one for how much of the window has passed (used running ahead of time means burning faster than time), the percentage, and in how long each starts again (amber from 80%, red from 95%; rest on one for the exact figures). Claude's usage comes from Anthropic: Shepherdr reads Claude Code's token from your keychain and asks every five minutes. Codex's is read from its own session files in `~/.codex/sessions`, as its latest session saw it, with no request. The model and effort are read from each agent's own files (`~/.claude/projects`, `~/.codex/sessions`) by the folder the session works in, so they show for sessions on this Mac only, and two agents in one folder can be mixed up.
- **Split the terminal:** **⌘D** splits the pane you work in side by side and **⇧⌘D** stacked, each with a shell in its folder. Herdr's own splits show the same way.
- **Dictation:** record a prompt (**⇧⌘M**); it is transcribed on this Mac and lands in the prompt editor for you to review.
- **Unlocked by default:** sessions open with input enabled. Click the padlock to lock one read-only. If another client controls the terminal, Shepherdr stays locked and offers an explicit **Take Over**.
- **A browser per session:** click a link in the terminal and it opens in the session's own browser, next to the terminal; its tabs stay put while you work elsewhere. **⌘-click**, in the terminal or in a page, opens your default browser instead, as Slack links always do.
- **Resources:** the pull requests, issues and Claude artifacts a session links to gather in a panel on the right, one click from its browser.
- **Local files:** click a path an agent prints. Markdown opens rendered in the session's browser, HTML opens as a page, and any other file in its default app.
- **Sessions named in the terminal:** click another session's name or pane ID, as `shepherdr` prints them when an agent starts one, to open that session.
- **Click to choose:** click an option of an agent's numbered menu, such as a permission prompt, to select it; double-click to confirm.
- **Picks up where you left off:** after a restart, the session you had open comes back, and every session keeps its browser tabs, prompt editor and resources.
- **Notifications:** a macOS notification tells you when an agent finishes or needs you, with what it last said, and when a pull request's checks finish. Click it to open the session.
- **Sessions on hold:** mark a session as waiting for others, such as a planner waiting for the subagents it launched. It shows an hourglass until they finish, and the sessions it waits for are listed under it, in a tree you can collapse.
- **Compass:** the window's first mode, before Agents (**⌥⌘1** and **⌥⌘2**), with a page of your day kept by an agent of its own on this Mac. It starts by summing up your sessions; ask it in its terminal to cover more, such as your calendar or mail. It updates on the schedule you choose, keeps every day's page and a copy per run in `~/.shepherdr/compass`, commits them to Git and can push them to a private repository. Buttons on the page start the sessions it suggests, once you check them in New Session.
- **Agents that coordinate:** Shepherdr installs a small `shepherdr` command and a skill for Claude Code and Codex on each machine, Linux included. An agent asked to "start a session on buildbox" starts it there, nested under its own session, which goes on hold until the new one finishes: starting sessions always fans out. When you ask the new session to hand its result back, it does with `shepherdr handoff`, and Shepherdr delivers it as a prompt once the coordinator is free. Machines never connect to your Mac: Shepherdr collects what agents leave for it.
- **Create and close sessions:** **⌘N** creates a Herdr workspace with a shell in a folder; start Claude Code, Codex or any other supported agent in it and it joins the queue. Create one in a group with its **+**, or next to a session with **New Session in Same Folder…** (**⇧⌘N**). **Close Session…** in a session's context menu ends its pane after confirmation. **Rename…** renames its Herdr workspace.
- **Overview:** how many sessions need you, are working, done or idle, and a card per machine with its sessions and its processor, memory and disk use. Click states and machines to list the sessions in any combination of them. Plain shell panes are listed separately.
- **GitHub inbox:** the overview's **GITHUB** tab lists what the repositories you follow ask of you: pull requests awaiting your review, issues assigned to you and your own open pull requests, with their checks and the pull requests linked to each issue. **SUGGEST ORDER** lists the pull requests in the order to take them on.
- **Lid status:** the foot of the sidebar speaks up only when it matters: while agents work on this Mac it says **Keep the lid open**, since sleep would pause them. Otherwise the face beside the cup is all you see; remote sessions don't count, they keep going. The foot also warns when machines are offline (**N machines offline**, or **Not connected**) or updates are paused, and is quiet otherwise.
- **Coffee:** the cup beside the lid status keeps this Mac from sleeping, with power assertions like `caffeinate`, until you click it again or quit Shepherdr; it's off every time Shepherdr opens, so a forgotten coffee never drains the battery. Plugged in, the Mac won't sleep; on battery, closing the lid still sleeps it, and the foot says **Lid still sleeps it**. With coffee on, the cup steams and the face beside it opens its eyes wide. Right-click the cup to keep the screen on too (off by default, since agents don't need it).
- **Machines** in **Settings → Machines** (⌘,): add SSH machines, disable them to stop polling, or remove them from Herdr's catalog.
- Concurrent queries, independent connection states, and last-known data marked stale after failure.
- Automatic refresh (5, 15, 30 or 60 seconds), pause, manual refresh with **⌘R**, and refresh after wake. While Shepherdr isn't on screen, other machines are asked every 30 seconds.
- A dark phosphor console theme in [Fira Code](https://github.com/tonsky/FiraCode) (bundled), any installed monospaced font for the terminal, an 8-bit logo of a German Shepherd watching its flock, and a pixel-art app icon of a German Shepherd in Matrix digital rain.

No worktree management or menu-bar UI. Input goes only to the session you are viewing, while it is unlocked, to sessions agents hand work to through the agent tools, and to Compass's own agent on its schedule; Shepherdr creates sessions, closes them and changes machines only when you ask, or when an agent on a machine you trust asks for a session. Compass starts and replaces its own agent, in its own workspace. Closing asks for confirmation.

## Download and install

Download the `.dmg` from [the latest GitHub release](../../../releases/latest), open it, and drag **Shepherdr.app** to **Applications**. A `.zip` of the same app and SHA-256 checksums are also available. Requires **Apple Silicon (M1 or later) and macOS 14 Sonoma or later**; no Xcode is needed to run the download.

Downloads are **signed with The Agile Monkeys' Developer ID and notarized by Apple**, so macOS opens them after its usual confirmation for apps from the internet. Earlier versions had an ad hoc signature: if macOS blocks one of those and you trust the download, use **System Settings → Privacy & Security → Open Anyway** for Shepherdr, following [Apple's instructions](https://support.apple.com/en-us/102445).

### Updates

Once a day, while it's open, Shepherdr asks GitHub for its latest release. When there's a newer one, the foot of the sidebar offers it: **UPDATE** installs it, **NOTES** opens what's new, and **LATER** asks again the next day. **Shepherdr → Check for Updates…**, or **Check Now** in **Settings → General → Updates**, asks right away; the same section turns the daily check off.

Updating runs a script that comes with the app. Before it touches anything, it checks the download against the release's `SHA256SUMS`, and that the new app is validly signed by the same Apple team as the one running, is Shepherdr in the version expected, and passes Gatekeeper. Then Shepherdr quits. The script puts the new app where the old one was, keeping the old one aside until that works, and opens it. The new version says how the update went; if anything failed after Shepherdr quit, the old app is back and says why.

When Shepherdr can't write to its folder, or macOS runs it from a temporary copy because it was opened where it was downloaded, **DOWNLOAD** opens the release page instead. Builds you make yourself aren't signed with a Developer ID, so they don't update themselves.

Install and start Herdr separately, then open Shepherdr. The app reads your existing sessions and saved machines. Installing the [GitHub CLI](https://cli.github.com) and signing in with `gh auth login` is recommended: see the requirements below.

## Requirements

- macOS 14 Sonoma or later.
- A locally installed `herdr` supporting `machine list --json` and `api snapshot`.
- For remote machines, a local Herdr build with the documented global `--machine` option, plus compatible remote installations and an already-running server. Herdr CLI 0.9.3 provides that option; 0.9.0 does not. Shepherdr shows an incompatibility message on older CLIs.
- For interactive terminals, the Herdr installation on the target machine must support `terminal session observe` and `terminal session control`. Verified with CLI/server 0.9.3. Remote terminals require a Unix-like host, OpenSSH access and an existing saved profile.
- Recommended: the [GitHub CLI](https://cli.github.com) on this Mac, signed in with `gh auth login`. With it, Shepherdr confirms GitHub pull requests and issues, private ones included, fetches their titles, watches pull requests' CI checks and fills the GitHub inbox. Without it, resources are checked through the session browsers, which see private repositories only while you're signed in there, checks aren't watched and the inbox stays empty.

Local integration has been verified with CLI 0.9.3 querying an existing, compatible 0.9.0 server. Updating the CLI does not require replacing a compatible running server.

## Connect Herdr

Start Herdr normally on your Mac. Shepherdr queries the **local default session** and lists the agents that Herdr itself reports. A shell pane is not an agent: panes without one appear under **Shells**, or in their group when created there, and move into the queue as soon as Herdr detects an agent in them. A shell that shares a Herdr tab with an agent, as a split does, shows inside its session instead, and a tab of shells alone is listed once. Machine status and failure details are in **Settings → Machines**.

Configure SSH machines in Herdr, then refresh Shepherdr:

```sh
herdr machine add workbox --label "Build machine"
# A saved profile can target a named remote session:
herdr machine add lab --label "Lab" --remote-session agents
herdr machine list --json
```

One profile represents one session, not every session on its host. Disabled profiles remain visible and are not polled. You can also add, disable, enable and remove machines in **Settings → Machines**; Shepherdr runs the same `herdr machine` commands. Adding a machine lets Herdr prepare its remote server, which can install or start Herdr there. Shepherdr never prompts for credentials: SSH must authenticate without interaction, so load passphrase-protected keys into your SSH agent first, or run the displayed `herdr machine add` command in Terminal. Removing a machine only forgets its profile; its remote server and sessions keep running. Shepherdr never stops or restarts a Herdr server.

Shepherdr locates Herdr in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.cargo/bin`, then absolute entries in `PATH`. For a custom installation, set `SHEPHERDR_HERDR_PATH` to the absolute executable path in **Scheme → Run → Arguments → Environment Variables**, or launch the built app's executable with that variable:

```sh
SHEPHERDR_HERDR_PATH=/absolute/path/to/herdr \
  build/Build/Products/Debug/Shepherdr.app/Contents/MacOS/Shepherdr
```

Local executable discovery does not source shell startup files. Inherited `HERDR_SESSION`, `HERDR_SOCKET_PATH`, and pane/workspace/tab routing variables are cleared so opening Shepherdr from an agent pane cannot silently retarget Local. Herdr's own configuration environment is otherwise retained.

## Overview

**⌘0** shows the overview. Its first row counts the sessions that need you, are working, are on hold, are done or are idle. Every session counts once, by the same status the queue shows: a session [on hold](#sessions-on-hold) counts as on hold, with the hourglass and **ON HOLD** on its card, until what it waits for finishes; then it counts by its agent's state again. If its agent works or needs you meanwhile, it counts as that. The second has a card per machine with how many sessions it has and how busy it is, to help choose where the next agent goes: processor use over one second, memory in use, and the disk holding the home folder, amber from 70% and red from 90%. Below, **SESSIONS** shows a card per session in priority order and **GITHUB** your [GitHub inbox](#github-inbox). A card shows the session's pull requests as the queue does, **⇄ #12** or **⇄ 3 PRs** with their checks, or, for a session without any, its issues, **◉ #7** or **◉ 2 issues**; click them to open them in the session's browser.

Click a state or a machine to show only its sessions, and click more to add them: the sessions that need you on two machines, say. Each row counts what the other row lets through. Click a card again to drop it, or **SHOW ALL** to see every session again. The sidebar's queue is never filtered. A machine that isn't answering shows its sessions' last known state, so they are left out once you choose a state.

Herdr does not report machine load, so Shepherdr measures it every 15 seconds while the overview is on screen: on this Mac directly, and on other machines with a short `sh` script over SSH, with the same non-interactive settings as remote terminals. The script uses `/proc` on Linux, `iostat` and `vm_stat` on macOS, and `df` on both. Memory in use counts what `free` and Activity Monitor count. A machine that stops answering keeps its last reading for a minute.

### GitHub inbox

The overview's **GITHUB** tab shows what the GitHub repositories you follow ask of you. Shepherdr asks GitHub through its CLI, so install the [GitHub CLI](https://cli.github.com) and sign in with `gh auth login`; the inbox says so when it can't.

Press **REPOS…** to choose the repositories: type `owner/repo`, or paste a github.com link or a remote. **PAUSE** keeps one on the list without asking GitHub about it, and **REMOVE** stops following it and forgets which of its items you saw. The list is kept on this Mac.

The repositories your sessions work in are followed too, without adding them: Shepherdr asks each machine which GitHub repository each session's folder is in, by its `origin` remote, or else its first remote on GitHub. **REPOS…** lists them under **FROM YOUR SESSIONS**, with how many sessions work in each, while any does: **PAUSE** stops asking GitHub about one, and **FOLLOW** keeps it once no session works in it. **⌘T** finds sessions by their repository too, as `theam/shepherdr`.

Three columns show eight items each, and **more** the rest: **REVIEW REQUESTED** (◇), open pull requests awaiting your review; **ASSIGNED ISSUES** (◉), open issues assigned to you; and **YOUR PULL REQUESTS** (⇄). Pull requests show whether they're drafts or what reviewers decided, and their checks: ● running, ✓ passed, ✗ failed. Issues show the pull requests linked to them, connected by hand or set to close them when merged, such as **⇄ PR #12**, dimmed once none is open. A dot marks what is new or changed since you opened it. Click an item to open it in your default browser; its context menu copies the link or marks it seen or unseen.

Each item ends with what to do about it in a session. Shepherdr knows which sessions work on which pull requests and issues from the links each session collected, as **Resources** shows them: one session can work on several, and several on one. An issue is also worked on by the sessions of the pull requests linked to it.

- **IMPLEMENT**, on an issue no session works on, opens **New Session** for its repository in a new worktree, `issue-<number>`, with your usual agent and a first prompt asking it to implement the issue.
- **REVIEW**, on a pull request no session works on, opens **New Session** for it, in a worktree of its branch, with a first prompt asking to review it, or, for one of yours, to address its reviews and checks.
- **OPEN** opens the session working on it. **OPEN** with a count, when several do, opens **⌘T** with the item typed in, such as `theam/shepherdr#12`, to choose among them.

Read the session's first prompt, its folder and agent before you start it: nothing starts until you press **CREATE**. The new session starts with the item in its resources, so its button reads **OPEN** from then on.

The inbox asks GitHub when the overview appears and its last answer is more than five minutes old, right away when you follow, pause or remove a repository, and when you press **SYNC**. A failed sync keeps the last answer on screen, with a warning.

**Suggested order.** Tick **SUGGEST ORDER** to replace the pull request columns with one numbered list. Each pull request says what to do and why, such as `approved · checks passed · +12 −3 · 2 files · open 3d`, in this order:

1. **MERGE**: yours, approved, with no conflicts and checks that aren't running or failing.
2. **REVIEW**: others' waiting on your review.
3. **ADDRESS**: yours, with changes requested.
4. **RESOLVE**: yours, in conflict with the branch it merges into.
5. **FIX**: yours, with failed checks.
6. **FINISH**: your drafts.
7. **WAIT**: yours, with nothing to do yet: waiting for a review, for its checks or for the pull request it's stacked on.

Within each step, ready pull requests come before those with running or failed checks or conflicts, smaller before larger, and older before newer. A pull request stacked on another listed one, merging into its branch in the same repository, goes right after it and isn't suggested for merging first. Assigned issues keep their column. Shepherdr remembers whether the box is ticked.

## Commands left running

Agents often leave commands running after their turn: dev servers, watchers, test loops. When the agent is done or idle, a turning clock **◴** replaces its ✓ or ○ in the queue and on its overview card. Hover its row for how many commands are running, also while the agent waits for you. The session's **ⓘ** details list them all, under **Still running**, with how long each has been running.

Agents run each command in a shell of their own, so Shepherdr counts the shells still alive under an agent that is not working: shells the agent started, not ones you open inside its pane, and only after five seconds, so its hooks and status line don't count. Herdr only reports a pane's foreground processes, so Shepherdr asks Herdr once for each pane's shell and lists the processes under them every 10 seconds while its window shows: with `ps` on this Mac, and on other machines over SSH, which returns only the processes under those panes.

## Go to a session

**⌘T**, or **⌘T to search** at the top of the queue, opens a panel over the window, like Spotlight, to go anywhere: any session, any shell, or Compass. It lists them by when you last looked at them, the most recent first, and never the one on screen, so **⌘T** then **Return** takes you back to where you just were. Type a few letters to narrow the list, which stays in that order: every word must match the session's name, agent, folder, task or machine, or one of its pull requests or issues, and `name@machine` narrows to a machine. A number finds exactly that one: `theam/shepherdr#12`, `shepherdr#12` or `#12` lists the sessions working on it, not those on `#123`. **↑** and **↓** choose, **Return** or a click opens, and **Esc** closes it. Opening a session scrolls the queue to it.

When you last visited each session and Compass is kept on this Mac with your priorities: identifiers and times only.

## Prioritize sessions

The sidebar queue is your saved order across all machines; a session's position is its priority, and the first nine answer to **⌘1…⌘9**. Drag a session to a new position (a line shows where it will land), use the ▲▼ controls that appear on hover or selection, press **⌥⌘↑ / ⌥⌘↓** for the selected session, or choose **Move to Top/Bottom** from its context menu. **⌘1…⌘9** open the first nine sessions, **⌘[ / ⌘]** step through them and **⌘0** returns to the overview.

Ordering is saved on this Mac and restored when you reopen Shepherdr. Newly discovered sessions join the end. Refreshes, lifecycle changes, temporary disconnections and an incomplete machine catalog do not erase existing positions. Priorities follow the machine profile and terminal ID, so sessions with identical names on different machines stay independent. A newly created terminal has a new identity and joins the end.

### Groups

Groups gather sessions however you like: a project, a client, personal work. Create one with **New Group…** in the **⋯** menu of the queue header, **Session → New Group…**, or **Move to Group → New Group…** in a session's context menu; a group created from a session takes its place in the queue.

- A group is one position in the queue: drag its header, use its ▲▼ controls or its context menu to prioritize it like a session. Inside, its sessions keep their own order with the same controls.
- Drop a session on a group's header to add it, or between grouped sessions to place it exactly. **Move to Group** and **Remove from Group** in a session's context menu do the same without dragging. Groups do not nest.
- Click a header to collapse or expand the group. A collapsed group still shows how many of its sessions need you, and its sessions are skipped by **⌘1…⌘9**.
- Hover a header and click **+** (or use **New Session in Group…** in its context menu) to create a session in the group. Until you start an agent in it, it is listed in the group as a shell.
- **Rename…** and **Ungroup** are in the header's context menu. Ungrouping leaves the sessions where the group was, in their order; it never closes them.

The queue counts from top to bottom, groups included, so a session's position always reflects overall priority.

Only stable identifiers, their order, group names, whether projects are gathered, and which groups and project headings are collapsed are stored in the app's local preferences. Priorities are independent of Herdr state and are not synchronized between Macs.

### Projects

Turn on **View → Gather Sessions by Project**, or choose **Gather by Project** in the **⋯** menu of the queue header, to gather each project's sessions under a heading. A project is a Git repository: its main checkout and all its worktrees, on any machine. Outside Git, sessions in folders with the same name share one. The option is off by default, and turning it off shows the queue as before.

- Projects gather within each list: the top of the queue, and each group. Two or more sessions of a project in the same list share a heading, in the place of its highest-priority session; a lone session stays a plain row. Your groups stay as they are, and a project can have a heading in more than one of them.
- Positions follow the queue as it shows, so **⌘1…⌘9** and **⌘[ / ⌘]** go down the list you see.
- Under a heading, a session moves among its project's sessions: its ▲▼, **⌥⌘↑ / ⌥⌘↓** and its context menu reorder them there. Anything else steps over the whole project. Hover a heading and use its ▲▼, or its context menu, to move the project with all its sessions.
- Drag a session among its project's sessions to reorder them. Anything else dropped on a project lands just before or after it. Within the same list a session can't leave its project's heading, since it would only come back; move it to another group instead. Headings move with ▲▼, not by dragging.
- Click a heading to collapse or expand it. A collapsed heading still shows how many of its sessions need you, and **⌘1…⌘9** skip its sessions.
- Sessions on hold still list the sessions they wait for under them, whatever their project.
- Moving or dropping sessions while projects are gathered saves the order as it shows, so those moves stay when you turn the option off.

## Create and close sessions

**⌘N** (or **+** in the sidebar) opens **New Session**: choose a folder (on the selected machine), or paste a GitHub repository or pull request, and an optional name. Shepherdr runs `herdr workspace create --cwd … --label …` and opens its shell. Start an agent there as you would in any terminal: Herdr detects it, and the session joins the queue within one refresh.

Below the folder, the folders agents on the selected machine work in are one click away, the most used first, followed by those of shells still waiting for an agent. Git worktrees are left out: they belong to the session that made them.

Shepherdr checks the folder on its machine first, over SSH for other machines, where `~` means that machine's home. If it doesn't exist, New Session offers to start a new project there: **NEW PROJECT** makes the folder, runs `git init` in it and opens the session. Herdr itself would open a missing folder's workspace in the home folder without a word.

Each machine has a projects folder, `~/projects` unless you change it: this Mac's in **Settings → General**, other machines' in **Settings → Machines**, where `~` is that machine's home. A folder name alone means a folder inside it, and GitHub repositories are cloned into it. On this Mac, **CHOOSE…** starts there. **New Session in Same Folder…** in a session's or shell's context menu, or **⇧⌘N** for the one on screen, prefills its folder and machine and places the new session right after it, in the same group. A group header's **+** places it in that group.

### In a worktree

Tick **IN A NEW WORKTREE** and name a branch to work apart from the folder's own checkout. Shepherdr asks Herdr to open the branch's worktree (`herdr worktree open --branch …`) and, when it has none yet, to create one (`herdr worktree create --cwd … --branch …`). Herdr checks the branch out if it exists, or creates it from the folder's current commit, in a checkout of its own under its worktrees folder: `~/.herdr/worktrees/<repository>/<branch>` unless Herdr's `worktrees.directory` says otherwise. It also opens the repository's own workspace beside it when that isn't open yet, as it groups worktrees with their repository. A worktree Herdr already has open is simply opened: no second session. The session is named after the branch unless you name it.

### From GitHub

Paste a repository's link, such as `https://github.com/theam/shepherdr` or an SSH remote like `git@github.com:theam/shepherdr.git`, instead of a folder. Shepherdr opens your clone of it on the selected machine: the folder of that name in its projects folder, or one a session there already works in, when one of its remotes points at the repository. Without one, it clones the repository into the projects folder first: from the SSH remote you gave, else over HTTPS, through the GitHub CLI when it's signed in on that machine. A folder of that name holding something else stops it with a message. Git never asks for anything: a clone that needs a password or an unknown host key fails with Git's own message. **IN A NEW WORKTREE** works here too.

Paste a pull request's link (`…/pull/12`) and the session opens in a worktree of its branch. Shepherdr asks GitHub which branch it comes from, through the GitHub CLI on this Mac (which sees private repositories) or else GitHub's public API, and shows its title. It finds or clones the repository as above, fetches the branch and checks it out in a worktree, so the agent can push to the pull request. A fork's pull request, whose branch could be named anything, goes to a branch `pr-12` instead, from GitHub's `pull/12/head`, which also covers pull requests whose branch was deleted. The session is named `repository#12` unless you name it, and starts with the pull request in its **Resources**. Asking again for the same pull request opens the same worktree.

**Close Session…** in a session's context menu asks for confirmation, then runs `herdr pane close`. It is deliberately only in the context menu, away from everyday controls. This ends the agent process. When it is the workspace's last pane, Herdr closes the workspace too.

## Work with a session

1. Select a session in the queue or an overview card. Its terminal opens in the work area with keyboard focus, unlocked: the open padlock in the session's header means your input goes to the session. The **ⓘ** beside the tools shows its machine, folder, agent, commands left running and, below, Herdr's own details (tab, pane, terminal ID).
2. Type in the terminal as you would in any terminal. **⇧⏎** sends Esc-Return, which Claude Code, Codex and Gemini read as a new line, so it no longer submits the first line of a multi-line prompt.
3. For longer prompts, open the prompt editor with the pencil icon in the status bar at the bottom or **⌘L**. It is closed by default and keeps its draft while closed (the icon shows a dot). **⏎** or **SEND** sends the prompt as a bracketed paste followed by a separate Return, so agents receive it verbatim, then closes the editor and returns to the terminal.
4. Click the padlock (or press **⌘E**) to lock the session read-only; click it again to unlock. A locked session's editor still takes drafts. **⌘⎋** sends Escape, which interrupts most agents.
5. Click a web link in the terminal to open it in the session's browser, or **⌘-click** it to open your default browser. Paths to files on this Mac work too, absolute, under `~` or relative to the session's folder: Markdown opens rendered in the session's browser, HTML as a page, and other files in their default app (**⌘-click** always uses the default app). Links agents mark up explicitly and plain-text `http(s)://` URLs both work, including URLs that wrap across lines; the pointer turns into a hand over them.
6. Click another session named in the terminal to open it: its pane ID, such as `w3:p1` in "In Herdr: pane w3:p1", its terminal ID (`term_…`), or its name, the agent's or the workspace's, as a word of its own, as in "Started fix-login (claude) on buildbox". A pane ID means a pane on the session's own machine, unless `@machine` or a `--machine` option on the same line names another. A name means a session on the same machine first; `name@machine`, with the machine as the queue shows it, picks another. Names inside paths, file names and longer words, names shorter than three characters, the session's own names, and names that sessions on several other machines share don't link. The pointer turns into a hand over the ones that do.
7. Drop files or images on the terminal to paste their paths into the agent's prompt, escaped as other macOS terminals do; Claude Code and Codex attach dropped images. An image dragged without a file, from a web page say, is saved as a PNG first. In a session on another machine, Shepherdr first copies each file there over SSH, into `~/.cache/shepherdr/drops` (readable only by you, cleared after a week), and pastes that path instead. The session must be unlocked.
8. Click an option of an agent's numbered menu, such as Claude Code's or Codex's permission prompts, to move the selection there; double-click it to confirm. Shepherdr presses the arrow keys and Return for you, so it works with any agent that draws a numbered menu with a marker on the selected option. Other plain clicks go to the program if it reads the mouse: in Claude Code's full-screen mode (`/tui fullscreen`), clicking a word of the prompt moves the cursor there. Herdr 0.9.2 or later delivers them and drops them for programs that don't read the mouse, such as Claude Code's default mode or a shell.
9. To have one agent message another, use the session's Herdr pane ID, such as `w3:p1`. It is under **For other agents** in the session's **ⓘ** details: click it to copy it, or right-click it (or the session in the queue) for **Copy Reference for Agents**. That copies the pane ID with the command an agent runs to prompt it, `herdr agent prompt w3:p1 "<message>"`, ready to paste into a prompt such as "report your progress to the coordinator (…)". Agents in the same Herdr session can run it as is.
10. The folder button in the header, **Show Folder in Finder** in the session's context menu, or **⇧⌘O** opens the folder the agent works in, in a Finder window. Finder only opens folders on this Mac, so for a session on another machine the button is off and its help says where the folder is.
11. Selecting another session or quitting Shepherdr only detaches this client. Herdr keeps the pane and its process running.

Shepherdr never takes input away from another client implicitly. If one is attached, the session stays locked with a notice; **Take Over** is an explicit choice that uses Herdr's `--takeover`. If another client later takes over, Shepherdr locks the session again. Terminal resizing uses Herdr's supported viewport/resize messages. Scrolling with the trackpad or mouse wheel moves through the history Herdr keeps for the terminal (in a full-screen program such as `less`, Herdr scrolls the program instead); while you read earlier output, **↓ LATEST** takes you back, and so does typing. Herdr scrolls a terminal for every client at once and only for the one in control, so a locked session doesn't scroll. Dragging always selects text natively, even in programs that read the mouse. Selecting text with the mouse copies it; while the button is down, new output waits so the selection holds still. **Option** types what your keyboard layout gives it (such as **⌥2** for @ on a Spanish keyboard), as in Terminal; **⌥←/⌥→**, **⌥⌫** and **⌥⏎** still send the Meta sequences TUIs and shells use to move by word, delete a word and add a line. **⌘←/⌘→** go to the start and end of the line and **⌘⌫/⌘⌦** delete to them, as in macOS text fields: Shepherdr sends Control-A, Control-E, Control-U and Control-K, which agents and shells read. **⇧↑ ⇧↓ ⇧← ⇧→** reach the program as other terminals send them, for agents such as Codex that ask for them. Drafts and prompt history are kept in memory per session and are never written to disk.

### Splits

**⌘D** (**Session → Split Right**) splits the pane you work in, with a shell in its folder beside it; **⇧⌘D** (**Split Down**) puts the shell underneath. Shepherdr runs `herdr pane split`, so the split is Herdr's own: a session shows every pane of its Herdr tab as Herdr lays them out, including splits made in Herdr or another client, and a line separates them. Each pane takes the size it has in the window.

Click a pane to work in it. It's outlined, and the prompt editor, the padlock and **⌘⎋** act on it; the header, the browser, the resources and the session's place in the queue stay the session's. Links clicked in any pane open in the session's browser.

**⌘W** in a split, or **Session → Close Split**, closes it: a shell at its prompt closes at once; a running command, or an agent, asks first. Typing `exit` in a split's shell closes it too. The keyboard goes back to the session's own pane, where **⌘W** closes the window as usual. Split shells aren't listed under **Shells** or in **⌘T**: they belong to their session. An agent started in a split joins the queue like any other, and opening it shows the same tab.

### Browser

Each session has its own browser column, to the right of the terminal. Clicking a link opens it there in a new tab, or switches to the tab already showing it; the globe icon in the session's header or **⌘B** shows or hides the column, and **+** opens an empty tab. The tabs stay loaded, scrolled and signed in while you switch sessions, so a pull request you are reviewing is still where you left it. Pages stay loaded out of sight, up to 24 besides the ones on screen; past that, the pages of the sessions you go back to least let go of their memory and of whatever they keep running, and more of them do when macOS runs short of memory (6 under memory pressure, none when it's critical). The tab keeps its address and title and loads the page again when you show it, without its scroll position, back and forward history, or anything typed in a form. Compass's page, a page still loading, and pages another page opened as a window stay loaded. Pages that open new windows open new tabs. **⧉** opens the current page in your default browser.

**⌘-click** a link in a page to open it in your default browser instead.

Slack links, wherever you open them (the terminal, a page, a resource, the address bar or Compass), leave Shepherdr as a ⌘-click does: macOS opens them in your default browser, where Slack offers to open them in its app. A page's **Sign in with Slack** stays in the column.

**Help → Shepherdr Guide** (**⌘?**) opens the quick guide in the browser of the session you are looking at, and **Help → Herdr Documentation** opens Herdr's. On the overview they open in a browser of its own, which **⌘B** also shows or hides; its tabs are not kept after a restart.

Sign-ins are shared by every session's browser and persist across launches, in WebKit's own storage for Shepherdr. Safari's sessions and cookies cannot be shared with other apps, so sign in once here, or **⌘-click** links to use Safari. Shepherdr remembers each session's tabs, the selected one and whether the browser was open: after a restart they come back, and each page loads the first time you look at it. Closing a tab forgets it, and closing the session forgets them all.

Local Markdown is rendered with GitHub-flavored Markdown (tables, task lists), with its images, and without running any script it contains; **↻** renders the file again. Links between local files open the same way. HTML files open as pages that can read their own folder.

### Resources

The **RESOURCES** panel, to the right, collects the pull requests and issues (GitHub, GitLab, Bitbucket, Linear, Jira) and Claude artifacts a session links to. Each kind lists the ten most relevant first, the ones you open most and the ones mentioned most, then the newest; **more** shows the rest. GitHub numbers pull requests and issues together and redirects one kind of link to the other, so a number appears once. Pull requests and issues carry GitHub's own icons and colors: green while open, purple once merged or completed, red when a pull request was closed without merging, and gray when an issue was closed as not planned or as a duplicate. The refresh button (↻) in the panel's header reads the session's recent output again: pull requests, issues and artifacts it no longer mentions leave the panel (links an agent pinned stay), and the rest are checked again, including their GitHub state, so reopened or newly closed ones are up to date.

Each new resource is checked once: links agents write as examples point nowhere. If the [GitHub CLI](https://cli.github.com) is installed and signed in, Shepherdr asks GitHub about its pull requests and issues, private ones included; anything else it loads out of sight in the session browsers, with their sign-ins. Resources that don't exist leave the panel, and the rest show their page's title. A page that asks you to sign in is checked again on a later launch, after you sign in through the session's browser.

**Pull request checks.** While you look at a session, and if the GitHub CLI is installed and signed in, Shepherdr watches the CI checks of its open GitHub pull requests: one query for all of them, every 15 seconds while checks run and every 2 minutes once they're done, paused while the Mac sleeps or Shepherdr isn't on screen. A mark follows each pull request in the panel and in the queue: ● running, ✓ passed, ✗ failed (as soon as one fails). When an agent finishes a turn, its session's pull requests are checked once more, since it may have pushed. When a pull request's checks finish, a notification says whether they passed or how many failed; click it to open the session with the pull request. Shepherdr finds them in the terminal while you watch it, in Herdr's recent output when you open the session, and in what an agent printed when it stops. Click one to open it in the session's browser; its context menu opens it in your default browser, copies the link or removes it. the Resources icon in the status bar hides or shows the panel, which appears once a session has a resource. Resources are remembered with the session's tabs.

**What Shepherdr remembers of GitHub.** What GitHub says about a pull request or issue, whether it is one and its title, comes back from a week-old answer before Shepherdr asks again, whichever session or inbox it came from: two sessions mentioning the same pull request ask once. Checks and issue states are kept too, so every session's pull requests show their last known checks from launch, and merged or closed ones are never asked about again. The repository each machine's folders are in is asked again after a week, or a day for a folder in none. All of it stays in memory, is written once a minute and as Shepherdr quits to `~/Library/Caches/com.theagilemonkeys.Shepherdr/github.json`, readable only by you, and is forgotten after a month. Delete the file to start over.

### Dictation

The microphone in the status bar at the bottom, or **⇧⌘M**, starts recording right away and opens the prompt editor. Press **STOP** (or **⇧⌘M** again) and the transcript is added to the draft for you to read and edit before sending; **×** discards the recording. Transcription runs on this Mac with NVIDIA's [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) through [FluidAudio](https://github.com/FluidInference/FluidAudio), the same engine as [scribe](https://github.com/theam/scribe). It detects the language among 25 European ones, and handles English technical terms inside Spanish speech well.

The model is about 460 MB. The first time, Shepherdr asks before downloading it from Hugging Face; if scribe already downloaded it, Shepherdr reuses that copy. It loads into memory while you speak the first time after each launch. Your voice is kept in memory only while recording and never leaves the Mac. Shepherdr asks for microphone access the first time you dictate.

## Notifications

When an agent stops working, because it finished or because it needs you (a permission prompt, a question), Shepherdr posts a macOS notification with the session's name, its state and agent, and the first paragraph of the agent's last message, read from its terminal; when there is none, Herdr's summary of the session. Click a notification to open the session. The session you are looking at in the front window never notifies, and agents that go idle don't either. Shepherdr notices state changes when it refreshes the queue (**Settings → General → Refresh sessions**), so a notification can take that long to arrive; while refreshing is paused, none arrive. While Shepherdr isn't on screen (its window hidden, minimized or covered, the displays asleep, the screen locked), this Mac keeps that pace but other machines are asked every 30 seconds, each time over SSH, so their notifications can take up to that long. Coming back to the window asks every machine at once.

macOS asks for permission the first time one is due. Turn them off in **Settings → General → Notifications**, or change their style in **System Settings → Notifications → Shepherdr**.

## Sessions on hold

When one session has to wait for others, such as a planner that launched subagents, choose **Wait For…** in its context menu, or **Session → Wait For…** while it's open, and type a few letters of a session it waits for: names that start with them come first, and `@` narrows to a machine, as in `api@buildbox`. **↑** and **↓** move through the matches, and **Return** or a click puts the session on hold for the one highlighted. Sessions it already waits for show **✓**; choosing one again stops waiting for it. The session shows an hourglass in the queue instead of its state until they have all finished; then it shows its agent's state again, and stays nested over them until you take it off hold.

A session it waits for finishes once it has worked and is free again, or when its turn ends before anyone looks (Herdr's **done**). A new session that hasn't had its first prompt yet doesn't count as finished, and one that gets busy again puts the session back on hold. Holds chain: a session waiting for one that is itself on hold keeps waiting until the last one in the chain finishes. If its agent works or needs you while it waits, the queue shows that instead of the hourglass.

The sessions it waits for move under it in the queue, joined by tree lines, and move with it. Click **▾** with their count to hide them and **▸** to show them again; while hidden, the count turns amber if one of them needs you. A session waited for by several others is listed under the first of them. To take one out of the tree, choose **Stop … Waiting for This** in its context menu.

In the tree, the sessions it waits for follow the session waiting for them, so they have no position of their own.

Opening a session on hold shows a panel above its terminal with the sessions it waits for and their state. Click one to open it, **×** to stop waiting for it, **+** to find another one to wait for, or **RESUME** to take the session off hold. Sessions that others are waiting for list them under **WAITED ON BY**. Holds are saved on this Mac with your priorities and only contain session identifiers. Shepherdr also keeps a copy in Herdr, as tokens on the waiting session's pane, so a new Mac, or this one after losing its settings, gets them back from there. The copy on this Mac wins: a hold you ended here doesn't come back from Herdr. Herdr has room for about 18 holds a session; more stay on this Mac only.

A session that closes, from Shepherdr or anywhere else, drops out of holds: once its machine answers without it for 30 seconds, nothing waits for it anymore, and it no longer waits for anything. A machine that doesn't answer keeps its sessions' holds until it does. The sessions that waited for it say so in a notice.

A shell, a pane without an agent, has no agent to hand work back, so a session waiting for one waits for the command it runs, such as a script started with `herdr pane run`. Shepherdr looks at the shell on each refresh while a session waits for it, and only then: the shell shows **running** while the command runs, and once it is back at the shell's prompt the hold finishes, with a notice. Shepherdr also notices a command that finished between two refreshes, by its output. A shell that hasn't run anything yet keeps the session waiting.

Shepherdr works statuses out once per refresh, and only for sessions whose state changed and the sessions waiting for them; a session on hold isn't worked out again until something it waits for changes. Every view, the overview and Compass's page show that same status.

**HANDOFF AND CLOSE**, on the **WAITED ON BY** line, wraps a session up for the sessions waiting for it. After you confirm, Shepherdr waits until its agent is free and types a request into its prompt: hand the work back with `shepherdr handoff`, in a message that stands alone with the files that matter. As soon as that handoff reaches Shepherdr, the session closes and its pane ends. From then on Shepherdr holds the message and files and delivers them as usual, so nothing goes with the pane. It needs the [agent tools](#agents-that-coordinate) on the session's machine.

- **While it waits:** the line says **HANDS OFF ONCE FREE**, then **HANDING OFF**. **CANCEL** keeps the session open; a request already typed stays in the agent's prompt.
- **Across machines:** the session still closes when the handoff arrives. The handoff itself waits for your approval in the waiting session's mail, and that session's banner says so.
- **When it stays open:** the session stays open, with a notice, if the handoff goes to another session or to none, if asking the agent fails, or if no handoff comes within 15 minutes of asking while the agent isn't working.
- **Quitting Shepherdr:** a pending close isn't saved, so quitting forgets it. A handoff the agent already wrote is still collected and delivered.

The interface uses the bundled Fira Code. **Settings → General → Terminal font** chooses the font and size for the terminal and prompt editor from the monospaced families installed on this Mac. **Ligatures**, off by default, join characters such as `->` and `!=` into single symbols in fonts that have them, like Fira Code; busy terminals redraw more slowly with them.

For remote terminals, Shepherdr invokes the remote installed Herdr CLI through `/usr/bin/ssh` using the saved profile's target and session. Host keys must already be trusted and authentication must work without a prompt. It uses the host's `herdr` on PATH, then checks `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.cargo/bin`. Connection or compatibility failures appear in the work area and leave the rest of the app usable.

Shepherdr's other trips to a machine, such as checking a folder, reading its load or collecting letters, share one SSH connection, as Herdr's own do, instead of connecting every few seconds. It stays open for a minute after the last one, and its socket lives in `~/.shepherdr/ssh`, readable only by you. A terminal always gets a connection of its own, so that leaving it ends its remote session. Connections that stop answering, as after the Mac sleeps or changes networks, end within about 20 seconds, and the next trip opens a new one.

When a terminal's connection drops, Shepherdr reconnects on its own. The banner keeps the error and counts down to the next attempt; the wait doubles after each one, from 1 second up to 5 minutes, and **RECONNECT** stays disabled meanwhile. After an hour of trying it stops, says how many times it tried, and **RECONNECT** tries again. Time asleep with the lid closed doesn't count toward the hour. A terminal Herdr no longer has, or an incompatible Herdr, isn't retried. A terminal whose program ended, such as a shell you typed `exit` in, isn't a dropped connection: its pane leaves at once.

Shepherdr keeps the terminals of the sessions you leave, with what they last showed: going back within 30 seconds finds them still attached, and later, still showing their last screen while they attach again. When nobody can see a terminal for 30 seconds, because you opened another session, Shepherdr's window is minimized, covered or on another Space, or the screens are asleep or locked, Shepherdr detaches it, so an agent writing all the while costs nothing meanwhile. It attaches again as soon as it shows, locked or unlocked as it was, and keeps the last screen until Herdr sends the whole one.

Shepherdr keeps up to 24 terminals out of sight, and fewer when macOS runs short of memory (8 under memory pressure, 2 when it's critical). When it has to let some go, it keeps the sessions you go back to most: each visit counts, and older visits count half as much every hour, so a session you open all day stays ahead of one you looked at once a minute ago. The open session, Compass's and the sessions that need you always stay. A terminal let go connects afresh the next time you open its session. That is not a dropped connection: nothing reconnects in the meantime. Links the session prints while the window is hidden are collected for **Resources** when it shows again.

## Agents that coordinate

Agents can start sessions, wait for them and hand work back through Shepherdr, on any of your machines. They do it with `~/.shepherdr/bin/shepherdr`, a small command Shepherdr installs on each machine, and a skill that teaches Claude Code and Codex when to use it. Say "start a session on buildbox that fixes the failing test" to an agent, and it starts one there with your prompt. The new session nests under the agent's own, which goes on hold until it finishes. Handing off and closing are yours to decide: ask the new session to hand off, or use **HANDOFF AND CLOSE**, and its result comes back to the agent as a prompt. The skill tells agents never to hand off or close on their own, and never to ask the sessions they start to.

### Install the agent tools

The first time Shepherdr reaches a machine without the tools, its sessions show a banner: **INSTALL** copies them there over the SSH connection Shepherdr already uses; **NOT NOW** asks again next launch; **DON'T ASK HERE** never offers them for that machine. This Mac is a machine too. **Settings → Agents** installs, updates and removes them on any machine, and shows what each one has: its system, and whether Claude Code and Codex have the skill.

Installing writes only `~/.shepherdr` (the command, its skill and the machine list) and the skill folders of the agents installed there, `~/.claude/skills/shepherdr` and `~/.codex/skills/shepherdr` (or under `$CODEX_HOME`). It changes no shell startup files, needs no `sudo` and doesn't touch `PATH`: agents run the command by its full path. Everything is readable only by you. The command is a POSIX `sh` script that only needs Herdr, so it runs on Linux and macOS alike. Agents already running pick up the skill when they restart; the command works right away.

When Shepherdr brings newer tools, the machine's sessions offer **UPDATE**. **Settings → Agents → Updates** can update them without asking, or never. If you install Claude Code or Codex on a machine after the tools, Shepherdr adds the skill the next time it checks that machine. **Remove** deletes the command and the skills; the letters stay in `~/.shepherdr` until you delete it.

### What agents can do

| Command | What it does |
| --- | --- |
| `shepherdr machines` | Which machine this is, and how each other machine is reached |
| `shepherdr folders [--machine NAME]` | The folders where sessions already work on a machine |
| `shepherdr spawn [--machine NAME] [--cwd DIR] [--kind KIND \| --shell] [--name NAME] [--prompt TEXT \| --prompt-file F] [--split right\|down] [--no-wait]` | Starts a session and links it to the caller |
| `shepherdr handoff [--to NAME] [--file F]… [MESSAGE \| --message-file F]` | Hands work back to the session waiting for the caller, or to a named one, when you ask |
| `shepherdr wait-for NAME…` / `resume [NAME…]` | Puts the caller on hold for other sessions, or takes it off |
| `shepherdr pin URL [--title TEXT]` | Adds a link to the caller's resources |
| `shepherdr open URL` | Opens a page in the caller's browser in Shepherdr |
| `shepherdr notify MESSAGE` | Shows you a notification |
| `shepherdr close [--force] [NAME…]` | Asks you to close those sessions, or the caller's own |
| `shepherdr status` | This machine, the caller's pane and letters not collected yet |

`spawn` creates a Herdr workspace in the folder (or splits the caller's pane with `--split`), starts the agent, by default the caller's own kind, and sends it the prompt. Shepherdr puts the new session right after the caller, in its group, nested under it, and keeps the caller on hold until the new one finishes; `--no-wait`, which the skill keeps for when you ask for a session that isn't linked, only places it. If the agent stops at a startup question, such as trusting the folder, Shepherdr sends the prompt once it is ready. Names are Herdr agent names, and the workspace gets the same one. A session asked for on this Mac starts once the Mac is awake and online, as [Compass's runs](#runs) do.

A handoff goes to the sessions waiting for its sender, unless `--to` names another by its agent or workspace name, with `@machine` to tell machines apart. Shepherdr delivers it as a prompt once that session is free (idle or done), one at a time, with the message and the paths of its files; to a session on this Mac, only while the Mac is awake and online, as [Compass's runs](#runs) are. The files are kept on this Mac in `~/.shepherdr/inbox`; for a session on another machine, Shepherdr copies them there first. If nobody waits for its sender, the handoff waits in the session's mail panel with **SEND TO**.

Ask an agent to close a session, its own included, and it runs `shepherdr close`; the skill tells agents to close sessions only when you ask, and, when you ask for both, to hand off first. Nothing closes until you confirm: each session asked for shows a close request in its mail panel, with a notification, and **CLOSE** closes it as **Close Session** does, ending its pane and agent. A session that asked to close itself closes once its agent finishes its turn, so its last answer gets written. Shepherdr doesn't ask about a session whose agent is working or needs you; the asking session says why, unless the agent added `--force`, which the skill keeps for when you asked for it. Compass's own agent never closes this way.

### Machine lists

The skill doesn't name your machines: they change, it doesn't. Instead, Shepherdr writes `~/.shepherdr/machines` on each machine that has the tools, with that machine's own view: its name, and how it reaches each of the others. From this Mac, Herdr reaches every saved machine directly. From another machine, only Shepherdr reaches the rest: `spawn` there files a request that you approve. Shepherdr rewrites a machine's list only when it changes, such as when you add, rename or disable a machine.

The lists only hold names and routes: never hosts, users, ports or keys. Herdr profile IDs only go into this Mac's own list. This Mac goes by its computer name unless you set another in **Settings → Agents → This Mac**. Turn off **Share the machine list** for a machine to let it know only its own name.

### Letters

Machines never connect to this Mac. The command leaves each request as a letter in `~/.shepherdr/outbox` on its machine, and rings a doorbell: a token on the caller's Herdr pane, which Shepherdr sees in its next refresh. Shepherdr then collects the machine's letters over SSH, keeps them in `~/.shepherdr/inbox` on this Mac, and moves them to `outbox/.collected` there. A manual refresh (**⌘R**) also looks in every outbox, for letters whose doorbell was lost when Herdr restarted. While Shepherdr is closed, letters wait.

Letters are data: Shepherdr checks every field, accepts only http and https links and plain files with safe names, and never runs anything in them. Letters from this Mac apply on their own, except requests to close a session, which always wait for you. From another machine, four things wait for you in the session's mail panel, on the overview and as a notification, with an amber envelope in the queue:

- **Handoffs to a session on a different machine**, since their text becomes a prompt for an agent there: **LET THROUGH** delivers them, **VIEW** shows the message first.
- **Requests for sessions** on machines it can't reach: **START** starts it with the requested folder, agent and prompt, linked to the session that asked.
- **Pages to open:** **OPEN** opens it in the session's browser.
- **Requests to close a session**, from any machine, this Mac included: **CLOSE** closes it.

**Settings → Agents → Trust its letters** lets a machine's letters through without asking, except requests to close a session. A cyan envelope means mail waits for its session to be free. Shepherdr keeps the letters' files for a month.

## Compass

Compass is the window's first mode: **COMPASS · AGENTS**, beside the window's buttons, or **⌥⌘1** and **⌥⌘2**. It shows a page of your day, kept by an agent of its own on this Mac, with the terminal of that agent beside it. The page says what deserves your attention; you talk to the agent all day to act on it, and buttons on the page start the sessions it suggests.

The COMPASS tab shows a green dot when the page changed since you last looked, cyan while a run is under way, and amber when the agent waits for you. The AGENTS tab counts your sessions, in amber when some need you.

### Start Compass

Open Compass and press **START COMPASS**, choosing the agent: Claude Code if you have it, Codex, or another Herdr agent kind. Shepherdr creates `~/.shepherdr/compass`, starts the agent there in a Herdr workspace named `compass`, and asks it for the first page. The first time, Claude Code asks whether you trust the folder: answer in Compass's terminal. Compass's agent never joins the queue, the overview or the shells: it lives in its mode.

The first page only looks at your sessions: what needs you, what finished, with its pull requests and checks, what's in progress and what's been idle for days. It ends with a **Make it yours** card. Ask the agent, in its terminal, to cover more: your calendar for the day strip, your mail or chat for what came in, your goals. It changes its own instructions in `prompt.md` and tells you what it changed. It uses whatever its agent can reach, such as Claude Code's connectors, so nothing in Compass assumes a service.

**Already have a Compass backup?** Paste its Git remote on the welcome screen and press **RESTORE**: Shepherdr clones it into `~/.shepherdr/compass`, with your prompt and every page.

### Runs

A run is one prompt to the agent: "update the page". Shepherdr sends it on the schedule in **Settings → Compass**: only when you run it, once a day, or every so often within hours of the day (every hour from 9 to 18, Monday to Friday, to start with). **▶ RUN** at the top of Compass's column, or **⌥⌘R**, runs it now. Shepherdr has to be open to run Compass.

- **Missed runs happen once.** If the Mac slept or Shepherdr was closed through several runs, Compass runs once when it can, and then waits for the next time on the schedule. Only runs due that day are made up: a Friday evening run doesn't happen on Saturday.
- **A run waits for this Mac to be awake and online.** Asleep on battery, a Mac wakes every so often for a few seconds with its screen off, and its network doesn't work then. An agent started then would go the whole day without what it loads only at launch, such as Claude Code's connectors to your calendar or mail. So Compass starts its agent and sends it runs only while this Mac is fully awake, and, for Claude Code, Codex and Gemini, online with their service's address resolving. A new agent gets its first run 15 seconds after it starts; if the Mac slept or lost the network meanwhile, Shepherdr starts it again first, unless it has worked or you typed to it. Compass's column says what the run waits for.
- **A run waits for you.** While the agent works or asks you something, or you typed to it in the last two minutes, the run waits. A handoff waiting for the agent goes first.
- **One agent a day.** The day's first run starts a fresh agent, closing yesterday's, so each day starts with a clean context. The rest of the day's runs, and your conversation, go to the same agent, which knows what you asked it in the morning.
- **The first and last runs of the day** say so, so the agent builds the page from scratch in the morning and closes the day in the evening.

Compass's column shows how the last run went, when the next one is, and what Compass is waiting for. If the agent stops at a question, such as a permission, the tab turns amber and a notification tells you; answer in its terminal. **cancel this run** stops waiting for a run without touching the agent.

### The page

Every page starts from Shepherdr's template, so every day reads the same: the date, a one-line headline, a day strip and a footer with the sources. The strip covers the hours in **Settings → Compass**, in this Mac's time: a line marks the time and moves on its own, and what's past dims. The agent decides everything in between, such as lists, tables and diagrams, and links what it mentions.

The page opens in the first tab of Compass's browser, which can't be closed; links open in tabs beside it, and **⌘-click** opens your default browser. Compass's column lists today's runs, each with the copy of the page it left, and every earlier day: click one to see it. **⌘B** shows or hides the agent's terminal.

### Buttons on the page

The page's buttons ask Shepherdr for something, and nothing happens until you confirm:

- **Start a session** opens New Session with the machine, folder, agent, name and first prompt filled in, and where in the queue it goes. Read the prompt before you start: the page is built from what others wrote. The session starts out of sight, and the page shows it beside the button with its state. With **Compass waits for it** ticked, as it is by default, Compass's session goes on hold for it, like any session an agent starts, and a handoff you ask it for comes back to Compass's agent, which updates the page.
- **Ask** puts text in Compass's prompt editor, such as "apply P1", for you to send.
- **Open a session** and **prompt a session** switch to Agents and open that session; a prompt lands in its editor for you to send.
- **Done** marks an item done on the page. The agent sees your marks in its next run.

Sessions the page names show their state beside their name, kept current as the queue refreshes.

The page's buttons work through a script that runs apart from the page's own scripts, and only for clicks you make. A page script can't press a button for you.

### Files and backup

Everything is in `~/.shepherdr/compass`:

| File | Whose | What |
| --- | --- | --- |
| `prompt.md` | yours | What Compass does. Starts as the starter prompt; Shepherdr never overwrites it. |
| `compass.json` | yours | The schedule, the agent, the strip's hours and the backup remote. Settings and the agent both change it. |
| `AGENTS.md`, `CLAUDE.md` | Shepherdr's | The agent's contract: runs, files, the template and the buttons. Rewritten with each version. |
| `template.html` | Shepherdr's | The page template. Once you change it, it's yours: **Settings → Compass** can bring Shepherdr's back. |
| `days/YYYY-MM-DD.html` | the agent's | One page per day, kept for good. |
| `days/YYYY-MM-DD/` | Shepherdr's | A copy of the page after each run, kept for 14 days. |
| `days/YYYY-MM-DD.marks.json` | Shepherdr's | What you marked done and the sessions you started from the page. |
| `context/` | Shepherdr's | The run's details and your queue, for the agent. |
| `state.json` | Shepherdr's | Shepherdr's notes about runs. |

The folder is a Git repository: Shepherdr commits it after each run and when the page changes. Set a remote in **Settings → Compass → Backup**, ideally a private repository, and Shepherdr pushes after each commit; it warns you if a GitHub remote is public. Git runs without asking anything, so keep your SSH key in your agent or use a credential helper for HTTPS. `state.json`, `context/` and the copies per run stay on this Mac.

A session you start from the page gets its first prompt once its agent is ready. Until then, the prompt waits in `~/.shepherdr/inbox/compass`; Shepherdr deletes it once delivered, or when you discard it from the session's mail panel.

`context/sessions.json` holds what your queue shows: names, states, agents, titles, folders, groups, holds, and the pull requests, issues and links each session collected, with their checks. Never what a terminal printed: the agent reads that itself with `herdr agent read` when it needs to. Shepherdr rewrites it at most every 30 seconds while Compass is set up.

Claude Code reads its permissions for Compass from `.claude/settings.json` in the folder: it may read and edit the folder and run read-only commands, such as `herdr agent read` and `shepherdr status`, without asking. Starting sessions, handing work to them and prompting them always asks first, since the agent reads content others wrote. Runs are unattended, so the contract tells the agent to put those actions on the page as buttons instead.
