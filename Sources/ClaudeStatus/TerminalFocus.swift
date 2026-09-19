import AppKit
import Darwin
import Foundation

/// Brings the terminal hosting a Claude session to the front when its row
/// is clicked. Two tiers:
///
/// 1. **Emulator adapters** — Ghostty (1.3+), Terminal.app, iTerm2 — select
///    the exact tab/split through their AppleScript dictionaries. Ghostty
///    exposes no pid/tty, so its terminals are matched on working directory
///    plus the tab title Claude Code sets (the transcript's `ai-title`
///    entry). Terminal.app and iTerm2 expose a `tty`, matched against the
///    session pid's controlling terminal.
/// 2. **Generic fallback** — the nearest ancestor of the session pid that is
///    a bundled app is activated (VS Code, Kitty, WezTerm, anything). Right
///    app, whatever tab it was on.
///
/// Apple events need `NSAppleEventsUsageDescription` in Info.plist and a
/// one-time Automation grant per target app (TCC). A denied, failing, or
/// non-matching adapter falls through to the generic tier, never to nothing.
///
/// Everything here blocks (sysctl, Apple events) — call off the main thread.
enum TerminalFocus {

    enum Adapter: Equatable {
        case ghostty
        case terminalApp
        case iterm
        case generic
    }

    static func adapter(forBundleId id: String?) -> Adapter {
        switch id {
        case "com.mitchellh.ghostty": return .ghostty
        case "com.apple.Terminal": return .terminalApp
        case "com.googlecode.iterm2": return .iterm
        default: return .generic
        }
    }

    enum Outcome: Equatable {
        case focusedTerminal(Adapter)
        case activatedApp(String)
        case noHostApp
    }

    // MARK: Entry point

    static func focus(_ session: ClaudeSession) -> Outcome {
        guard let app = hostApp(of: session.pid) else { return .noHostApp }
        let adapter = adapter(forBundleId: app.bundleIdentifier)
        if focusExactTerminal(session, adapter: adapter) {
            return .focusedTerminal(adapter)
        }
        activate(app)
        return .activatedApp(app.bundleIdentifier ?? "?")
    }

    private static func focusExactTerminal(_ session: ClaudeSession, adapter: Adapter) -> Bool {
        switch adapter {
        case .ghostty:
            guard let terminals = ghosttyTerminals(),
                  let pick = pickGhosttyTerminal(terminals, cwd: session.cwd, title: session.title)
            else { return false }
            return runScript(ghosttyFocusScript(terminalId: pick.id)) == "ok"
        case .terminalApp:
            guard let tty = ttyPath(of: session.pid) else { return false }
            return runScript(terminalAppScript(tty: tty)) == "ok"
        case .iterm:
            guard let tty = ttyPath(of: session.pid) else { return false }
            return runScript(itermScript(tty: tty)) == "ok"
        case .generic:
            return false
        }
    }

