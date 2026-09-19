import Combine
import SwiftUI

struct SessionsView: View {
    @ObservedObject var store: SessionStore
    /// Row click: bring the session's terminal to the front. Injected by
    /// AppDelegate (which also closes the panel); no-op in previews/tests.
    var onFocusSession: (ClaudeSession) -> Void = { _ in }
    @ViewState private var now: Date = Date()
    @ViewState private var hoveredPid: pid_t? = nil

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if store.sessions.isEmpty {
                emptyState
            } else {
                sessionRows
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 392, alignment: .leading)
        .onReceive(tick) { now = $0 }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Sessions")
                .font(.headline)
            Spacer()
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: String {
        if store.sessions.isEmpty { return "none running" }
        var parts: [String] = []
        if store.busyCount > 0 { parts.append("\(store.busyCount) working") }
        if store.shellCount > 0 { parts.append("\(store.shellCount) in shell") }
        if store.waitingCount > 0 { parts.append("\(store.waitingCount) waiting") }
        if store.idleCount > 0 { parts.append("\(store.idleCount) idle") }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        Text("No Claude sessions running.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.vertical, 4)
    }

    private var sessionRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(store.sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 { Divider() }
                clickableRow(for: session)
            }
        }
    }

    /// The whole row is a click target that raises the session's terminal;
    /// the Approve/Deny/⋯ controls inside keep their own taps (child
    /// gestures win). Hover tints the row and shows the pointing hand, same
    /// affordance as the approval pills. The padding-in/padding-out pair
    /// draws the highlight slightly larger than the content without
    /// shifting the layout.
    private func clickableRow(for session: ClaudeSession) -> some View {
        row(for: session)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hoveredPid == session.pid ? 0.06 : 0))
            )
            .padding(.horizontal, -6)
            .padding(.vertical, -5)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    hoveredPid = session.pid
                    NSCursor.pointingHand.set()
                } else {
                    if hoveredPid == session.pid { hoveredPid = nil }
                    NSCursor.arrow.set()
                }
            }
            .onTapGesture { onFocusSession(session) }
            .help("Bring this session's terminal to the front")
    }

    private func row(for session: ClaudeSession) -> some View {
        let effectiveState = store.effectiveState(session)
        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(stateColor(effectiveState))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 14, weight: .semibold))
                    if store.hasAutoApprove(session) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                            .help("Auto-approving permission requests for this session")
                    }
                }
                if let branch = session.gitBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(abbreviatedPath(session.cwd))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // A pending permission request takes over the status area: the
            // verdict buttons render exactly where the state text would be,
            // with the command under them where the timing caption goes.
            if let approval = store.firstPending(for: session) {
                approvalControls(for: approval, in: session)
            } else {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(stateText(session))
                        .font(.callout)
                        .foregroundStyle(stateColor(session.state))
                    Text(activityText(for: session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func approvalControls(for approval: PendingApproval, in session: ClaudeSession) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button("Approve") { store.approve(approval) }
                    .buttonStyle(ApprovalPillStyle(color: Self.approveGreen))
                Button("Deny") { store.deny(approval) }
                    .buttonStyle(ApprovalPillStyle(color: .red))
                Menu {
                    Button("Approve all for 5 minutes") {
                        if let sid = session.sessionId {
                            store.approveAll(sessionId: sid, rule: .until(Date().addingTimeInterval(300)))
                        }
                    }
                    Button("Approve all for this session") {
                        if let sid = session.sessionId {
                            store.approveAll(sessionId: sid, rule: .forSession)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            // Hover reveals the full request (newlines intact) after the
            // system's standard tooltip delay.
            Text(pendingSummary(approval, in: session))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .trailing)
                .help(approval.detail)
        }
    }

    /// Approve-pill green: plain systemGreen is too washed out against the
    /// panel's near-white light-mode background, but full forest green read
    /// too rich — light mode sits halfway between the two. Dark mode keeps
    /// the brighter system green, which reads well on dark.
    private static let approveGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemGreen
            : NSColor(srgbRed: 0.16, green: 0.64, blue: 0.29, alpha: 1)
    })

    private func pendingSummary(_ approval: PendingApproval, in session: ClaudeSession) -> String {
        let more = store.pendingCount(for: session) - 1
        return more > 0 ? "\(approval.summary) · +\(more) more" : approval.summary
    }

    private var footer: some View {
        HStack {
            Spacer()
            Menu {
                Toggle("Invert menu bar colors", isOn: $store.invertMenubarColors)
                    .help("On: solid color block behind the count. Off: colored text on the bare menu bar.")
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: Derived

    private func stateColor(_ state: ClaudeSession.State) -> Color {
        switch state {
        case .busy: return .green
        case .shell: return .blue
        case .idle: return Color(nsColor: .secondaryLabelColor)
        case .waitingForInput: return .orange
        }
    }

    private func stateText(_ session: ClaudeSession) -> String {
        switch session.state {
        case .busy: return "Working"
        case .shell: return "Shell command"
        case .idle: return "Idle"
        case .waitingForInput:
            if let what = session.waitingFor, !what.isEmpty {
                return "Waiting: \(what)"
            }
            return "Waiting for input"
        }
    }

    /// "for 12s · up 2h 14m" — how long the current state has held, plus
    /// session age.
    private func activityText(for session: ClaudeSession) -> String {
        var parts: [String] = []
        if let since = session.stateSince {
            parts.append("for \(StatusFormat.compactAge(since: since, now: now))")
        }
        if let started = session.startedAt {
            parts.append("up \(StatusFormat.compactDuration(from: started, to: now))")
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Compact tinted capsule for the inline Approve/Deny verdict buttons —
/// color-on-soft-color so the pair reads instantly (green = go, red = stop)
/// against the panel's vibrancy, with a darker fill while pressed. Hover
/// shows the pointing hand as the click affordance.
private struct ApprovalPillStyle: ButtonStyle {
    let color: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 3.5)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.35 : 0.15)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

// MARK: - Formatting helpers

enum StatusFormat {
    /// "just now" / "12s ago" / "3m ago" / "2h 5m ago"
    static func agoString(since past: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince(past)))
        if secs < 5 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(compactDuration(from: past, to: now)) ago"
    }

    /// "2h 34m" / "57m" / "0m" — same shape as ClaudeUsage's duration labels.
    static func compactDuration(from start: Date, to end: Date) -> String {
        let secs = max(0, Int(end.timeIntervalSince(start)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "12s" / "3m" / "2h 5m" — seconds-precision only while young, for the
    /// "state held for …" label.
    static func compactAge(since past: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(now.timeIntervalSince(past)))
        if secs < 60 { return "\(secs)s" }
        return compactDuration(from: past, to: now)
    }
}
