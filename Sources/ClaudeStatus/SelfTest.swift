import AppKit
import Foundation

/// Hand-rolled test harness — this machine has no XCTest/swift-testing (CLT
/// toolchain only), and we don't want the dependency anyway. Dispatched from
/// App.main via `ClaudeStatus --self-test`, before NSApplication exists, so
/// it runs headless and exits with 0/1. Covers the pure logic: registry
/// parsing, status mapping, cwd→project-dir flattening, transcript tail
/// parsing, menubar label, and duration formatting.
enum SelfTest {
    struct Runner {
        var passed = 0
        var failures: [String] = []

        mutating func expectEqual<T: Equatable>(_ got: T, _ want: T, _ name: String) {
            if got == want {
                passed += 1
            } else {
                failures.append("\(name): got \(got), want \(want)")
            }
        }

        mutating func expectNil<T>(_ got: T?, _ name: String) {
            if got == nil {
                passed += 1
            } else {
                failures.append("\(name): got \(String(describing: got)), want nil")
            }
        }

        func finish() -> Never {
            for f in failures { print("FAIL  \(f)") }
            print("\(passed) passed, \(failures.count) failed")
            exit(failures.isEmpty ? 0 : 1)
        }
    }

    static func run() -> Never {
        var t = Runner()

        // MARK: registry parsing

        let registryJSON = """
        {"pid":43606,"sessionId":"93fb531a-9e91-4926-ab89-93ded70cba7e",\
        "cwd":"/Users/andrewnowicki/Documents/code/claude-status",\
        "startedAt":1783455271121,"version":"2.1.202","kind":"interactive",\
        "name":"claude-status-b3","status":"busy",\
        "updatedAt":1783457374373,"statusUpdatedAt":1783457374373}
        """
        let entry = SessionScanner.parseRegistryEntry(Data(registryJSON.utf8))
        t.expectEqual(entry?.pid, 43606, "registry: pid")
        t.expectEqual(entry?.cwd, "/Users/andrewnowicki/Documents/code/claude-status", "registry: cwd")
        t.expectEqual(entry?.sessionId, "93fb531a-9e91-4926-ab89-93ded70cba7e", "registry: sessionId")
        t.expectEqual(entry?.name, "claude-status-b3", "registry: name")
        t.expectEqual(entry?.status, "busy", "registry: status")
        t.expectEqual(entry?.startedAt, Date(timeIntervalSince1970: 1783455271.121), "registry: startedAt epoch-ms")
        t.expectEqual(entry?.statusUpdatedAt, Date(timeIntervalSince1970: 1783457374.373), "registry: statusUpdatedAt")
        t.expectNil(entry?.waitingFor, "registry: waitingFor absent")

        let withWaiting = SessionScanner.parseRegistryEntry(
            Data(#"{"pid":1,"status":"waiting","waitingFor":"permission"}"#.utf8))
        t.expectEqual(withWaiting?.waitingFor, "permission", "registry: waitingFor present")

        t.expectNil(SessionScanner.parseRegistryEntry(Data(#"{"nopid":true}"#.utf8)), "registry: missing pid → nil")
        t.expectNil(SessionScanner.parseRegistryEntry(Data("garbage".utf8)), "registry: garbage → nil")

        // MARK: status mapping — the CLI's enum is ["busy","shell","idle","waiting"]

        t.expectEqual(SessionScanner.state(fromStatus: "busy"), .busy, "status busy → busy")
        t.expectEqual(SessionScanner.state(fromStatus: "shell"), .shell, "status shell → shell")
        t.expectEqual(SessionScanner.state(fromStatus: "idle"), .idle, "status idle → idle")
        t.expectEqual(SessionScanner.state(fromStatus: "waiting"), .waitingForInput, "status waiting → waiting")
        t.expectEqual(SessionScanner.state(fromStatus: "someday-new"), .idle, "unknown status → idle, never a false alarm color")
        t.expectEqual(SessionScanner.state(fromStatus: nil), .idle, "missing status → idle")

        // MARK: projectDirName

        t.expectEqual(
            SessionScanner.projectDirName(forCwd: "/Users/andrewnowicki/Documents/code/claude-status"),
            "-Users-andrewnowicki-Documents-code-claude-status",
            "projectDirName flattens slashes"
        )
        t.expectEqual(
            SessionScanner.projectDirName(forCwd: "/Users/a_b/foo.bar"),
            "-Users-a-b-foo-bar",
            "projectDirName flattens underscores and dots"
        )

        // MARK: parseTail

        let twoLines = """
        {"type":"user","sessionId":"abc-123","gitBranch":"main","message":{"role":"user"}}
        {"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn"}}
        """
        let parsed = SessionScanner.parseTail(twoLines)
        t.expectEqual(parsed?.sessionId, "abc-123", "parseTail finds newest entry with sessionId")
        t.expectEqual(parsed?.gitBranch, "main", "parseTail reads gitBranch")

        let truncated = """
        ...half a json object"}
        {"type":"assistant","sessionId":"s1","gitBranch":"feature/x","message":{}}
        """
        t.expectEqual(SessionScanner.parseTail(truncated)?.gitBranch, "feature/x",
                      "parseTail skips truncated first line")

        // The newest entries often carry a sessionId but no gitBranch
        // (progress records, tool results) — the branch must come from the
        // newest entry that HAS one, not vanish.
        let branchlessNewest = """
        {"type":"user","sessionId":"abc-123","gitBranch":"feature/y","message":{}}
        {"type":"progress","sessionId":"abc-123"}
        {"type":"assistant","sessionId":"abc-123","message":{"stop_reason":"tool_use"}}
        """
        let tail2 = SessionScanner.parseTail(branchlessNewest)
        t.expectEqual(tail2?.sessionId, "abc-123", "parseTail: sessionId from newest entry")
        t.expectEqual(tail2?.gitBranch, "feature/y", "parseTail: branch survives branch-less newer entries")

        t.expectEqual(SessionScanner.parseTail(#"{"sessionId":"s","gitBranch":""}"#)?.gitBranch, nil,
                      "parseTail: empty-string branch ignored")

        t.expectNil(SessionScanner.parseTail(""), "parseTail empty → nil")
        t.expectNil(SessionScanner.parseTail("not json at all"), "parseTail garbage → nil")

        // MARK: pid liveness

        t.expectEqual(SessionScanner.pidAlive(getpid()), true, "own pid is alive")

        // MARK: menubar symbol

        t.expectEqual(SessionStore.trayState(busy: 0, waiting: 0), .idle, "tray: nothing running → idle")
        t.expectEqual(SessionStore.trayState(busy: 2, waiting: 0), .busy, "tray: busy sessions → busy")
        t.expectEqual(SessionStore.trayState(busy: 2, waiting: 1), .waiting, "tray: any waiting beats busy")

        t.expectEqual(SessionStore.trayColor(.idle), .labelColor, "tray color: idle → system label color")
        t.expectEqual(SessionStore.trayColor(.busy), .systemGreen, "tray color: busy → green")
        t.expectEqual(SessionStore.trayColor(.waiting), .systemOrange, "tray color: waiting → orange")

        // MARK: approval wire format

        let hookInput = #"{"session_id":"s-1","cwd":"/tmp/proj","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf build\necho done","description":"clean"}}"#
        if let line = ApprovalWire.requestLine(fromHookInput: Data(hookInput.utf8)) {
            t.expectEqual(line.last, 0x0A, "wire: request line newline-terminated")
            let req = ApprovalWire.parseRequest(line.dropLast())
            t.expectEqual(req?.sessionId, "s-1", "wire: sessionId round-trips")
            t.expectEqual(req?.cwd, "/tmp/proj", "wire: cwd round-trips")
            t.expectEqual(req?.toolName, "Bash", "wire: toolName round-trips")
            t.expectEqual(req?.summary, "Bash: rm -rf build echo done", "wire: row summary collapses newlines")
            t.expectEqual(req?.detail, "Bash: rm -rf build\necho done", "wire: hover detail keeps newlines")
        } else {
            t.expectEqual(false, true, "wire: requestLine produced nil")
        }
        t.expectNil(ApprovalWire.requestLine(fromHookInput: Data("nope".utf8)), "wire: garbage stdin → nil")

        t.expectEqual(ApprovalWire.summary(tool: "Edit", input: ["file_path": "/a/b.swift"]),
                      "Edit: /a/b.swift", "wire: Edit summary uses file_path")
        t.expectEqual(ApprovalWire.summary(tool: "Mystery", input: nil), "Mystery", "wire: no input → bare tool name")
        t.expectEqual(ApprovalWire.summary(tool: "Bash", input: ["command": String(repeating: "x", count: 300)]).count <= 206,
                      true, "wire: summary clipped")
        t.expectEqual(ApprovalWire.summary(tool: "Bash", input: ["command": String(repeating: "y", count: 5000)], maxChars: 4000, collapseNewlines: false).count <= 4006,
                      true, "wire: detail clipped at its own cap")

        t.expectEqual(ApprovalWire.parseResponse(ApprovalWire.responseLine(allow: true).dropLast()), true, "wire: allow round-trips")
        t.expectEqual(ApprovalWire.parseResponse(ApprovalWire.responseLine(allow: false).dropLast()), false, "wire: deny round-trips")
        t.expectNil(ApprovalWire.parseResponse(Data("{}".utf8)), "wire: missing behavior → nil")

        t.expectEqual(
            ApprovalWire.decisionJSON(allow: true),
            #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}"#,
            "wire: allow decision JSON matches CLI schema")
        t.expectEqual(
            ApprovalWire.decisionJSON(allow: false).contains(#""behavior":"deny""#), true,
            "wire: deny decision JSON has deny behavior")

        // MARK: auto-approve rules

        let now2 = Date(timeIntervalSince1970: 2_000_000)
        t.expectEqual(SessionStore.ruleAllows(nil, now: now2), false, "rules: no rule → no auto-approve")
        t.expectEqual(SessionStore.ruleAllows(.forSession, now: now2), true, "rules: forSession always allows")
        t.expectEqual(SessionStore.ruleAllows(.until(now2.addingTimeInterval(60)), now: now2), true, "rules: unexpired timer allows")
        t.expectEqual(SessionStore.ruleAllows(.until(now2.addingTimeInterval(-1)), now: now2), false, "rules: expired timer denies")

        // MARK: terminal-answer reconciliation

        let recv = Date(timeIntervalSince1970: 3_000_000)
        t.expectEqual(SessionStore.resolvedInTerminal(state: .waitingForInput, stateSince: recv.addingTimeInterval(1), receivedAt: recv),
                      false, "reconcile: still waiting → keep buttons")
        t.expectEqual(SessionStore.resolvedInTerminal(state: .busy, stateSince: recv.addingTimeInterval(-60), receivedAt: recv),
                      false, "reconcile: pre-prompt busy (stale stateSince) → keep")
        t.expectEqual(SessionStore.resolvedInTerminal(state: .busy, stateSince: recv.addingTimeInterval(3), receivedAt: recv),
                      true, "reconcile: fresh busy → answered in terminal, drop")
        t.expectEqual(SessionStore.resolvedInTerminal(state: .idle, stateSince: recv.addingTimeInterval(3), receivedAt: recv),
                      true, "reconcile: fresh idle (denied, turn over) → drop")
        t.expectEqual(SessionStore.resolvedInTerminal(state: .busy, stateSince: nil, receivedAt: recv),
                      false, "reconcile: no stateSince → keep (never guess)")
        t.expectEqual(SessionStore.shouldPruneUnmatched(receivedAt: recv, now: recv.addingTimeInterval(5)),
                      false, "reconcile: unmatched within grace → keep")
        t.expectEqual(SessionStore.shouldPruneUnmatched(receivedAt: recv, now: recv.addingTimeInterval(11)),
                      true, "reconcile: unmatched past grace → prune")

        // MARK: hook installer merge (pure, no file IO)

        let (installed, changed1) = HookInstaller.merged([:])
        t.expectEqual(changed1, true, "installer: fresh settings gains hook")
        let matchers = (installed["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        let cmd = (matchers?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        t.expectEqual(cmd, HookInstaller.hookCommand, "installer: command written")
        let (_, changed2) = HookInstaller.merged(installed)
        t.expectEqual(changed2, false, "installer: idempotent")
        let (removedRoot, changed3) = HookInstaller.removed(installed)
        t.expectEqual(changed3, true, "installer: removal reports change")
        t.expectNil(removedRoot["hooks"], "installer: emptied containers pruned")
        let preserved = HookInstaller.merged(["model": "opus", "hooks": ["Stop": [["hooks": []]]]]).0
        t.expectEqual(preserved["model"] as? String, "opus", "installer: unrelated keys preserved")
        t.expectEqual(((preserved["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.isEmpty, false,
                      "installer: unrelated hooks preserved")

        // MARK: approval server ↔ helper socket round-trip

        let sockPath = NSTemporaryDirectory() + "claudestatus-test-\(getpid()).sock"
        let server = ApprovalServer(path: sockPath)
        let gotRequest = DispatchSemaphore(value: 0)
        var requestedId: UUID?
        var requestedSummary: String?
        server.onRequest = { id, info in
            requestedId = id
            requestedSummary = info.summary
            gotRequest.signal()
        }
        if server.start() {
            var verdict: Bool? = nil
            let clientDone = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                if let fd = ApprovalSocket.connect(path: sockPath) {
                    let line = Data(#"{"toolName":"Bash","toolInput":{"command":"ls"},"sessionId":"s-9"}"# .utf8) + Data([0x0A])
                    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                    var buf = [UInt8](repeating: 0, count: 4096)
                    let n = read(fd, &buf, buf.count)
                    if n > 0 { verdict = ApprovalWire.parseResponse(Data(buf[0..<n]).prefix(while: { $0 != 0x0A })) }
                    close(fd)
                }
                clientDone.signal()
            }
            t.expectEqual(gotRequest.wait(timeout: .now() + 5), .success, "server: request arrives")
            t.expectEqual(requestedSummary, "Bash: ls", "server: summary parsed")
            if let id = requestedId { server.respond(id, allow: true) }
            t.expectEqual(clientDone.wait(timeout: .now() + 5), .success, "server: client completes")
            t.expectEqual(verdict, true, "server: client received allow")
            server.stop()
        } else {
            t.expectEqual(false, true, "server: failed to start on \(sockPath)")
        }

        // MARK: terminal focus

        let titledTail = """
        {"type":"user","sessionId":"s1","gitBranch":"main","cwd":"/x"}
        {"type":"ai-title","aiTitle":"Old title","sessionId":"s1"}
        {"type":"ai-title","aiTitle":"Swift builds failing","sessionId":"s1"}
        {"type":"progress","sessionId":"s1"}
        """
        let titled = SessionScanner.parseTail(titledTail)
        t.expectEqual(titled?.aiTitle, "Swift builds failing", "tail: newest ai-title wins")
        t.expectEqual(titled?.gitBranch, "main", "tail: branch still found past ai-title entries")
        t.expectNil(SessionScanner.parseTail(#"{"type":"ai-title","aiTitle":"","sessionId":"s1"}"#)?.aiTitle, "tail: empty ai-title ignored")
        t.expectNil(SessionScanner.parseTail(#"{"type":"user","aiTitle":"not a title entry","sessionId":"s1"}"#)?.aiTitle, "tail: aiTitle only read off ai-title entries")

        t.expectEqual(TerminalFocus.adapter(forBundleId: "com.mitchellh.ghostty"), .ghostty, "focus: Ghostty adapter")
        t.expectEqual(TerminalFocus.adapter(forBundleId: "com.apple.Terminal"), .terminalApp, "focus: Terminal adapter")
        t.expectEqual(TerminalFocus.adapter(forBundleId: "com.googlecode.iterm2"), .iterm, "focus: iTerm adapter")
        t.expectEqual(TerminalFocus.adapter(forBundleId: "org.alacritty"), .generic, "focus: unknown app → generic")
        t.expectEqual(TerminalFocus.adapter(forBundleId: nil), .generic, "focus: nil bundle → generic")

        let surfaces = [
            TerminalFocus.GhosttyTerminal(id: "A", name: "◐ Fix the build", cwd: "/repo/one"),
            TerminalFocus.GhosttyTerminal(id: "B", name: "◑ Fix the build", cwd: "/repo/two"),
            TerminalFocus.GhosttyTerminal(id: "C", name: "✳ Claude Code", cwd: "/repo/two"),
            TerminalFocus.GhosttyTerminal(id: "D", name: "cargo run", cwd: "/repo/three/"),
        ]
        t.expectEqual(TerminalFocus.pickGhosttyTerminal(surfaces, cwd: "/repo/two", title: "Fix the build")?.id, "B", "pick: cwd + title beats title alone")
        t.expectEqual(TerminalFocus.pickGhosttyTerminal(surfaces, cwd: "/elsewhere", title: "Fix the build")?.id, "A", "pick: title alone when cwd differs")
        t.expectEqual(TerminalFocus.pickGhosttyTerminal(surfaces, cwd: "/repo/two", title: nil)?.id, "B", "pick: cwd alone, first in order")
        t.expectEqual(TerminalFocus.pickGhosttyTerminal(surfaces, cwd: "/repo/three", title: "")?.id, "D", "pick: trailing slash tolerated, empty title ignored")
        t.expectNil(TerminalFocus.pickGhosttyTerminal(surfaces, cwd: "/nope", title: "Nothing"), "pick: no match → nil (fall back to app)")

        func strList(_ xs: [String]) -> NSAppleEventDescriptor {
            let l = NSAppleEventDescriptor.list()
            for x in xs { l.insert(NSAppleEventDescriptor(string: x), at: 0) }
            return l
        }
        let reply = NSAppleEventDescriptor.list()
        reply.insert(strList(["id1", "id2"]), at: 0)
        reply.insert(strList(["◐ One", "Two"]), at: 0)
        reply.insert(strList(["/a", "/b"]), at: 0)
        t.expectEqual(TerminalFocus.parseGhosttyList(reply), [
            TerminalFocus.GhosttyTerminal(id: "id1", name: "◐ One", cwd: "/a"),
            TerminalFocus.GhosttyTerminal(id: "id2", name: "Two", cwd: "/b"),
        ], "ghostty: parallel lists zip into terminals")
        t.expectNil(TerminalFocus.parseGhosttyList(NSAppleEventDescriptor(string: "oops")), "ghostty: non-list reply → nil")
        t.expectEqual(TerminalFocus.parseGhosttyList(reply)?.count, 2, "ghostty: count")

        t.expectEqual(TerminalFocus.appleScriptLiteral(#"say "hi" \ bye"#), #"say \"hi\" \\ bye"#, "script: literal escaping")
        t.expectEqual(TerminalFocus.ghosttyFocusScript(terminalId: "X\"Y").contains(#"terminal id "X\"Y""#), true, "script: id embedded escaped")
        t.expectEqual(TerminalFocus.terminalAppScript(tty: "/dev/ttys004").contains(#"tty of t is "/dev/ttys004""#), true, "script: Terminal tty embedded")
        t.expectEqual(TerminalFocus.itermScript(tty: "/dev/ttys004").contains(#"tty of s is "/dev/ttys004""#), true, "script: iTerm tty embedded")

        t.expectEqual(TerminalFocus.adapter(forBundleId: "com.microsoft.VSCode"), .vscode, "focus: VS Code adapter")
        t.expectEqual(TerminalFocus.adapter(forBundleId: "com.todesktop.230313mzl4w4u92"), .vscode, "focus: Cursor adapter")
        t.expectEqual(TerminalFocus.cliName(forBundleId: "com.microsoft.VSCode"), "code", "vscode: cli name")
        t.expectEqual(TerminalFocus.cliName(forBundleId: "com.microsoft.VSCodeInsiders"), "code-insiders", "vscode: insiders cli name")
        t.expectEqual(TerminalFocus.cliName(forBundleId: "com.todesktop.230313mzl4w4u92"), "cursor", "vscode: cursor cli name")

        let reqData = TerminalFocus.vscodeRequest(nonce: "n-1", pids: [10, 20], cwd: "/w", sessionId: "s-1",
                                                  now: Date(timeIntervalSince1970: 1_700_000_000.5))
        let req = (try? JSONSerialization.jsonObject(with: reqData)) as? [String: Any]
        t.expectEqual(req?["nonce"] as? String, "n-1", "vscode request: nonce")
        t.expectEqual(req?["pids"] as? [Int], [10, 20], "vscode request: pids")
        t.expectEqual(req?["ts"] as? Int, 1_700_000_000_500, "vscode request: epoch ms")
        t.expectEqual(req?["cwd"] as? String, "/w", "vscode request: cwd")
        t.expectEqual(req?["sessionId"] as? String, "s-1", "vscode request: sessionId")

        let okReply = Data(#"{"nonce":"n-1","workspace":"/w/proj.code-workspace","terminal":"zsh","ts":1}"#.utf8)
        t.expectEqual(TerminalFocus.parseVSCodeReply(okReply, nonce: "n-1"),
                      TerminalFocus.VSCodeReply(nonce: "n-1", workspace: "/w/proj.code-workspace", terminal: "zsh"), "vscode reply: parsed")
        t.expectNil(TerminalFocus.parseVSCodeReply(okReply, nonce: "other"), "vscode reply: nonce mismatch → nil")
        t.expectEqual(TerminalFocus.parseVSCodeReply(Data(#"{"nonce":"n-1","workspace":null}"#.utf8), nonce: "n-1")?.workspace, nil, "vscode reply: untitled window → nil workspace")
        t.expectEqual(TerminalFocus.parseVSCodeReply(Data(#"{"nonce":"n-1","workspace":""}"#.utf8), nonce: "n-1")?.workspace, nil, "vscode reply: empty workspace → nil")
        t.expectNil(TerminalFocus.parseVSCodeReply(Data("garbage".utf8), nonce: "n-1"), "vscode reply: malformed → nil")

        let winJSON = Data(#"{"ts":1700000000000,"name":"claude-status","workspace":"/w/claude-status","terminals":[{"pid":501,"name":"zsh"},{"pid":502,"name":"✳ Claude Code"},{"name":"starting"}]}"#.utf8)
        let win = TerminalFocus.parseVSCodeWindowState(winJSON)
        t.expectEqual(win?.terminalPids, [501, 502], "window state: pids (pid-less terminal skipped)")
        t.expectEqual(win?.label, "claude-status", "window state: label from workspace name")
        t.expectEqual(win?.ts, Date(timeIntervalSince1970: 1_700_000_000), "window state: epoch ms")
        t.expectEqual(TerminalFocus.parseVSCodeWindowState(Data(#"{"ts":1,"workspace":"/w/proj","terminals":[]}"#.utf8))?.label, "proj", "window state: label falls back to folder name")
        t.expectEqual(TerminalFocus.parseVSCodeWindowState(Data(#"{"ts":1,"terminals":[]}"#.utf8))?.label, "untitled window", "window state: untitled")
        t.expectNil(TerminalFocus.parseVSCodeWindowState(Data(#"{"terminals":[]}"#.utf8)), "window state: no ts → nil")
        let winA = TerminalFocus.VSCodeWindowState(name: "A", workspace: nil, terminalPids: [11, 12], ts: Date())
        let winB = TerminalFocus.VSCodeWindowState(name: "B", workspace: nil, terminalPids: [21], ts: Date())
        t.expectEqual(TerminalFocus.vscodeWindow(owning: [900, 21, 1], in: [winA, winB])?.name, "B", "window lookup: any pid in the chain")
        t.expectNil(TerminalFocus.vscodeWindow(owning: [7], in: [winA, winB]), "window lookup: none → nil")
        let winDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cs-windows-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: winDir)
        try? FileManager.default.createDirectory(at: winDir, withIntermediateDirectories: true)
        let fresh = Int(Date().timeIntervalSince1970 * 1000)
        try? Data(#"{"ts":\#(fresh),"name":"fresh","terminals":[{"pid":1}]}"#.utf8).write(to: winDir.appendingPathComponent("a.json"))
        try? Data(#"{"ts":\#(fresh - 600_000),"name":"stale","terminals":[{"pid":2}]}"#.utf8).write(to: winDir.appendingPathComponent("b.json"))
        try? Data("junk".utf8).write(to: winDir.appendingPathComponent("c.json"))
        t.expectEqual(TerminalFocus.loadVSCodeWindows(dir: winDir).map(\.name), ["fresh"], "window load: stale and junk files dropped")
        t.expectEqual(TerminalFocus.loadVSCodeWindows(dir: winDir.appendingPathComponent("missing")).count, 0, "window load: missing dir → empty")
        try? FileManager.default.removeItem(at: winDir)
        t.expectEqual(TerminalFocus.displayName(forBundleId: "com.microsoft.VSCode", fallback: "Code"), "VS Code", "host name: VS Code")
        t.expectEqual(TerminalFocus.displayName(forBundleId: "com.mitchellh.ghostty", fallback: "Ghostty"), "Ghostty", "host name: fallback")

        func fakeSession(_ pid: pid_t, cwd: String, host: SessionHost?) -> ClaudeSession {
            ClaudeSession(pid: pid, cwd: cwd, name: nil, sessionId: nil, gitBranch: nil, title: nil, host: host,
                          state: .idle, waitingFor: nil, lastActivity: nil, stateSince: nil, startedAt: nil)
        }
        let vsA = SessionHost(bundleId: "com.microsoft.VSCode", appName: "VS Code", window: "alpha")
        let vsB = SessionHost(bundleId: "com.microsoft.VSCode", appName: "VS Code", window: "beta")
        let ghostty = SessionHost(bundleId: "com.mitchellh.ghostty", appName: "Ghostty", window: nil)
        t.expectEqual(vsA.label, "VS Code · alpha", "host: window label")
        t.expectEqual(ghostty.label, "Ghostty", "host: app-only label")
        t.expectEqual(vsA.groupKey == vsB.groupKey, false, "host: windows group separately")
        let grouped = SessionsView.grouped([
            fakeSession(1, cwd: "/a", host: vsB),
            fakeSession(2, cwd: "/b", host: ghostty),
            fakeSession(3, cwd: "/c", host: nil),
            fakeSession(4, cwd: "/d", host: vsA),
            fakeSession(5, cwd: "/a", host: vsB),
            fakeSession(6, cwd: "/f", host: SessionHost(bundleId: "com.microsoft.VSCode", appName: "VS Code", window: nil)),
        ])
        t.expectEqual(grouped.map(\.label), ["Ghostty", "VS Code", "Other"], "grouping: hosts by label, Other last")
        t.expectEqual(grouped[1].windows.map(\.label), ["alpha", "beta", nil], "grouping: windows by label, unreported last")
        t.expectEqual(grouped[1].windows[1].sessions.map(\.pid), [1, 5], "grouping: rows keep scan order inside a window")
        t.expectEqual(grouped[1].windows[1].sharedPath, "/a", "grouping: shared cwd → path on the window")
        t.expectEqual(grouped[1].windows[0].sharedPath, "/d", "grouping: single row → its cwd is the window's")
        t.expectNil(grouped[0].windows.first?.label, "grouping: Ghostty has no window level")
        t.expectNil(SessionsView.grouped([fakeSession(1, cwd: "/a", host: vsB), fakeSession(2, cwd: "/z", host: vsB)])[0].windows[0].sharedPath, "grouping: mixed cwds in a window → no shared path")
        t.expectEqual(SessionsView.grouped([]).count, 0, "grouping: empty")

        let chain = TerminalFocus.ancestorPids(of: getpid())
        t.expectEqual(chain.first, getpid(), "ancestors: starts with the pid itself")
        t.expectEqual(chain.contains(getppid()), true, "ancestors: includes the parent")
        t.expectEqual(chain.contains(1), false, "ancestors: stops below launchd")

        // Bridge round-trip against a fake extension: a thread watching the
        // request file that answers with the request's nonce.
        let bridgeDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cs-bridge-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: bridgeDir)
        t.expectNil(TerminalFocus.bridgeVSCode(pids: [1], cwd: "/", sessionId: nil, dir: bridgeDir, deadline: 0.2), "bridge: no extension → nil after deadline")
        Thread.detachNewThread {
            let request = bridgeDir.appendingPathComponent("request.json")
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: request),
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let nonce = obj["nonce"] as? String, (obj["pids"] as? [Int]) == [42, 43] {
                    let reply = #"{"nonce":"\#(nonce)","workspace":"/fake/ws","terminal":"zsh"}"#
                    try? Data(reply.utf8).write(to: bridgeDir.appendingPathComponent("reply.json"))
                    return
                }
                usleep(10_000)
            }
        }
        let bridged = TerminalFocus.bridgeVSCode(pids: [42, 43], cwd: "/x", sessionId: "s", dir: bridgeDir, deadline: 2)
        t.expectEqual(bridged?.workspace, "/fake/ws", "bridge: reply from the owning window")
        t.expectEqual(bridged?.terminal, "zsh", "bridge: terminal name carried")
        try? FileManager.default.removeItem(at: bridgeDir)

        t.expectEqual(TerminalFocus.chooseHostIndex(policies: [.regular]), 0, "host: lone regular app")
        t.expectEqual(TerminalFocus.chooseHostIndex(policies: [.accessory, .regular]), 1, "host: skip helper, take the app above it")
        t.expectEqual(TerminalFocus.chooseHostIndex(policies: [.prohibited, .accessory, .regular, .regular]), 2, "host: nearest regular, not the outermost")
        t.expectEqual(TerminalFocus.chooseHostIndex(policies: [.accessory, .prohibited]), 0, "host: no regular app → nearest of any kind")
        t.expectNil(TerminalFocus.chooseHostIndex(policies: []), "host: no apps in the chain → nil")

        t.expectEqual(TerminalFocus.parentPid(of: getpid()), getppid(), "proc: parent pid via sysctl")
        t.expectNil(TerminalFocus.parentPid(of: 999_999), "proc: dead pid → nil")
        if let tty = TerminalFocus.ttyPath(of: getpid()) {
            t.expectEqual(tty.hasPrefix("/dev/tty"), true, "proc: tty path shape")
        } else {
            t.expectEqual(true, true, "proc: no controlling tty (headless run)")
        }

        // MARK: formatting

        let now = Date(timeIntervalSince1970: 1_000_000)
        t.expectEqual(StatusFormat.agoString(since: now.addingTimeInterval(-2), now: now), "just now", "ago: <5s")
        t.expectEqual(StatusFormat.agoString(since: now.addingTimeInterval(-30), now: now), "30s ago", "ago: seconds")
        t.expectEqual(StatusFormat.agoString(since: now.addingTimeInterval(-150), now: now), "2m ago", "ago: minutes")
        t.expectEqual(StatusFormat.compactAge(since: now.addingTimeInterval(-12), now: now), "12s", "age: seconds")
        t.expectEqual(StatusFormat.compactAge(since: now.addingTimeInterval(-150), now: now), "2m", "age: minutes")
        t.expectEqual(StatusFormat.compactAge(since: now.addingTimeInterval(-7500), now: now), "2h 5m", "age: hours")
        let start = Date(timeIntervalSince1970: 0)
        t.expectEqual(StatusFormat.compactDuration(from: start, to: start.addingTimeInterval(59)), "0m", "duration: sub-minute")
        t.expectEqual(StatusFormat.compactDuration(from: start, to: start.addingTimeInterval(9240)), "2h 34m", "duration: hours")

        t.finish()
    }
}
