// StudyLens: samples what is on screen once a minute, shows a desktop widget, and asks for a weekend check-in.
// The analyzer (Python, run by launchd) labels the samples with a local Ollama vision model.
import AppKit
import CoreLocation
import CoreWLAN
import ServiceManagement
import SQLite3
import SwiftUI

let dataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/StudyLens")
let shotsDir = dataDir.appendingPathComponent("shots")
let analyzerDir = dataDir.appendingPathComponent("analyzer")

// Runs before the settings load, so the preview works on any Mac.
if let i = CommandLine.arguments.firstIndex(of: "--render-preview"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared  // SwiftUI rendering needs the app object, even without a window
    MainActor.assumeIsolated { renderPreview(to: CommandLine.arguments[i + 1]) }
    exit(0)
}

// MARK: Config

struct Config: Decodable {
    struct Place: Decodable { let name: String; let lat: Double?; let lon: Double?; let radius_m: Double?; let ssid_contains: [String]? }
    struct Checkin: Decodable { let weekdays: [Int]; let hour: Int }  // Calendar weekdays: 1 = Sunday … 6 = Friday, 7 = Saturday
    let sample_seconds: Double
    let idle_minutes: Double
    let screenshot_every_minutes: Double
    let screenshot_max_px: Int
    let hide_widget_at: [Place]
    let no_screenshot_apps: [String]
    let ignore_assertion_owners: [String]
    let checkin: Checkin
}

let cfg: Config = {
    guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("config.json")),
          let config = try? JSONDecoder().decode(Config.self, from: data) else {
        let alert = NSAlert()
        alert.messageText = "StudyLens can't read its settings"
        alert.informativeText = "~/Library/Application Support/StudyLens/config.json is missing or not valid JSON. Run install.sh again, or fix the file."
        alert.runModal()
        exit(1)
    }
    return config
}()

// MARK: Helpers

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: out, as: UTF8.self)
}

func appleScript(_ source: String) -> String? {
    var err: NSDictionary?
    let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
    return err == nil ? result?.stringValue : nil
}

let uvPath = ["/opt/homebrew/bin/uv", "/usr/local/bin/uv", NSHomeDirectory() + "/.local/bin/uv", NSHomeDirectory() + "/.cargo/bin/uv"]
    .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/uv"

func runAnalyzer(_ command: String) {
    DispatchQueue.global().async {
        run(uvPath, ["run", "--project", analyzerDir.path, "--frozen", "--quiet", "studylens", command])
    }
}

// MARK: Database (schema shared with the analyzer)

let schema = """
CREATE TABLE IF NOT EXISTS samples(
  id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, app TEXT, bundle TEXT, title TEXT,
  state TEXT NOT NULL, video INTEGER DEFAULT 0, private INTEGER DEFAULT 0, shot TEXT,
  category TEXT, topic TEXT, activity TEXT, summary TEXT, label_source TEXT);
CREATE INDEX IF NOT EXISTS samples_ts ON samples(ts);
CREATE TABLE IF NOT EXISTS checkins(id INTEGER PRIMARY KEY, ts INTEGER NOT NULL, reply TEXT NOT NULL, applied INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS title_cache(key TEXT PRIMARY KEY, category TEXT, topic TEXT, activity TEXT, summary TEXT);
"""

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class DB {
    private var h: OpaquePointer?

    init() {
        try? FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        sqlite3_open(dataDir.appendingPathComponent("studylens.db").path, &h)
        sqlite3_exec(h, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;" + schema, nil, nil, nil)
    }

    private func prepare(_ sql: String, _ args: [Any?]) -> OpaquePointer? {
        var st: OpaquePointer?
        sqlite3_prepare_v2(h, sql, -1, &st, nil)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case let v as Int: sqlite3_bind_int64(st, idx, Int64(v))
            case let v as String: sqlite3_bind_text(st, idx, v, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_null(st, idx)
            }
        }
        return st
    }

    func exec(_ sql: String, _ args: [Any?] = []) {
        let st = prepare(sql, args)
        sqlite3_step(st)
        sqlite3_finalize(st)
    }

    func strings(_ sql: String, _ args: [Any?] = []) -> [String] {
        let st = prepare(sql, args)
        var out: [String] = []
        while sqlite3_step(st) == SQLITE_ROW {
            if let c = sqlite3_column_text(st, 0) { out.append(String(cString: c)) }
        }
        sqlite3_finalize(st)
        return out
    }

    /// Turns the minutes since the last input into idle time; returns screenshots that are no longer needed.
    func markIdle(since: Int) -> [String] {
        let pending = "ts >= ? AND state = 'active' AND video = 0 AND label_source IS NULL"
        let shots = strings("SELECT shot FROM samples WHERE \(pending) AND shot IS NOT NULL", [since])
        exec("UPDATE samples SET state = 'idle', shot = NULL WHERE \(pending)", [since])
        return shots
    }
}

