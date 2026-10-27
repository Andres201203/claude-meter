// Claude Meter — a desktop widget for Claude's 5-hour and weekly plan limits.
// Reads the OAuth token Claude Code keeps in the Keychain (read-only) and polls
// the usage endpoint Claude itself uses. Nothing is stored except the last reading.

import AppKit
import SwiftUI

// MARK: - Model

struct Limit: Codable, Equatable {
    var percent: Double
    var resetsAt: Date?
}

struct Reading: Codable, Equatable {
    var session: Limit
    var weekly: Limit
    var plan: String?
    var fetchedAt: Date
}

enum WidgetSize: String { case medium, small }

enum Status: Equatable {
    case loading
    case ok
    case loginExpired
    case failed(String)
}

final class Store: ObservableObject {
    @Published var reading: Reading?
    @Published var status: Status = .loading
    @Published var now = Date()
    @Published var size: WidgetSize

    private let defaults = UserDefaults.standard
    private var pollTimer: Timer?
    private var clockTimer: Timer?

    init() {
        size = WidgetSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium
        if let data = defaults.data(forKey: "lastReading"),
           let saved = try? JSONDecoder().decode(Reading.self, from: data) {
            reading = saved
        }
    }

    func start() {
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in self?.refresh() }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.now = Date() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    func setSize(_ s: WidgetSize) {
        size = s
        defaults.set(s.rawValue, forKey: "size")
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async {
            let result = UsageClient.fetch()
            DispatchQueue.main.async {
                self.now = Date()
                switch result {
                case .success(let r):
                    self.reading = r
                    self.status = .ok
                    if let data = try? JSONEncoder().encode(r) { self.defaults.set(data, forKey: "lastReading") }
                case .failure(let e):
                    self.status = e == .loginExpired ? .loginExpired : .failed(e.message)
                }
            }
        }
    }
}

// MARK: - Fetching

enum FetchError: Error, Equatable {
    case loginExpired
    case other(String)

    var message: String {
        switch self {
        case .loginExpired: return "Login expired"
        case .other(let m): return m
        }
    }
}

enum UsageClient {
    struct Credentials { let token: String; let expiresAt: Date?; let plan: String? }

    /// Reads Claude Code's credentials through `/usr/bin/security`, the same way
    /// Claude Code does, so the Keychain doesn't prompt and nothing is written back.
    static func credentials() -> Credentials? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(token: token, expiresAt: expires, plan: oauth["subscriptionType"] as? String)
    }

    static func fetch() -> Result<Reading, FetchError> {
        guard let creds = credentials() else { return .failure(.loginExpired) }
        if let exp = creds.expiresAt, exp < Date() { return .failure(.loginExpired) }

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-meter/1.0", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var result: Result<Reading, FetchError> = .failure(.other("No response"))
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if err != nil { result = .failure(.other("Offline")); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { result = .failure(.loginExpired); return }
            guard code == 200, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = limit(json["five_hour"]),
                  let weekly = limit(json["seven_day"]) else {
                result = .failure(.other(code == 429 ? "Rate limited" : "Couldn't read usage"))
                return
            }
            result = .success(Reading(session: session, weekly: weekly, plan: creds.plan, fetchedAt: Date()))
        }.resume()
        sem.wait()
        return result
    }

    private static func limit(_ any: Any?) -> Limit? {
        guard let d = any as? [String: Any], let pct = d["utilization"] as? Double else { return nil }
        return Limit(percent: pct, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Formatting

enum Fmt {
    static func countdown(to date: Date?, now: Date) -> String {
        guard let date else { return "—" }
        let mins = max(0, Int(date.timeIntervalSince(now) / 60))
        if mins < 60 { return "\(mins)m" }
        return "\(mins / 60)h \(mins % 60)m"
    }

    static func weekday(_ date: Date?) -> String {
        guard let date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "'Today' h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    static func ago(_ date: Date, now: Date) -> String {
        let mins = Int(now.timeIntervalSince(date) / 60)
        if mins < 1 { return "Updated just now" }
        if mins < 60 { return "Updated \(mins) min ago" }
        return "Updated \(mins / 60)h ago"
    }

    static func time(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }
}

// MARK: - Views

struct Ring: View {
    let percent: Double
    let diameter: CGFloat
    let lineWidth: CGFloat
    let fontSize: CGFloat

    var color: Color {
        percent >= 90 ? Color(nsColor: .systemRed) : percent >= 75 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue)
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, percent / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: percent)
            // "36%" is centered as one unit, with a smaller % on the same baseline.
            (Text("\(Int(percent.rounded()))")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
             + Text("%")
                .font(.system(size: fontSize * 0.62, weight: .semibold, design: .rounded)))
                .monospacedDigit()
                .fixedSize()
        }
        .frame(width: diameter, height: diameter)
    }
}

struct Meter: View {
    let name: String
    let detail: String
    let percent: Double
    let compact: Bool

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Ring(percent: percent,
                 diameter: compact ? 42 : 64,
                 lineWidth: compact ? 6 : 7,
                 fontSize: compact ? 12.5 : 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: compact ? 12 : 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: compact ? 10.5 : 11.5))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .monospacedDigit()
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }
}

struct Header: View {
    let trailing: String?
    let plan: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle").font(.system(size: 10, weight: .bold))
            Text(plan.map { "Claude · \($0.capitalized)" } ?? "Claude")
            Spacer(minLength: 4)
            if let trailing { Text(trailing).fontWeight(.medium).monospacedDigit() }
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(Color.primary.opacity(0.6))
        .lineLimit(1)
    }
}

struct WidgetView: View {
    @ObservedObject var store: Store

