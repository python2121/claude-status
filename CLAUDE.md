# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ClaudeStatus` is a single-target Swift Package macOS menubar app (`Package.swift`, `Sources/ClaudeStatus/`). It shows one glyph in the menubar summarizing all running Claude Code sessions — a **green ◐◓◑◒-style spinner** (0.25 s/frame, timer runs only while busy) when any session is busy, an **orange ●** when one or more are waiting on user input, and **○** in the system label color when everything is idle (or nothing runs). The glyphs are **drawn with NSBezierPath, not font characters** — the system font lacks U+25D0–25D3, and fallback served the left/right halves and top/bottom halves from different fonts at visibly different sizes. Don't switch back to string glyphs. Clicking it opens a borderless overlay panel listing each session (project, branch, path, state + how long it's held, uptime). Everything is local inspection: no network, no keychain, no credentials.

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

1. **Live-session registry (the source of truth)** — Claude Code maintains one JSON status file per running process at `~/.claude/sessions/<pid>.json` with `pid`, `sessionId`, `cwd`, `name` (e.g. "claude-status-b3"), `startedAt`/`statusUpdatedAt` (epoch **ms**), and an authoritative `status`. The CLI's status enum (extracted from the 2.1.202 binary) is `["busy","shell","idle","waiting"]`, plus a `waitingFor` detail string. Mapping: busy→green work, shell→user running a `!` command, idle→at the prompt (NOT an alarm state), waiting→orange. Unknown/missing statuses read as idle — never a false alarm color. Files whose pid is dead (`kill(pid, 0)`) are crash leftovers, skipped. The rust app at `~/Documents/code/system-stats` (`src/claude.rs`) reads the same registry and was the reference for this.
2. **Transcript garnish** — the transcript at `~/.claude/projects/<dashed-cwd>/<sessionId>.jsonl` (cwd flattens: every non-alphanumeric/`-` char becomes `-`) is tail-read only for `gitBranch` and mtime. State never comes from transcripts: a first cut inferred it from the last JSONL entry and couldn't distinguish "idle at prompt" from "waiting on permission" — don't regress to that.

`SingleInstance.swift` (flock on `~/Library/Application Support/ClaudeStatus/instance.lock`) guards against duplicate menubar items, same rationale as ClaudeUsage. `--permission-hook`, `--install-hook`/`--uninstall-hook`, `--self-test`, and `--scan` dispatch at the top of `App.main`, before NSApplication or the lock.

## Remote approval (the PermissionRequest hook bridge)

When a session hits a permission prompt, the user can approve/deny it from the overlay instead of the terminal. Three pieces:

1. **Hook** — `install.sh` runs `--install-hook` automatically (`SKIP_HOOK=1` opts out), which registers a `PermissionRequest` hook in `~/.claude/settings.json` (command: the `/Applications` binary + `--permission-hook`, timeout 86 400 s — a leak backstop, not UX; see below). The merge (`HookInstaller`) is surgical and idempotent; it only ever touches the one entry containing the `--permission-hook` marker.
2. **Helper** (`PermissionHook.swift`) — spawned by Claude Code with the request JSON on stdin (`tool_name`, `tool_input`, `session_id`, `cwd`). It forwards one request line over the UDS socket at `~/Library/Application Support/ClaudeStatus/approvals.sock` and blocks **with no deadline** for a verdict — the terminal prompt is live concurrently, so blocking hides nothing, and the app hangs up (EOF) when the prompt resolves elsewhere. **The prime directive: emit a decision only on an explicit verdict.** App not running, hang-up, crash, malformed reply — all exit 0 with no output, which Claude Code treats as "no decision" and defers to the terminal prompt. Output schema (verified against the CLI's own zod validator): `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}`.
3. **Server** (`ApprovalCenter.swift`) — blocking POSIX UDS server inside the app; one connection = one pending approval. `SessionStore` publishes `pendingApprovals`, matches them to session rows by `sessionId`, and forces those rows' effective state to waiting. If a helper dies anyway, `onClosed` drops the buttons instantly so a stale click can't fire into nothing. Pendings with no matching live session (session exited, ids never lined up) are pruned after a 10 s grace period (`shouldPruneUnmatched`) — with no helper deadline, that prune is what prevents immortal requests.

**The terminal prompt and our buttons are live simultaneously** — the CLI renders its prompt while the PermissionRequest hook is still running, and whichever side answers first wins. That requires reconciliation for the terminal-wins case: while the prompt is up, the session's registry status reads `waiting`; answering it flips the status (usually to `busy`) with a fresh `statusUpdatedAt`. Each poll, `reconcilePendingWithRegistry()` drops any pending approval whose session left `waiting` with a status change newer than the approval's arrival, and closes its helper connection via `server.cancel(id)` — a verdict-less shutdown (distinct from `respond`) so we never answer a question the terminal already settled. The predicate (`resolvedInTerminal`) is deliberately conservative: the pre-prompt `busy` state has a *stale* `statusUpdatedAt`, so it can't false-trigger at arrival.

The overlay renders Approve / Deny / `⋯` **in place of the status text** on the affected row, with the command summary where the timing caption goes. The `⋯` menu holds "Approve all for 5 minutes" and "Approve all for this session" — per-session auto-approve rules held in memory only (deliberately not persisted; a standing approval shouldn't outlive the app that granted it), pruned when they expire or the session ends, and marked with a yellow bolt on the row.

## Testing — hand-rolled, on purpose

**This machine has no XCTest or swift-testing** (Command Line Tools toolchain only, no Xcode), and the owner prefers no test-framework dependency. Tests live in `SelfTest.swift` — a tiny assertion runner baked into the binary, run via `swift run ClaudeStatus --self-test`. Do **not** add a `testTarget`, `import XCTest`, or `import Testing`; add cases to `SelfTest.run()` instead. It covers the pure logic (registry parsing, status mapping, dir-name flattening, tail parsing, menubar label, formatting); GUI and filesystem paths are exercised via `--scan` and running the app.

## Things to know before editing

- `LSUIElement=true` in `Info.plist` (built inline in `build-app.sh`) plus `setActivationPolicy(.accessory)` keep the app out of the Dock. Don't remove either.
- Signing is best-effort: `SIGN_IDENTITY` from `.env` if the cert exists, else ad-hoc. Unlike ClaudeUsage there are no keychain ACLs at stake, so ad-hoc is fine here.
- The overlay's row order is stable (cwd, then pid) so rows don't jump between 2 s polls — state is conveyed by color, not position. Keep it stable.
- Transcript tail reads are capped at 64 KB and tolerate a truncated first line; entries are one JSON object per line.