// MARK: Location (only "am I at one of my hide-the-widget places" is kept, never coordinates)

final class Locator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var nearPlace: String?

    /// The configured place you are at, if any; the widget hides there.
    var hiddenAt: String? { nearPlace ?? placeByWiFi() }

    func start() {
        // Location is only asked for when a place with coordinates is configured.
        guard cfg.hide_widget_at.contains(where: { $0.lat != nil && $0.lon != nil }) else { return }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 200
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { m.startUpdatingLocation() }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let here = locations.last else { return }
        nearPlace = cfg.hide_widget_at.first { place in
            guard let lat = place.lat, let lon = place.lon else { return false }
            return here.distance(from: CLLocation(latitude: lat, longitude: lon)) <= place.radius_m ?? 500
        }?.name
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}

    private func placeByWiFi() -> String? {
        guard let ssid = CWWiFiClient.shared().interface()?.ssid() else { return nil }
        return cfg.hide_widget_at.first { place in
            (place.ssid_contains ?? []).contains { ssid.localizedCaseInsensitiveContains($0) }
        }?.name
    }
}

// MARK: Sampler

final class Sampler {
    let db: DB
    var pausedUntil: Date?
    private var lastShotKey = ""
    private var lastShotAt = Date.distantPast

    init(db: DB) { self.db = db }

    var paused: Bool { (pausedUntil ?? .distantPast) > Date() }

    func tick() {
        if paused || screenLocked() || CGDisplayIsAsleep(CGMainDisplayID()) != 0 { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let now = Int(Date().timeIntervalSince1970)
        let bundle = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? bundle
        let window = frontWindow(pid: app.processIdentifier)
        var title = window?[kCGWindowName as String] as? String ?? ""
        let isPrivate = privateWindow(bundle: bundle, pid: app.processIdentifier)
        if isPrivate { title = "" }

        let idleSeconds = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: UInt32.max)!)
        let video = videoPlaying()
        let idle = idleSeconds >= cfg.idle_minutes * 60 && !video
        if idle {
            for path in db.markIdle(since: now - Int(idleSeconds)) { try? FileManager.default.removeItem(atPath: path) }
        }

        var shot: String?
        if !idle && !isPrivate && !cfg.no_screenshot_apps.contains(bundle) {
            let key = bundle + "|" + title
            if key != lastShotKey || Date().timeIntervalSince(lastShotAt) >= cfg.screenshot_every_minutes * 60 {
                shot = screenshot(ts: now, window: window)
                if shot != nil { lastShotKey = key; lastShotAt = Date() }
            }
        }

        db.exec("INSERT INTO samples(ts, app, bundle, title, state, video, private, shot) VALUES (?,?,?,?,?,?,?,?)",
                [now, name, bundle, title, idle ? "idle" : "active", video ? 1 : 0, isPrivate ? 1 : 0, shot])
    }

    private func screenLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func frontWindow(pid: pid_t) -> [String: Any]? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
    }

    /// With two monitors, the display that holds the front window's centre (the main display otherwise).
    private func displayBounds(of window: [String: Any]?) -> CGRect {
        var display = CGMainDisplayID()
        if let dict = window?[kCGWindowBounds as String] as? NSDictionary,
           let frame = CGRect(dictionaryRepresentation: dict) {
            var found: CGDirectDisplayID = 0
            var count: UInt32 = 0
            if CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &found, &count) == .success, count > 0 {
                display = found
            }
        }
        return CGDisplayBounds(display)
    }

    /// Incognito and private windows are never screenshotted and their titles are not stored.
    /// If the check itself fails (e.g. automation permission denied), the window is treated as private.
    private func privateWindow(bundle: String, pid: pid_t) -> Bool {
        switch bundle {
        case "com.google.Chrome":
            return appleScript("tell application id \"com.google.Chrome\" to return mode of front window") != "normal"
        case "com.apple.Safari":
            // Safari's scripting has no private flag, but its accessibility title for a private window
            // ends in ", Private Browsing" (the on-screen title does not).
            guard AXIsProcessTrusted() else { return true }
            var window: CFTypeRef?
            var title: CFTypeRef?
            let app = AXUIElementCreateApplication(pid)
            guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
                  let window,
                  AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success,
                  let title = title as? String else { return true }
            return title.hasSuffix("Private Browsing")
        default:
            return false
        }
    }

    /// A video or call keeps the display awake, so watching a lecture without touching the Mac is not idle.
    private func videoPlaying() -> Bool {
        let out = run("/usr/bin/pmset", ["-g", "assertions"])
        for line in out.split(separator: "\n") where line.contains("PreventUserIdleDisplaySleep") && line.contains("pid ") {
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: ")") else { continue }
            let owner = line[line.index(after: open)..<close]
            if !cfg.ignore_assertion_owners.contains(where: { owner.localizedCaseInsensitiveContains($0) }) { return true }
        }
        return false
    }

    private func screenshot(ts: Int, window: [String: Any]?) -> String? {
        let path = shotsDir.appendingPathComponent("\(ts).jpg").path
        let b = displayBounds(of: window)
        let rect = "\(Int(b.minX)),\(Int(b.minY)),\(Int(b.width)),\(Int(b.height))"
        run("/usr/sbin/screencapture", ["-x", "-R", rect, "-t", "jpg", path])
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        run("/usr/bin/sips", ["-Z", String(cfg.screenshot_max_px), "-s", "formatOptions", "70", path])
        return path
    }
}

