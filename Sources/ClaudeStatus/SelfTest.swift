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
        t.expectEqual(SessionScanner.state(fromStatus: "someday-new"), .idle, "unknown status → idle, never false red")
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

        t.expectNil(SessionScanner.parseTail(""), "parseTail empty → nil")
        t.expectNil(SessionScanner.parseTail("not json at all"), "parseTail garbage → nil")

        // MARK: pid liveness

        t.expectEqual(SessionScanner.pidAlive(getpid()), true, "own pid is alive")

        // MARK: menubar label

        t.expectEqual(SessionStore.label(total: 0, busy: 0, waiting: 0, invert: true).text, "0", "label text at zero")
        t.expectEqual(SessionStore.label(total: 0, busy: 0, waiting: 0, invert: true).color, .secondaryLabelColor, "zero sessions → muted")
        t.expectEqual(SessionStore.label(total: 3, busy: 2, waiting: 0, invert: true).color, .systemOrange, "busy → orange")
        t.expectEqual(SessionStore.label(total: 3, busy: 2, waiting: 1, invert: true).color, .systemRed, "any waiting → red")
        t.expectEqual(SessionStore.label(total: 2, busy: 0, waiting: 0, invert: true).color, .secondaryLabelColor, "all idle → muted")
        t.expectEqual(SessionStore.label(total: 3, busy: 1, waiting: 1, invert: true).text, "3", "label shows total count")
        t.expectEqual(SessionStore.label(total: 3, busy: 2, waiting: 0, invert: true).filled, true, "invert on + busy → filled pill")
        t.expectEqual(SessionStore.label(total: 3, busy: 2, waiting: 1, invert: false).filled, false, "invert off → never filled")
        t.expectEqual(SessionStore.label(total: 2, busy: 0, waiting: 0, invert: true).filled, false, "muted idle state stays plain even inverted")

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
