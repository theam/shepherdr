---
name: shepherdr
description: "Start agent sessions on this machine or on other machines in the user's Shepherdr network, wait for them, hand results back to the session coordinating you, close sessions, and pin links or notify the user in Shepherdr. Use when the user asks to create, start or launch a session or agent on a machine or server by name, to hand off or report back to a coordinating session, to wait for another session, or to close a session, this one included. Requires HERDR_ENV=1."
---

# Shepherdr

Shepherdr is the user's Mac app for the Herdr sessions on all their machines. Its command line, `~/.shepherdr/bin/shepherdr`, starts sessions that Shepherdr links to yours, and sends work back to the session that coordinates you.

It never connects to the user's Mac. It writes letters in `~/.shepherdr/outbox` on this machine, and Shepherdr collects them within seconds while it is open. If Shepherdr is closed, they wait there.

Check that you run inside Herdr first:

```bash
test "${HERDR_ENV:-}" = 1
```

Outside Herdr, Shepherdr can't tell which session you are. Only `handoff --to`, `notify` and `spawn` without links work there.

## Machines

Before you use a machine name, run:

```bash
~/.shepherdr/bin/shepherdr machines
```

It says which machine you are on and how each of the others is reached. Never guess names.

- Route `here` or `direct`: `spawn` starts the session right away.
- Route `shepherdr`: this machine can't reach it. `spawn` files a request that the user approves in Shepherdr. Tell the user it is waiting for their approval.

## Start a session

```bash
~/.shepherdr/bin/shepherdr spawn --machine buildbox --cwd ~/src/api --name api-fix \
  --prompt "Fix the failing API test. When you finish, hand the result back with ~/.shepherdr/bin/shepherdr handoff."
```

- Leave out `--machine` for this machine. `--split right` or `--split down` opens it beside your pane instead of in a new workspace (this machine only).
- `--cwd` defaults to your folder here, and to the home folder elsewhere. `shepherdr folders --machine NAME` lists the folders where sessions already work.
- `--kind claude|codex|…` defaults to your own agent. `--shell` starts a plain shell, only when the user asks for one: run builds, tests and scripts yourself, with your own tools, so their output comes back to you and no session is left behind.
- `--name` is the new agent's Herdr name: a lowercase letter, then lowercase letters, digits, `-` or `_`. It is made up from the folder if you leave it out.
- Shepherdr nests the new session under yours and keeps yours on hold until it finishes. Add `--no-wait` when you don't need its result.
- In the prompt, ask it to hand its result back with `~/.shepherdr/bin/shepherdr handoff` when it finishes.
- If the agent stops at a startup question, such as trusting the folder, Shepherdr sends your prompt once the user answers it.

To follow it from here, use Herdr with the agent name: `herdr agent read NAME`, or `herdr --machine PROFILE agent read NAME` on another machine. `spawn` prints which.

## Hand work back

When you finish work that another session asked for, hand the result back:

```bash
~/.shepherdr/bin/shepherdr handoff --file REPORT.md "Opened theam/api#41. The flaky test was a race in the cache; tests pass."
```

- It goes to the session waiting for you. `--to NAME` picks another session by its agent or workspace name; add `@machine` when two machines have one with that name.
- Shepherdr delivers it as a prompt once that session is free. When it comes from another machine, the user may approve it first.
- Write the message so it stands alone: what you did, the results, links, and what is left.
- `--file` attaches files, up to 5 MB in all. `--message-file FILE` takes the message from a file, and `-` from standard input.

## Wait and resume

```bash
~/.shepherdr/bin/shepherdr wait-for reviewer tester
~/.shepherdr/bin/shepherdr resume
```

`wait-for` puts your session on hold until those sessions finish. `resume` takes it off hold, or stops waiting for the sessions you name.

## Close sessions

Close a session only when the user asks you to. Closing ends its Herdr pane and the agent in it, and nothing in it can be recovered.

```bash
~/.shepherdr/bin/shepherdr close
~/.shepherdr/bin/shepherdr close reviewer tester@buildbox
```

- With no name, it closes your own session once you finish this turn. Keep your last message short: the session closes right after it, and the user may not get to read it.
- With names, it closes those sessions, by agent or workspace name like `handoff --to`. A session that is working or waiting for the user stays open, and Shepherdr shows you why; add `--force` only when the user asked to close it anyway.
- Closing a session on another machine may wait for the user's approval in Shepherdr.
- If you finish work another session waits for, hand it back with `handoff` before you close.

## Links and notices

```bash
~/.shepherdr/bin/shepherdr pin https://github.com/theam/api/pull/41 --title "Cache race fix"
~/.shepherdr/bin/shepherdr open http://localhost:3000
~/.shepherdr/bin/shepherdr notify "Migration finished: 1,204 rows moved."
```

- `pin` adds a link to your session's resources in Shepherdr.
- `open` opens a page in your session's browser in Shepherdr. From another machine, it only suggests the page to the user.
- `notify` shows the user a notification.

Only http and https links are accepted.

## When something fails

- `shepherdr status` shows this machine, your pane and the letters Shepherdr hasn't collected yet.
- A machine name that isn't in the list fails with the names that are. Pick one or ask the user.
- `shepherdr help` lists every option.
