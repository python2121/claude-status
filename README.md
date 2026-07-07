# Claude Status

A macOS menu bar app that shows the status of your running [Claude Code](https://claude.com/claude-code) sessions at a glance.

The menu bar shows a count of live sessions:

- **Green** — one or more sessions are busy (Claude is working)
- **Orange** — one or more sessions are **waiting on your input** (permission prompt, etc.)
- **Muted** — everything is idle (or nothing is running)

By default the count draws as colored text on the bare menu bar; the "Invert menu bar colors" toggle (in the overlay's `⋯` menu, or by right-clicking the menu bar number) switches to a solid color pill with contrasting text for extra legibility.

Clicking the count opens an overlay listing each session: project, git branch, path, current state (Working / Shell command / Idle / Waiting for input — including *what* it's waiting for when known), how long the state has held, and session uptime. Rows update every 2 seconds.

## Approving permissions from the app

When a session asks for permission (usually approving a command), the app can catch it before the terminal prompt renders: the affected row shows **Approve** / **Deny** buttons right where its status text normally sits, plus a `⋯` menu with **Approve all for 5 minutes** and **Approve all for this session** (per-session standing approvals, marked with a ⚡ on the row, never persisted across app restarts).

Enable it once:

```bash
/Applications/ClaudeStatus.app/Contents/MacOS/ClaudeStatus --install-hook    # registers a PermissionRequest hook in ~/.claude/settings.json
/Applications/ClaudeStatus.app/Contents/MacOS/ClaudeStatus --uninstall-hook  # removes it
```

The terminal prompt and the app's buttons are live at the same time, for as long as the prompt is unanswered — answer in whichever is closer. Answering in the terminal clears the app's buttons within a couple of seconds; answering in the app resolves the terminal prompt. If the app isn't running at all, requests flow to the terminal untouched. Explicit deny/ask rules in your Claude Code settings still override an app-side allow.

## How it works

Everything is local — no network, no keychain, no credentials:

1. **Live-session registry.** Claude Code maintains one status file per running process at `~/.claude/sessions/<pid>.json`, carrying the session's pid, cwd, derived name, and an authoritative `status` (`busy` / `shell` / `idle` / `waiting`, plus a `waitingFor` detail). That registry is the single source of truth for state; entries whose pid is dead are ignored.
2. **Transcripts** under `~/.claude/projects/` are tail-read only for the git branch.

## Install

```bash
./install.sh
```

Builds a release bundle, installs it to `/Applications/ClaudeStatus.app`, and launches it (via your LaunchAgent if you've set one up at `~/Library/LaunchAgents/com.andrewnowicki.claudestatus.plist`, otherwise directly).

Code signing is best-effort: set `SIGN_IDENTITY` in a `.env` file to sign with a stable self-signed cert (nicer Login Items label); otherwise the build falls back to ad-hoc signing, which is fine — this app holds no keychain items.

## Development

```bash
./build-app.sh                       # release build → ./ClaudeStatus.app
swift run                            # dev loop (menubar app, unsigned)
swift run ClaudeStatus --scan        # headless: print detected sessions and exit
swift run ClaudeStatus --self-test   # run the test suite
```

Tests are a hand-rolled assertion harness baked into the binary (`SelfTest.swift`) — no XCTest or swift-testing dependency, so everything builds with a Command Line Tools-only toolchain.

The build scripts and visual style are shared with [claude-usage](https://github.com/jakeonrails/claude-usage) — the two apps are meant to sit side by side in the menu bar.
