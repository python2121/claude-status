import AppKit

@main
struct ClaudeStatusMain {
    // Held in a static so NSApplication's weak `delegate` reference doesn't
    // free it.
    private static let appDelegate = AppDelegate()

    static func main() {
        // Headless self-test mode: run the hand-rolled assertion suite and
        // exit, before NSApplication (or the single-instance lock) exists.
        if CommandLine.arguments.contains("--self-test") {
            SelfTest.run()
        }

        // Headless scan mode: print one line per detected session and exit.
        // Handy for debugging the detection heuristics without the GUI.
        if CommandLine.arguments.contains("--scan") {
            let sessions = SessionScanner.scan()
            for s in sessions {
                let state: String
                switch s.state {
                case .busy: state = "busy"
                case .shell: state = "shell"
                case .idle: state = "idle"
                case .waitingForInput: state = "waiting" + (s.waitingFor.map { " (\($0))" } ?? "")
                }
                let since = s.stateSince.map { StatusFormat.compactAge(since: $0) } ?? "?"
                print("pid=\(s.pid) [\(state) for \(since)] \(s.name ?? s.projectName) (\(s.gitBranch ?? "-")) \(s.cwd)")
            }
            print("\(sessions.count) session(s), \(sessions.filter { $0.state == .waitingForInput }.count) waiting")
            exit(0)
        }

        // Only one menubar GUI at a time. If another instance already holds
        // the lock (e.g. the LaunchAgent copy is up and something launched a
        // second one), bow out cleanly instead of stacking a duplicate
        // status item.
        guard SingleInstance.acquire() else {
            FileHandle.standardError.write(
                Data("ClaudeStatus: another instance is already running; exiting.\n".utf8))
            exit(0)
        }

        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