// MARK: Widget

struct Summary: Decodable {
    struct Row: Decodable, Identifiable { let name: String; let color: String; let min: Int; var id: String { name } }
    let updated: String
    let focused_min: Int
    let active_min: Int
    let idle_min: Int
    let categories: [Row]
    let highlights: [String]
    let balance_note: String
    let checkin_text: String
}

final class SummaryStore: ObservableObject {
    @Published var summary: Summary?
    func reload() {
        guard let data = try? Data(contentsOf: dataDir.appendingPathComponent("summary.json")) else { return }
        summary = try? JSONDecoder().decode(Summary.self, from: data)
    }
}

func hm(_ minutes: Int) -> String { minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m" }

func swatch(_ name: String) -> Color {
    switch name {
    case "orange": return .orange
    case "blue": return .blue
    case "purple": return .purple
    case "green": return .green
    case "red": return .red
    case "pink": return .pink
    case "yellow": return .yellow
    case "teal": return .teal
    default: return .gray
    }
}

struct WidgetView: View {
    @ObservedObject var store: SummaryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s = store.summary {
                HStack {
                    Text("Today").font(.headline)
                    Spacer()
                    Text(s.updated).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hm(s.focused_min)).font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("focused").foregroundStyle(.secondary)
                }
                Text("\(hm(s.active_min)) on screen · \(hm(s.idle_min)) idle").font(.caption).foregroundStyle(.secondary)
                let top = Array(s.categories.prefix(5))
                let most = max(top.first?.min ?? 1, 1)
                ForEach(top) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(row.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text(hm(row.min)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        GeometryReader { g in
                            Capsule().fill(swatch(row.color))
                                .frame(width: max(4, g.size.width * CGFloat(row.min) / CGFloat(most)), height: 4)
                        }.frame(height: 4)
                    }
                }
                if !s.highlights.isEmpty {
                    Divider()
                    ForEach(s.highlights.prefix(3), id: \.self) { Text("• " + $0).font(.caption2).lineLimit(1) }
                }
                if !s.balance_note.isEmpty {
                    Divider()
                    Text(s.balance_note).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("StudyLens").font(.headline)
                Text("Collecting your first minutes…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 260, alignment: .leading)
    }
}

final class WidgetPanel: NSPanel {
    let hosting: NSHostingView<WidgetView>

    init(store: SummaryStore) {
        hosting = NSHostingView(rootView: WidgetView(store: store))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isMovableByWindowBackground = true

        let glass = NSVisualEffectView()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 16
        glass.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: glass.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
        ])
        contentView = glass

        if !setFrameUsingName("StudyLensWidget"), let screen = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: screen.maxX - 280, y: screen.maxY - 20))
        }
        setFrameAutosaveName("StudyLensWidget")
    }

    override var canBecomeKey: Bool { false }

    func fit() {
        var origin = NSPoint(x: frame.minX, y: frame.maxY)
        // Unplugging the second monitor can leave the widget off-screen; bring it back to the main one.
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }), let main = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: main.maxX - 280, y: main.maxY - 20)
        }
        let size = hosting.fittingSize
        setFrame(NSRect(x: origin.x, y: origin.y - size.height, width: size.width, height: size.height), display: true)
    }
}

