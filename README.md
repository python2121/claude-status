# Claude Status

A macOS menu bar app that shows the status of your running [Claude Code](https://claude.com/claude-code) sessions at a glance.

The menu bar shows a count of live sessions:

- **Orange** — one or more sessions are busy (Claude is working)
- **Red** — one or more sessions are **waiting on your input** (permission prompt, etc.)
- **Muted** — everything is idle (or nothing is running)

By default the count draws as a solid color pill for legibility ("inverted" style); a toggle in the overlay's `⋯` menu switches to plain colored text.

Clicking the count opens an overlay listing each session: project, git branch, path, current state (Working / Shell command / Idle / Waiting for input — including *what* it's waiting for when known), how long the state has held, and session uptime. Rows update every 2 seconds.

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