    var body: some View {
        Group {
            if store.status == .loginExpired {
                expired
            } else if let r = store.reading {
                content(r)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Header(trailing: nil, plan: nil)
                    Spacer()
                    Text(placeholder).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.6))
                    Spacer()
                }
            }
        }
        .padding(16)
        .frame(width: store.size == .medium ? 340 : 158, height: 158, alignment: .topLeading)
        // Native desktop widgets read as a deeper tint of the wallpaper with a faint edge.
        .background(scheme == .dark ? Color.black.opacity(0.34) : Color.white.opacity(0.32))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .circular)
                .strokeBorder(Color.white.opacity(scheme == .dark ? 0.14 : 0.5), lineWidth: 1)
        )
    }

    @Environment(\.colorScheme) private var scheme

    private var placeholder: String {
        if case .failed(let m) = store.status { return m }
        return "Loading…"
    }

    private var trailingNote: String? {
        guard let r = store.reading else { return nil }
        if case .failed(let m) = store.status { return m }
        return Fmt.ago(r.fetchedAt, now: store.now)
    }

    @ViewBuilder private func content(_ r: Reading) -> some View {
        let s = r.session, w = r.weekly
        if store.size == .medium {
            VStack(alignment: .leading, spacing: 10) {
                Header(trailing: trailingNote, plan: r.plan)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Meter(name: "5-hour", detail: "Resets in \(Fmt.countdown(to: s.resetsAt, now: store.now))", percent: s.percent, compact: false)
                    Meter(name: "Weekly", detail: "Resets \(Fmt.weekday(w.resetsAt))", percent: w.percent, compact: false)
                }
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Header(trailing: nil, plan: nil)
                Meter(name: "5-hour", detail: "in \(Fmt.countdown(to: s.resetsAt, now: store.now))", percent: s.percent, compact: true)
                Meter(name: "Weekly", detail: Fmt.weekday(w.resetsAt), percent: w.percent, compact: true)
            }
        }
    }

    private var expired: some View {
        VStack(alignment: .leading, spacing: 6) {
            Header(trailing: nil, plan: nil)
            Spacer(minLength: 0)
            Text("Login expired").font(.system(size: 14, weight: .semibold))
            Text(expiredDetail)
                .font(.system(size: 12))
                .foregroundStyle(Color.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var expiredDetail: String {
        var text = "Open Claude Code once to reconnect."
        if let r = store.reading {
            text += " Last reading: \(Int(r.session.percent.rounded()))% at \(Fmt.time(r.fetchedAt))."
        }
        return text
    }
}

// MARK: - Window

/// Sits on top of the SwiftUI content and handles the only interactions the
/// widget has: drag to move, double-click to refresh, right-click for the menu.
final class InteractionView: NSView {
    var onDoubleClick: () -> Void = {}

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick(); return }
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let store = Store()
    var window: WidgetWindow!
    var effect: NSVisualEffectView!

    func applicationDidFinishLaunching(_ note: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 340, height: 158)
        window = WidgetWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false // native desktop widgets sit flat on the wallpaper
        // Just above the wallpaper and desktop icons, below every app window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.delegate = self

        effect = NSVisualEffectView(frame: rect)
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        // A mask image (not a layer corner radius) is what rounds the window's
        // real outline, so no square edges show through at the corners.
        effect.maskImage = Self.roundedMask(radius: 22)
        effect.autoresizingMask = [.width, .height]

        let host = NSHostingView(rootView: WidgetView(store: store))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)

        let interaction = InteractionView(frame: effect.bounds)
        interaction.autoresizingMask = [.width, .height]
        interaction.onDoubleClick = { [weak self] in self?.store.refresh() }
        interaction.menu = makeMenu()
        effect.addSubview(interaction)

        window.contentView = effect
        applySize(store.size, keepOrigin: false)
        window.orderFrontRegardless()
        store.start()
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "").target = self
        let medium = menu.addItem(withTitle: "Medium size", action: #selector(useMedium), keyEquivalent: "")
        medium.target = self
        let small = menu.addItem(withTitle: "Small size", action: #selector(useSmall), keyEquivalent: "")
        small.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Claude Meter", action: #selector(quit), keyEquivalent: "").target = self
        return menu
    }

    @objc func refreshNow() { store.refresh() }
    @objc func useMedium() { store.setSize(.medium); applySize(.medium, keepOrigin: true) }
    @objc func useSmall() { store.setSize(.small); applySize(.small, keepOrigin: true) }
    @objc func quit() { NSApp.terminate(nil) }

    private func applySize(_ size: WidgetSize, keepOrigin: Bool) {
        let w: CGFloat = size == .medium ? 340 : 158
        var origin = window.frame.origin
        if !keepOrigin {
            let d = UserDefaults.standard
            if d.object(forKey: "x") != nil {
                origin = NSPoint(x: d.double(forKey: "x"), y: d.double(forKey: "y"))
            } else if let vf = NSScreen.main?.visibleFrame {
                origin = NSPoint(x: vf.maxX - w - 24, y: vf.maxY - 158 - 24)
            }
        }
        window.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: 158)), display: true)
        clampToScreen()
    }

    /// Keeps the widget visible if a monitor was unplugged or the saved spot is off-screen.
    private func clampToScreen() {
        let f = window.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) { return }
        guard let vf = NSScreen.main?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: vf.maxX - f.width - 24, y: vf.maxY - f.height - 24))
    }

    func windowDidMove(_ note: Notification) {
        UserDefaults.standard.set(window.frame.origin.x, forKey: "x")
        UserDefaults.standard.set(window.frame.origin.y, forKey: "y")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