    /// `activate()` is the cooperative macOS 14 API and can be refused when
    /// we aren't the active app (the overlay is a non-activating panel, so
    /// we usually aren't). Opening the running app's bundle URL is the
    /// `open -a` path and is honored regardless.
    private static func activate(_ app: NSRunningApplication) {
        if app.activate() { return }
        guard let url = app.bundleURL else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    // MARK: Ghostty

    struct GhosttyTerminal: Equatable {
        var id: String
        var name: String
        var cwd: String
    }

    /// One round-trip for the whole surface list; the pick happens here so
    /// it's testable and the matching rules live in one place.
    static let ghosttyListScript = """
    tell application id "com.mitchellh.ghostty"
      return {id of every terminal, name of every terminal, working directory of every terminal}
    end tell
    """

    static func ghosttyTerminals() -> [GhosttyTerminal]? {
        runScriptDescriptor(ghosttyListScript).flatMap(parseGhosttyList)
    }

    /// The script returns three parallel lists (ids, names, cwds). A missing
    /// title or cwd comes back as `missing value`, read here as "".
    static func parseGhosttyList(_ desc: NSAppleEventDescriptor) -> [GhosttyTerminal]? {
        guard desc.numberOfItems == 3,
              let ids = desc.atIndex(1), let names = desc.atIndex(2), let cwds = desc.atIndex(3),
              ids.numberOfItems == names.numberOfItems, ids.numberOfItems == cwds.numberOfItems
        else { return nil }
        var out: [GhosttyTerminal] = []
        var i = 1
        while i <= ids.numberOfItems {
            if let id = ids.atIndex(i)?.stringValue, !id.isEmpty {
                out.append(GhosttyTerminal(
                    id: id,
                    name: names.atIndex(i)?.stringValue ?? "",
                    cwd: cwds.atIndex(i)?.stringValue ?? ""))
            }
            i += 1
        }
        return out
    }

    /// Match order: cwd + title (exact), then title alone (the shell moved,
    /// or Ghostty reports a differently-resolved path), then cwd alone (no
    /// title yet — first turn — or a title collision; first in Ghostty's
    /// order wins). nil when nothing matches so the caller falls back to
    /// activating the app rather than guessing a surface.
    static func pickGhosttyTerminal(_ terminals: [GhosttyTerminal], cwd: String, title: String?) -> GhosttyTerminal? {
        let wantTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        func titleHit(_ t: GhosttyTerminal) -> Bool { wantTitle.map { t.name.hasSuffix($0) } ?? false }
        func cwdHit(_ t: GhosttyTerminal) -> Bool { samePath(t.cwd, cwd) }
        return terminals.first { titleHit($0) && cwdHit($0) }
            ?? terminals.first { titleHit($0) }
            ?? terminals.first { cwdHit($0) }
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        trimSlashes(a) == trimSlashes(b)
    }

    private static func trimSlashes(_ path: String) -> String {
        var s = Substring(path)
        while s.count > 1 && s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    static func ghosttyFocusScript(terminalId: String) -> String {
        """
        tell application id "com.mitchellh.ghostty"
          focus terminal id "\(appleScriptLiteral(terminalId))"
          activate
          return "ok"
        end tell
        """
    }

    // MARK: Terminal.app / iTerm2 (tty match)

    static func terminalAppScript(tty: String) -> String {
        """
        tell application id "com.apple.Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(appleScriptLiteral(tty))" then
                set selected tab of w to t
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
          return "none"
        end tell
        """
    }

    static func itermScript(tty: String) -> String {
        """
        tell application id "com.googlecode.iterm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(appleScriptLiteral(tty))" then
                  select s
                  select t
                  select w
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
          return "none"
        end tell
        """
    }

    /// Escape for interpolation inside an AppleScript double-quoted string.
    static func appleScriptLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: AppleScript execution

    static func runScript(_ source: String) -> String? {
        runScriptDescriptor(source)?.stringValue
    }

    static func runScriptDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            NSLog("ClaudeStatus: AppleScript failed: %@", error)
            return nil
        }
        return result
    }

    // MARK: Process tree (sysctl)

    private static func processInfo(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func parentPid(of pid: pid_t) -> pid_t? {
        processInfo(pid)?.kp_eproc.e_ppid
    }

    /// "/dev/ttys004" for the pid's controlling terminal, nil when it has none.
    static func ttyPath(of pid: pid_t) -> String? {
        guard let info = processInfo(pid) else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    /// Walk up from the session pid (claude → zsh → login → Ghostty, say) to
    /// the first ancestor LaunchServices knows as an app. Shell and login
    /// processes have no NSRunningApplication; helper processes of the
    /// terminal generally don't either, so this lands on the main app.
    static func hostApp(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<16 {
            guard let parent = parentPid(of: current), parent > 1 else { return nil }
            if parent != getpid(),
               let app = NSRunningApplication(processIdentifier: parent),
               app.bundleIdentifier != nil {
                return app
            }
            current = parent
        }
        return nil
    }
}
