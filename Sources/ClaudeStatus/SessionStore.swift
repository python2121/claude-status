import AppKit
import Foundation

/// Single source of truth: polls SessionScanner and publishes the session
/// list. AppDelegate observes objectWillChange to repaint the menubar count;
/// SessionsView renders the rows.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    /// Menubar style: true = solid color block with contrasting text (the
    /// "inverted" look), false = the classic colored-text-on-clear style.
    /// Persisted; AppDelegate repaints via objectWillChange on change.
    @Published var invertMenubarColors: Bool = UserDefaults.standard.object(forKey: SessionStore.invertMenubarColorsKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(invertMenubarColors, forKey: SessionStore.invertMenubarColorsKey) }
    }
    private static let invertMenubarColorsKey = "invertMenubarColors"

    private var timer: Timer?
    /// Everything we poll is local (libproc + a stat and a tail-read per
    /// session), so a tight interval is cheap and keeps the count honest.
    private let pollInterval: TimeInterval = 2

    init(startPolling: Bool = true) {
        guard startPolling else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.refresh() }
        }
    }

    func refresh() async {
        // The scan blocks on libproc + file IO — keep it off the main thread.
        let scanned = await Task.detached(priority: .utility) { SessionScanner.scan() }.value
        if scanned != sessions { sessions = scanned }
    }

    var waitingCount: Int { sessions.filter { $0.state == .waitingForInput }.count }
    var busyCount: Int { sessions.filter { $0.state == .busy }.count }
    var shellCount: Int { sessions.filter { $0.state == .shell }.count }
    var idleCount: Int { sessions.filter { $0.state == .idle }.count }

    /// Menubar text + color: the session count, red when anything is waiting
    /// on the user, orange when sessions are working, muted when everything
    /// is idle (or nothing is running). `filled` requests a solid color block
    /// (the state color as background, contrasting text) instead of
    /// colored-on-clear text — far more legible in the menu bar. Only the
    /// alert states (red/orange) fill — and only when `invertMenubarColors`
    /// is on; the muted zero/idle state stays plain so it blends in.
    var menubarLabel: (text: String, color: NSColor, filled: Bool) {
        Self.label(total: sessions.count, busy: busyCount, waiting: waitingCount, invert: invertMenubarColors)
    }

    nonisolated static func label(total: Int, busy: Int, waiting: Int, invert: Bool) -> (text: String, color: NSColor, filled: Bool) {
        let text = "\(total)"
        if waiting > 0 { return (text, .systemRed, invert) }
        if busy > 0 { return (text, .systemOrange, invert) }
        return (text, .secondaryLabelColor, false)
    }
}