// MARK: App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let db = DB()
    lazy var sampler = Sampler(db: db)
    let locator = Locator()
    let store = SummaryStore()
    lazy var panel = WidgetPanel(store: store)
    var statusItem: NSStatusItem!
    var showWidget = UserDefaults.standard.object(forKey: "showWidget") as? Bool ?? true

    func applicationDidFinishLaunching(_ note: Notification) {
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
        // Needed only to recognise Safari private windows; until granted, Safari is treated as private.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        try? SMAppService.mainApp.register()
        locator.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "book.closed", accessibilityDescription: "StudyLens")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refresh()
        Timer.scheduledTimer(withTimeInterval: cfg.sample_seconds, repeats: true) { [weak self] _ in
            self?.sampler.tick()
            self?.refresh()
            self?.maybeCheckin(force: false)
        }
        sampler.tick()
    }

    var missingPermissions: [String] {
        (CGPreflightScreenCaptureAccess() ? [] : ["Screen Recording"]) + (AXIsProcessTrusted() ? [] : ["Accessibility"])
    }

    func refresh() {
        let status = ["missing_permissions": missingPermissions, "checked": [ISO8601DateFormatter().string(from: Date())]]
        try? JSONSerialization.data(withJSONObject: status).write(to: dataDir.appendingPathComponent("status.json"))
        store.reload()
        if showWidget && locator.hiddenAt == nil {
            panel.fit()
            panel.orderFront(nil)
        } else {
            panel.orderOut(nil)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for missing in missingPermissions { menu.addItem(withTitle: "⚠️ \(missing) not allowed", action: nil, keyEquivalent: "") }
        if let place = locator.hiddenAt { menu.addItem(withTitle: "At \(place): widget hidden", action: nil, keyEquivalent: "") }
        let widget = menu.addItem(withTitle: "Show desktop widget", action: #selector(toggleWidget), keyEquivalent: "")
        widget.state = showWidget ? .on : .off
        if sampler.paused {
            menu.addItem(withTitle: "Resume tracking", action: #selector(resume), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Pause tracking for 1 hour", action: #selector(pause), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Weekend check-in…", action: #selector(checkinNow), keyEquivalent: "")
        menu.addItem(withTitle: "Open StudyLens folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit StudyLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc func toggleWidget() {
        showWidget.toggle()
        UserDefaults.standard.set(showWidget, forKey: "showWidget")
        refresh()
    }

    @objc func pause() { sampler.pausedUntil = Date().addingTimeInterval(3600) }
    @objc func resume() { sampler.pausedUntil = nil }
    @objc func checkinNow() { maybeCheckin(force: true) }
    @objc func openFolder() { NSWorkspace.shared.open(dataDir) }

    /// Once per weekend (Friday or Saturday evening by default): "what were you doing or learning?"
    func maybeCheckin(force: Bool) {
        let now = Date()
        let cal = Calendar.current
        let weekKey = "\(cal.component(.yearForWeekOfYear, from: now))-\(cal.component(.weekOfYear, from: now))"
        let defaults = UserDefaults.standard
        if !force {
            guard cfg.checkin.weekdays.contains(cal.component(.weekday, from: now)),
                  cal.component(.hour, from: now) >= cfg.checkin.hour,
                  defaults.string(forKey: "checkinWeek") != weekKey,
                  (defaults.object(forKey: "checkinSnooze") as? Date ?? .distantPast) < now,
                  locator.hiddenAt == nil else { return }
        }

        let alert = NSAlert()
        alert.messageText = "Weekend check-in"
        alert.informativeText = (store.summary?.checkin_text ?? "")
            + "\n\nWhat were you doing or learning this week? Courses, topics, anything the tracker might have missed."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 110))
        field.placeholderString = "e.g. Algorithms: Dijkstra and DP problems; two papers for my thesis; IELTS writing practice"
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field

        let saved = alert.runModal() == .alertFirstButtonReturn
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if saved && !text.isEmpty {
            db.exec("INSERT INTO checkins(ts, reply) VALUES (?, ?)", [Int(now.timeIntervalSince1970), text])
            defaults.set(weekKey, forKey: "checkinWeek")
            runAnalyzer("relabel")
        } else {
            defaults.set(now.addingTimeInterval(3600), forKey: "checkinSnooze")
        }
    }
}

/// `StudyLens --render-preview out.png` draws the widget with sample data (for the README and demos) and exits.
@MainActor func renderPreview(to path: String) {
    let store = SummaryStore()
    store.summary = Summary(
        updated: "18:40", focused_min: 312, active_min: 401, idle_min: 38,
        categories: [
            .init(name: "Course: Algorithms", color: "blue", min: 104),
            .init(name: "BCS Bangla", color: "orange", min: 72),
            .init(name: "Thesis writing", color: "purple", min: 66),
            .init(name: "Course: Linear Algebra", color: "blue", min: 40),
            .init(name: "Chat & social", color: "gray", min: 30),
        ],
        highlights: ["Algorithms · Dijkstra's shortest path (52m)", "BCS Bangla · সমাস (40m)", "Thesis · Landsat NDWI (38m)"],
        balance_note: "BCS behind this week: International Affairs, Geography",
        checkin_text: "")
    let card = WidgetView(store: store)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.13).opacity(0.92)))
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.42, green: 0.24, blue: 0.38)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    let view = NSHostingView(rootView: card)
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
