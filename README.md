<div align="center">

<img src="docs/assets/header.png" alt="Shepherdr: a pixel-art German Shepherd keeping watch over a flock of Matrix sheep" width="720">

**A native macOS console for herding your coding agents.**

Claude Code, Codex, Gemini, opencode… on every [Herdr](https://herdr.dev/) machine you run, in one prioritized queue.

[Download](../../releases/latest) · [Guide](docs/GUIDE.md) · [Hacking](docs/DEVELOPMENT.md) · [MIT License](LICENSE)

<img src="docs/assets/screenshot.png" alt="Shepherdr's queue of nine agent sessions working on humanity's biggest problems, with a live terminal curing cancer" width="900">

</div>

---

## What's Herdr?

[Herdr](https://herdr.dev) ([source](https://github.com/herdrdev/herdr)) is "the runtime your coding agents live on". It is a single Rust binary that owns the terminals your agents run in: Claude Code, Codex, opencode, Gemini and friends keep working in a background server when you close the client or lose your SSH connection. Every pane is marked working, blocked or idle, local and SSH machines share one agent list, and agents can drive Herdr themselves through its CLI and socket API. Its own client is a keyboard-and-mouse TUI that runs in any terminal.

Shepherdr is another window onto those same sessions: a native macOS app that drives the `herdr` CLI. It doesn't wrap, replace or bundle Herdr.

## Why another Herdr client?

I love Herdr. It's rock solid, and it lets me work across several machines at once. Soon I had a few dozen agents on the go, each with its own trail of browser tabs: pull requests, Claude artifacts and whatever else came up along the way. That's a lot of sheep to herd.

I wanted a native macOS tool built for exactly that: see at a glance which agent needs me and which sessions are waiting for which, and keep the important work at the top, so every minute goes where it matters most. I looked at several apps, and some are very cool (a few are [below](#other-similar-projects-worth-exploring)), but I wanted one shaped around the way I work.

So I spawned this one with Claude. We live in the agentic era: when the tool you want doesn't exist exactly the way you'd like it, you describe it, argue with a couple of agents for a few evenings, and **spawn it into existence**. Shepherdr has been my main tool for working with agents ever since, and it gains features as I find I need them. It's an agent console, built mostly by agents, with a human holding the crook.

There's no roadmap, on purpose. This world moves incredibly fast, and adapting day by day is half the fun. The way I work changes every week, and Shepherdr changes right along with it.

If it fits the way you work, take it. If it doesn't, fork it and make it yours, or spawn your own. That's the whole point.

## What it does

- **One queue for every agent.** Sessions from all your machines, local and SSH, in your own priority order. Drag to reorder, jump with **⌘1…⌘9**, and gather them into groups that you prioritize as one.
- **The real terminal, embedded.** Pick a session and type straight into its agent's TUI (⇧⏎ for a new line), or drop files and images on it for the agent to pick up, even on remote machines. Open the prompt editor when a prompt deserves more thought, or dictate it and edit the transcript.
- **A browser per session.** Click a link and it opens next to the terminal, in tabs that stay put while you hop between sessions and come back after a restart. Paths to local files open too: Markdown rendered, HTML as a page.
- **Resources at hand.** The pull requests, issues and Claude artifacts each session links to gather in a side panel, one click away.
- **See where the work is.** The overview counts sessions by state and machine, shows how busy each machine's processor, memory and disk are, and lists the sessions in any mix of states and machines you click.
- **Know when it's your turn.** A notification tells you when an agent finishes or needs you, with what it last said.
- **Sessions on hold.** Mark a planner as waiting for its subagents; they nest under it in a collapsible tree, and its hourglass turns green when they're done.
- **Drive or just watch.** Sessions open unlocked; one click on the padlock makes them read-only. Shepherdr never steals input from another client: taking over is always your explicit call.
- **Spawn and dismiss sessions.** **⌘N**: pick a folder and get a shell; start any agent in it and the queue picks it up.
- **Phosphor green, 8-bit soul.** Bundled Fira Code, a pixel-art flock, and a German Shepherd keeping watch.

No accounts, no telemetry, no server. Shepherdr drives the `herdr` CLI you already have (plus `ssh` for remote terminals, dropped files and machine load). Prompts, terminal output and your voice never touch the disk: Shepherdr only remembers your queue and, per session, its browser tabs and collected links. Dictation runs entirely on your Mac.

## Get it

1. Install and start [Herdr](https://herdr.dev/docs/), which Shepherdr needs (CLI 0.9.3 or later for remote machines and terminals).
2. Recommended: install the [GitHub CLI](https://cli.github.com) and sign in with `gh auth login`. Shepherdr uses it to confirm pull requests and issues, private ones included, fetch their titles, and watch pull requests' CI checks; without it, those features are limited or off.
3. Grab the `.dmg` from the [latest release](../../releases/latest) and drag **Shepherdr.app** to Applications. You need an Apple Silicon Mac with macOS 14 or later. It's signed and notarized by Apple, so it opens like any other download.

Prefer to build it yourself? `open Shepherdr.xcodeproj` and hit **⌘R**. More in [DEVELOPMENT](docs/DEVELOPMENT.md).

## Other similar projects worth exploring

Shepherdr is one take among several. Warp and Superset are the ones I used the most before spawning it, and herdrm and herdr-GPUI are fellow Herdr clients. If Shepherdr isn't yours, these are worth a look:

- [Warp](https://www.warp.dev): the agentic development environment, a modern terminal built for coding with agents, whether Warp's own or Claude Code and Codex.
- [Superset](https://superset.sh) ([source](https://github.com/superset-sh/superset)): an agentic IDE that runs a fleet of CLI coding agents in parallel, each task in its own Git worktree.
- [herdrm](https://github.com/missuo/herdrm): a native macOS console for Herdr, with all your coding agents and their live terminals, across devices.
- [herdr-GPUI](https://github.com/penso/herdr-gpui): a native Herdr client for macOS, Linux and Windows, built with Rust and GPUI, covering terminal sessions, workspaces, Git worktrees and agent activity.

## The fine print

Shepherdr is a side project started by [Javier Toledo](https://github.com/javiertoledo) (CTO at [The Agile Monkeys](https://www.theagilemonkeys.com)) to scratch his own itch. The Agile Monkeys donates it under the [MIT License](LICENSE) to anyone who finds it useful.

There are no commercial plans and no promises of maintenance or support. That's what the MIT license is for. Issues and pull requests are welcome, and they'll get an answer whenever the shepherd is off duty.

Shepherdr is an independent project, not affiliated with Herdr. Built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT), [Fira Code](https://github.com/tonsky/FiraCode) (OFL) and [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) running NVIDIA's [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (CC BY 4.0).

<div align="center">

*Do androids dream of electric sheep? These ones get a dog.*

</div>
