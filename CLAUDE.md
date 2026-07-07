# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ClaudeStatus` is a single-target Swift Package macOS menubar app (`Package.swift`, `Sources/ClaudeStatus/`). It shows a count of currently running Claude Code sessions in the menubar — **orange** while any session is busy, **red** when one or more are waiting on user input, muted secondary when everything is idle (or nothing runs). Clicking it opens a borderless overlay panel listing each session (project, branch, path, state + how long it's held, uptime). Everything is local inspection: no network, no keychain, no credentials.

The build scripts, panel machinery, and visual style are lifted wholesale from `~/Documents/code/claude-usage` (ClaudeUsage) — same borderless `NSPanel` + `NSVisualEffectView` chrome, same animations, same footer idiom. The overlay is **392 pt wide** (vs ClaudeUsage's 280); height follows the SwiftUI content. When restyling, keep the two apps visually in sync.

## Common commands

```bash
./build-app.sh                    # swift build -c release + assemble + codesign → ./ClaudeStatus.app
./install.sh                      # build (unless SKIP_BUILD=1), replace /Applications/ClaudeStatus.app, restart
swift run ClaudeStatus --self-test  # run the hand-rolled test suite (exit 0/1)
swift run ClaudeStatus --scan       # headless: print detected sessions and exit — debug the heuristics
swift run                          # dev loop (menubar app, unsigned)
```

## Architecture

`App.swift` → `AppDelegate.swift` → `SessionStore` (single source of truth) drives an `NSStatusItem` and a borderless `PopoverPanel` hosting `SessionsView` (SwiftUI). `SessionStore` polls every 2 s (cheap — all local); `objectWillChange` is observed by `AppDelegate` to repaint the menubar count (hop one runloop tick because `objectWillChange` fires *before* the `@Published` write).

Detection path — `SessionScanner.swift`, all pure/blocking, called off-main via `Task.detached`:

1. **Live-session registry (the source of truth)** — Claude Code maintains one JSON status file per running process at `~/.claude/sessions/<pid>.json` with `pid`, `sessionId`, `cwd`, `name` (e.g. "claude-status-b3"), `startedAt`/`statusUpdatedAt` (epoch **ms**), and an authoritative `status`. The CLI's status enum (extracted from the 2.1.202 binary) is `["busy","shell","idle","waiting"]`, plus a `waitingFor` detail string. Mapping: busy→orange work, shell→user running a `!` command, idle→at the prompt (NOT an alarm state), waiting→red. Unknown/missing statuses read as idle — never a false red. Files whose pid is dead (`kill(pid, 0)`) are crash leftovers, skipped. The rust app at `~/Documents/code/system-stats` (`src/claude.rs`) reads the same registry and was the reference for this.
2. **Transcript garnish** — the transcript at `~/.claude/projects/<dashed-cwd>/<sessionId>.jsonl` (cwd flattens: every non-alphanumeric/`-` char becomes `-`) is tail-read only for `gitBranch` and mtime. State never comes from transcripts: a first cut inferred it from the last JSONL entry and couldn't distinguish "idle at prompt" from "waiting on permission" — don't regress to that.

`SingleInstance.swift` (flock on `~/Library/Application Support/ClaudeStatus/instance.lock`) guards against duplicate menubar items, same rationale as ClaudeUsage. `--self-test` and `--scan` dispatch at the top of `App.main`, before NSApplication or the lock.

## Testing — hand-rolled, on purpose

**This machine has no XCTest or swift-testing** (Command Line Tools toolchain only, no Xcode), and the owner prefers no test-framework dependency. Tests live in `SelfTest.swift` — a tiny assertion runner baked into the binary, run via `swift run ClaudeStatus --self-test`. Do **not** add a `testTarget`, `import XCTest`, or `import Testing`; add cases to `SelfTest.run()` instead. It covers the pure logic (registry parsing, status mapping, dir-name flattening, tail parsing, menubar label, formatting); GUI and filesystem paths are exercised via `--scan` and running the app.

## Things to know before editing

- `LSUIElement=true` in `Info.plist` (built inline in `build-app.sh`) plus `setActivationPolicy(.accessory)` keep the app out of the Dock. Don't remove either.
- Signing is best-effort: `SIGN_IDENTITY` from `.env` if the cert exists, else ad-hoc. Unlike ClaudeUsage there are no keychain ACLs at stake, so ad-hoc is fine here.
- The overlay's row order is stable (cwd, then pid) so rows don't jump between 2 s polls — state is conveyed by color, not position. Keep it stable.
- Transcript tail reads are capped at 64 KB and tolerate a truncated first line; entries are one JSON object per line.
