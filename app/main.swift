// StudyLens: samples what is on screen once a minute, shows a desktop widget, and asks for a weekend check-in.
// The analyzer (Python, run by launchd) labels the samples with a local Ollama vision model.
import AppKit
import Charts
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
CREATE TABLE IF NOT EXISTS user_rules(key TEXT PRIMARY KEY, category TEXT NOT NULL);
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

    func rows(_ sql: String, _ args: [Any?] = []) -> [[String]] {
        let st = prepare(sql, args)
        var out: [[String]] = []
        while sqlite3_step(st) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(st)).map { i in
                sqlite3_column_text(st, i).map { String(cString: $0) } ?? ""
            })
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
    // Screen Time-style chart data (optional so an older summary.json still loads).
    struct Series: Decodable { let name: String; let color: String }
    struct Point: Decodable, Identifiable { let x: String; let sort: Int; let series: String; let min: Int; var id: String { x + "|" + series } }
    let entertainment_min: Int?
    let series: [Series]?
    let hourly: [Point]?
    let daily: [Point]?
    let today_totals: [Row]?
    let week_totals: [Row]?
}

/// Colors for the chart, in stacking order, so every chart and legend agrees.
func seriesScale(_ s: Summary) -> (domain: [String], range: [Color]) {
    let series = s.series ?? []
    return (series.map(\.name), series.map { swatch($0.color) })
}

func hourLabel(_ h: Int) -> String { h == 0 ? "12 AM" : h == 12 ? "12 PM" : h < 12 ? "\(h) AM" : "\(h - 12) PM" }

/// Bars per hour of the day, stacked by subject group, like Screen Time.
struct HourlyChart: View {
    let summary: Summary
    var compact = true
    var highlight: String? = nil

    var body: some View {
        let scale = seriesScale(summary)
        let peak = Dictionary(grouping: summary.hourly ?? [], by: \.sort).values.map { $0.reduce(0) { $0 + $1.min } }.max() ?? 0
        Chart(summary.hourly ?? []) { p in
            BarMark(x: .value("Hour", p.sort), y: .value("Minutes", p.min), width: .fixed(compact ? 6 : 14))
                .foregroundStyle(by: .value("Series", p.series))
                .opacity(highlight == nil || highlight == p.series ? 1 : 0.18)
        }
        .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
        .chartXScale(domain: -0.5...23.5)
        .chartYScale(domain: 0...max(60, peak))
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { v in
                AxisGridLine()
                AxisValueLabel { Text(hourLabel(v.as(Int.self) ?? 0)).font(compact ? .system(size: 8) : .caption) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, 30, 60]) { v in
                AxisGridLine()
                AxisValueLabel { Text("\(v.as(Int.self) ?? 0)m").font(compact ? .system(size: 8) : .caption) }
            }
        }
        .chartLegend(.hidden)
    }
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
    case "brown": return .brown
    case "idle": return Color.gray.opacity(0.35)
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
                Text("\(hm(s.active_min)) on screen · \(hm(s.idle_min)) idle · \(hm(s.entertainment_min ?? 0)) entertainment")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                if !(s.hourly ?? []).isEmpty {
                    HourlyChart(summary: s).frame(height: 78)
                }
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
        .frame(width: 280, alignment: .leading)
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

    /// Resizes to the content and keeps the whole widget on the screen its top edge is on (the main screen if that
    /// screen is gone), so growing content, a drag to the other monitor or unplugging it never leaves part of it off-screen.
    func fit() {
        if NSEvent.pressedMouseButtons != 0 { return }  // the user is dragging it; don't fight the drag
        let size = hosting.fittingSize
        let anchor = NSPoint(x: frame.midX, y: frame.maxY - 1)
        let current = NSScreen.screens.first { $0.frame.contains(anchor) }
        guard let screen = (current ?? NSScreen.main)?.visibleFrame else { return }
        var left = frame.minX
        var top = frame.maxY
        if current == nil {  // its monitor was unplugged: back to the top-right of the main screen
            left = screen.maxX - size.width - 20
            top = screen.maxY - 20
        }
        left = min(max(left, screen.minX + 8), screen.maxX - size.width - 8)
        top = min(max(top, screen.minY + size.height + 8), screen.maxY - 8)
        setFrame(NSRect(x: left, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Desktop level sits under your windows like Apple's widgets; "on top" floats above them.
    func applyLevel(onTop: Bool) {
        level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
}

// MARK: Subjects & labels window

/// Edits subjects in config.json and the labels of recent minutes, so nobody has to touch the JSON.
final class ManageModel: ObservableObject {
    struct Category: Identifiable { let id = UUID(); var original: String?; var name: String; var hint: String; var extra: [String: Any] }
    struct Group: Identifiable { let id = UUID(); var original: String?; var name: String; var color: String; var categories: [Category] }
    struct Block: Identifiable {
        let bundle, app, title, topic, category: String
        let minutes: Int
        var id: String { bundle + "|" + title + "|" + topic + "|" + category }
        /// A title that names one thing (a file, a page), unlike "Claude" or "New Tab" that cover anything.
        var specificTitle: Bool { !title.isEmpty && title != app && !["New Tab", "Untitled", "Start Page", "Favorites"].contains(title) }
        /// What you were doing: the window's own title when it names the thing, otherwise the topic, never just the app.
        var name: String { specificTitle ? title : (topic.isEmpty ? app : topic) }
        var detail: String { [app, specificTitle ? topic : "", hm(minutes)].filter { !$0.isEmpty }.joined(separator: " · ") }
    }

    @Published var groups: [Group] = []
    @Published var blocks: [Block] = []
    @Published var days = 1 { didSet { loadBlocks() } }
    @Published var status = ""
    @Published var describe = ""
    @Published var suggesting = false

    private let db: DB
    private var config: [String: Any] = [:]
    private let configURL = dataDir.appendingPathComponent("config.json")
    private let palette = ["blue", "orange", "purple", "green", "pink", "teal", "yellow", "red"]

    var categoryNames: [String] { groups.flatMap { $0.categories.map(\.name) } }

    init(db: DB) {
        self.db = db
        reload()
    }

    func reload() {
        loadConfig()
        loadBlocks()
        status = ""
    }

    private func loadConfig() {
        guard let data = try? Data(contentsOf: configURL),
              let c = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        config = c
        groups = (c["groups"] as? [[String: Any]] ?? []).map { g in
            Group(original: g["name"] as? String, name: g["name"] as? String ?? "", color: g["color"] as? String ?? "gray",
                  categories: (g["categories"] as? [[String: Any]] ?? []).map { cat in
                      Category(original: cat["name"] as? String, name: cat["name"] as? String ?? "",
                               hint: cat["hint"] as? String ?? "", extra: cat)
                  })
        }
    }

    private func since() -> Int { Int(Date().timeIntervalSince1970) - days * 86400 }

    func loadBlocks() {
        blocks = db.rows("""
            SELECT bundle, app, title, category, MAX(IFNULL(topic, '')), COUNT(*) FROM samples
            WHERE ts >= ? AND state = 'active' AND private = 0 AND category IS NOT NULL
              AND category NOT IN ('Idle', 'Private browsing')
            GROUP BY bundle, title, category,
                     CASE WHEN title IN ('', 'New Tab', 'Untitled', 'Start Page', 'Favorites') OR title = app
                          THEN IFNULL(topic, '') ELSE '' END
            ORDER BY MAX(ts) DESC LIMIT 150
            """, [since()]).map {
            Block(bundle: $0[0], app: $0[1], title: $0[2], topic: $0[4], category: $0[3], minutes: Int($0[5]) ?? 0)
        }
    }

    /// Re-labels these minutes and remembers the choice: for the window when its title is specific, and for the
    /// topic always, so the AI's future labels with that topic follow it. The topic also becomes an example in the prompt.
    func relabel(_ b: Block, to category: String) {
        guard category != b.category else { return }
        let created = !categoryNames.contains(category)
        if created { addSubject(category, near: b.category) }
        if b.specificTitle {  // one window, one label: all of its minutes, whatever they were labeled before
            db.exec("UPDATE samples SET category = ?, label_source = 'you' WHERE bundle = ? AND title = ?",
                    [category, b.bundle, b.title])
        } else {
            db.exec("UPDATE samples SET category = ?, label_source = 'you' WHERE bundle = ? AND title = ? AND lower(IFNULL(topic, '')) = ?",
                    [category, b.bundle, b.title, b.topic.lowercased()])
        }
        if b.specificTitle {
            db.exec("INSERT OR REPLACE INTO user_rules(key, category) VALUES (?, ?)", [b.bundle + "|" + b.title, category])
            db.exec("DELETE FROM title_cache WHERE key = ?", [b.bundle + "|" + b.title])
        }
        if !b.topic.isEmpty {
            db.exec("INSERT OR REPLACE INTO user_rules(key, category) VALUES (?, ?)", ["topic|" + b.topic.lowercased(), category])
            addExample(b.topic, to: category)
        }
        loadBlocks()
        let what = b.name
        status = "“\(what)” is now \(category), and will be from now on."
            + (created ? " New subject “\(category)” added; describe it in the Subjects tab to help the AI." : "")
        runAnalyzer("analyze")
    }

    /// A subject typed in Recent activity: goes into the same study group as the label it replaces,
    /// or into "Added by me" when that label was outside your study groups.
    private func addSubject(_ name: String, near current: String) {
        var saved = config["groups"] as? [[String: Any]] ?? []
        var focus = config["focus_groups"] as? [String] ?? []
        let mine = "Added by me"
        func contains(_ g: [String: Any], _ n: String) -> Bool {
            (g["categories"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == n }
        }
        var gi = saved.firstIndex { focus.contains($0["name"] as? String ?? "") && contains($0, current) }
        if gi == nil { gi = saved.firstIndex { $0["name"] as? String == mine } }
        if gi == nil {
            let used = Set(saved.compactMap { $0["color"] as? String })
            let at = max(0, saved.count - 1)  // before "Other"
            saved.insert(["name": mine, "color": palette.first { !used.contains($0) } ?? "blue", "categories": []], at: at)
            focus.append(mine)
            gi = at
        }
        var cats = saved[gi!]["categories"] as? [[String: Any]] ?? []
        cats.append(["name": name, "hint": ""])
        saved[gi!]["categories"] = cats
        config["groups"] = saved
        config["focus_groups"] = focus
        writeConfig()
        loadConfig()
    }

    private func addExample(_ topic: String, to category: String) {
        var saved = config["groups"] as? [[String: Any]] ?? []
        for gi in saved.indices {
            var cats = saved[gi]["categories"] as? [[String: Any]] ?? []
            for ci in cats.indices where cats[ci]["name"] as? String == category {
                var examples = cats[ci]["examples"] as? [String] ?? []
                if !examples.contains(topic) { examples.append(topic) }
                cats[ci]["examples"] = Array(examples.suffix(8))
            }
            saved[gi]["categories"] = cats
        }
        config["groups"] = saved
        writeConfig()
        // Keep unsaved edits in the Subjects tab, but carry the new examples along.
        for gi in groups.indices {
            for ci in groups[gi].categories.indices where groups[gi].categories[ci].original == category {
                let fresh = saved.flatMap { $0["categories"] as? [[String: Any]] ?? [] }.first { $0["name"] as? String == category }
                groups[gi].categories[ci].extra["examples"] = fresh?["examples"]
            }
        }
    }

    func addGroup() {
        let used = Set(groups.map(\.color))
        let color = palette.first { !used.contains($0) } ?? "blue"
        groups.insert(Group(original: nil, name: "New group", color: color, categories: [Category(original: nil, name: "", hint: "", extra: [:])]),
                      at: max(0, groups.count - 1))
    }

    func remove(_ id: UUID) {
        for gi in groups.indices { groups[gi].categories.removeAll { $0.id == id } }
    }

    func suggest() {
        let text = describe.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !suggesting else { return }
        suggesting = true
        status = "Asking the local AI…"
        DispatchQueue.global().async {
            let out = run(uvPath, ["run", "--project", analyzerDir.path, "--frozen", "--quiet", "studylens", "suggest", text])
            DispatchQueue.main.async {
                self.suggesting = false
                guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: String],
                      let name = json["name"], let group = json["group"] else {
                    self.status = "The AI couldn't suggest a subject. Is Ollama running?"
                    return
                }
                let category = Category(original: nil, name: name, hint: json["hint"] ?? "", extra: [:])
                if let gi = self.groups.firstIndex(where: { $0.name == group }) {
                    self.groups[gi].categories.append(category)
                } else {
                    self.addGroup()
                    let gi = max(0, self.groups.count - 2)
                    self.groups[gi].name = group
                    self.groups[gi].categories = [category]
                }
                self.describe = ""
                self.status = "Added “\(name)” to \(group). Check it, then press Save."
            }
        }
    }

    func save() {
        for gi in groups.indices {
            groups[gi].name = groups[gi].name.trimmingCharacters(in: .whitespaces)
            for ci in groups[gi].categories.indices {
                groups[gi].categories[ci].name = groups[gi].categories[ci].name.trimmingCharacters(in: .whitespaces)
            }
        }
        let names = categoryNames
        guard !names.contains(""), Set(names).count == names.count else { status = "Every subject needs its own name."; return }
        guard names.contains("Other") else { status = "Keep the “Other” subject; unclear time goes there."; return }
        guard !groups.contains(where: { $0.name.isEmpty }) else { status = "Every group needs a name."; return }

        // Past minutes follow renamed subjects; minutes of deleted subjects become Other.
        let before = Set((config["groups"] as? [[String: Any]] ?? []).flatMap { ($0["categories"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String } })
        let kept = Set(groups.flatMap { $0.categories.compactMap(\.original) })
        for g in groups {
            for c in g.categories {
                guard let old = c.original, old != c.name else { continue }
                db.exec("UPDATE samples SET category = ? WHERE category = ?", [c.name, old])
                db.exec("UPDATE user_rules SET category = ? WHERE category = ?", [c.name, old])
                db.exec("DELETE FROM title_cache WHERE category = ?", [old])
            }
        }
        for gone in before.subtracting(kept) {
            db.exec("UPDATE samples SET category = 'Other' WHERE category = ?", [gone])
            db.exec("DELETE FROM user_rules WHERE category = ?", [gone])
            db.exec("DELETE FROM title_cache WHERE category = ?", [gone])
        }

        var focus = config["focus_groups"] as? [String] ?? []
        for g in groups {
            if let old = g.original, old != g.name { focus = focus.map { $0 == old ? g.name : $0 } }
            if g.original == nil && g.name != "Other" && !focus.contains(g.name) { focus.append(g.name) }
        }
        let live = groups.filter { !$0.categories.isEmpty }
        config["focus_groups"] = focus.filter { f in live.contains { $0.name == f } }
        // The weighted "balance" group (e.g. exam subjects by marks) follows a rename and is dropped with its group.
        if var balance = config["balance_group"] as? String {
            if let renamed = groups.first(where: { $0.original == balance }) { balance = renamed.name }
            config["balance_group"] = live.contains { $0.name == balance } ? balance : NSNull()
        }
        config["groups"] = live.map { g -> [String: Any] in
            ["name": g.name, "color": g.color, "categories": g.categories.map { c -> [String: Any] in
                var d = c.extra
                d["name"] = c.name
                d["hint"] = c.hint
                return d
            }]
        }
        writeConfig()
        loadConfig()
        loadBlocks()
        status = "Saved. New minutes use these subjects from now on."
        runAnalyzer("analyze")
    }

    private func writeConfig() {
        let backup = dataDir.appendingPathComponent("config.backup.json")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: configURL, to: backup)
        if let data = try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? data.write(to: configURL, options: .atomic)
        }
    }
}

/// Screen Time-style overview: today by hour or the last 7 days by day, with totals per group and distraction.
struct OverviewTab: View {
    @ObservedObject var store: SummaryStore
    @State private var week = false
    @State private var hovered: String?  // a breakdown row under the pointer; the charts spotlight it

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = store.summary, s.series != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(week ? "Last 7 days" : "Today").font(.headline).foregroundStyle(.secondary)
                        let total = (week ? s.week_totals : s.today_totals) ?? []
                        Text(hm(total.filter { $0.name != "Idle" }.reduce(0) { $0 + $1.min })).font(.system(size: 30, weight: .semibold, design: .rounded))
                        Text("on screen, \(hm(total.first { $0.name == "Idle" }?.min ?? 0)) idle").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $week) {
                        Text("Today").tag(false)
                        Text("Last 7 days").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 220)
                }
                let scale = seriesScale(s)
                if week {
                    Chart(s.daily ?? []) { p in
                        BarMark(x: .value("Day", p.x), y: .value("Hours", Double(p.min) / 60))
                            .foregroundStyle(by: .value("Series", p.series))
                            .opacity(hovered == nil || hovered == p.series ? 1 : 0.18)
                    }
                    .chartForegroundStyleScale(domain: scale.domain, range: scale.range)
                    .chartYAxis { AxisMarks(position: .trailing) { v in AxisGridLine(); AxisValueLabel { Text("\(v.as(Double.self) ?? 0, specifier: "%.0f")h") } } }
                    .chartLegend(.hidden)
                    .frame(height: 240)
                } else {
                    HourlyChart(summary: s, compact: false, highlight: hovered).frame(height: 240)
                }
                Divider()
                let rows = (week ? s.week_totals : s.today_totals) ?? []
                let most = max(rows.map(\.min).max() ?? 1, 1)
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows) { r in
                            let on = hovered == r.name
                            HStack(spacing: 10) {
                                Circle().fill(swatch(r.color)).frame(width: on ? 12 : 10, height: on ? 12 : 10)
                                Text(r.name).fontWeight(on ? .semibold : .regular).frame(width: 190, alignment: .leading)
                                GeometryReader { g in
                                    Capsule().fill(swatch(r.color)).frame(width: max(4, g.size.width * CGFloat(r.min) / CGFloat(most)), height: on ? 9 : 6)
                                        .frame(maxHeight: .infinity)
                                }
                                Text(hm(r.min)).monospacedDigit().foregroundStyle(on ? .primary : .secondary).frame(width: 70, alignment: .trailing)
                            }
                            .frame(height: 18)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 8).fill(on ? swatch(r.color).opacity(0.15) : .clear))
                            .scaleEffect(on ? 1.025 : 1, anchor: .leading)
                            .opacity(hovered == nil || on ? 1 : 0.55)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                withAnimation(.easeOut(duration: 0.15)) { hovered = inside ? r.name : (hovered == r.name ? nil : hovered) }
                            }
                        }
                    }
                }
            } else {
                Text("The chart appears after the next analysis (within 10 minutes).")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }
}

struct ManageView: View {
    @ObservedObject var model: ManageModel
    @ObservedObject var store: SummaryStore

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                OverviewTab(store: store).tabItem { Text("Overview") }
                ActivityTab(model: model).tabItem { Text("Recent activity") }
                SubjectsTab(model: model).tabItem { Text("Subjects") }
            }
            if !model.status.isEmpty {
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .padding(.top, 10)
        .frame(minWidth: 780, minHeight: 560)
    }
}

struct ActivityTab: View {
    @ObservedObject var model: ManageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wrong subject? Pick the right one. StudyLens re-labels that time, uses it for that window from now on, and learns from the example.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Picker("", selection: $model.days) {
                    Text("Last 24 hours").tag(1)
                    Text("Last 7 days").tag(7)
                }
                .pickerStyle(.segmented).frame(width: 220)
            }
            if model.blocks.isEmpty {
                Text("Nothing labeled yet. Labels appear about 10 minutes after you work on something.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.blocks) { b in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(b.name).lineLimit(1)
                            Text(b.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        SubjectBox(value: b.category, options: model.categoryNames) { model.relabel(b, to: $0) }
                            .frame(width: 240)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding()
    }
}

/// Pick a subject or type one: it autocompletes from your subjects, and a name that doesn't exist yet is created.
struct SubjectBox: NSViewRepresentable {
    let value: String
    let options: [String]
    let onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.completes = true
        box.numberOfVisibleItems = 14
        box.delegate = context.coordinator
        box.target = context.coordinator
        box.action = #selector(Coordinator.entered(_:))
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        guard box.currentEditor() == nil else { return }  // don't overwrite what the user is typing
        box.removeAllItems()
        box.addItems(withObjectValues: options)
        box.stringValue = value
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: SubjectBox
        init(_ parent: SubjectBox) { self.parent = parent }

        @objc func entered(_ box: NSComboBox) { commit(box.stringValue) }

        func comboBoxSelectionDidChange(_ note: Notification) {
            guard let box = note.object as? NSComboBox, box.indexOfSelectedItem >= 0,
                  let picked = box.itemObjectValue(at: box.indexOfSelectedItem) as? String else { return }
            commit(picked)
        }

        func controlTextDidEndEditing(_ note: Notification) {
            if let box = note.object as? NSComboBox { commit(box.stringValue) }
        }

        private func commit(_ text: String) {
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Typing a different case of an existing subject means that subject.
            let match = parent.options.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            guard !match.isEmpty, match != parent.value else { return }
            parent.onCommit(match)
        }
    }
}

struct SubjectsTab: View {
    @ObservedObject var model: ManageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Describe something new to track, e.g. “rickshaw battery project” or “IELTS writing”", text: $model.describe)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.suggest() }
                Button(model.suggesting ? "Thinking…" : "Add with AI") { model.suggest() }
                    .disabled(model.suggesting || model.describe.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach($model.groups) { $group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Circle().fill(swatch(group.color)).frame(width: 10, height: 10)
                                TextField("Group name", text: $group.name).font(.headline).textFieldStyle(.plain)
                            }
                            ForEach($group.categories) { $category in
                                HStack {
                                    TextField("Subject", text: $category.name).textFieldStyle(.roundedBorder).frame(width: 210)
                                    TextField("What it looks like on screen: topics, books, websites, tools", text: $category.hint)
                                        .textFieldStyle(.roundedBorder)
                                    Button { model.remove(category.id) } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless)
                                        .disabled(category.name == "Other")
                                        .help("Delete this subject; its past minutes become Other")
                                }
                            }
                            Button("+ Add subject") {
                                group.categories.append(.init(original: nil, name: "", hint: "", extra: [:]))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    Button("+ New group") { model.addGroup() }.buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
            HStack {
                Spacer()
                Button("Undo changes") { model.reload() }
                Button("Save") { model.save() }.keyboardShortcut("s").buttonStyle(.borderedProminent)
            }
        }
        .padding()
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
    var widgetOnTop = UserDefaults.standard.bool(forKey: "widgetOnTop")
    lazy var manageModel = ManageModel(db: db)
    var manageWindow: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        // A menu-bar app has no menus of its own; this Edit menu makes ⌘C/⌘V/⌘Z work in its text fields.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(NSMenuItem())
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
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
        if CommandLine.arguments.contains("--manage") { openManage() }
        panel.applyLevel(onTop: widgetOnTop)
        // Plugging in or removing a monitor moves the widget back onto a screen right away.
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
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
        let onTop = menu.addItem(withTitle: "Keep widget above windows", action: #selector(toggleOnTop), keyEquivalent: "")
        onTop.state = widgetOnTop ? .on : .off
        if sampler.paused {
            menu.addItem(withTitle: "Resume tracking", action: #selector(resume), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Pause tracking for 1 hour", action: #selector(pause), keyEquivalent: "")
        }
        menu.addItem(withTitle: "Subjects & labels…", action: #selector(openManage), keyEquivalent: "")
        menu.addItem(withTitle: "Weekend check-in…", action: #selector(checkinNow), keyEquivalent: "")
        menu.addItem(withTitle: "Open StudyLens folder", action: #selector(openFolder), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit StudyLens", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
    }

    @objc func toggleOnTop() {
        widgetOnTop.toggle()
        UserDefaults.standard.set(widgetOnTop, forKey: "widgetOnTop")
        panel.applyLevel(onTop: widgetOnTop)
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

    @objc func openManage() {
        if manageWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "StudyLens: Subjects & labels"
            window.contentView = NSHostingView(rootView: ManageView(model: manageModel, store: store))
            window.isReleasedWhenClosed = false
            window.center()
            manageWindow = window
        } else {
            manageModel.reload()
        }
        NSApp.activate(ignoringOtherApps: true)
        manageWindow?.makeKeyAndOrderFront(nil)
    }

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
        checkin_text: "",
        entertainment_min: 26,
        series: [.init(name: "University", color: "blue"), .init(name: "BCS", color: "orange"),
                 .init(name: "Thesis", color: "purple"), .init(name: "Chat & social", color: "pink"),
                 .init(name: "Entertainment", color: "red"), .init(name: "Idle", color: "idle")],
        hourly: [(8, "University", 25), (9, "University", 48), (10, "BCS", 40), (10, "Chat & social", 8), (11, "BCS", 32),
                 (11, "Idle", 12), (13, "Thesis", 35), (14, "Thesis", 31), (14, "Entertainment", 14), (16, "University", 31),
                 (17, "Chat & social", 12), (17, "Entertainment", 12), (18, "Idle", 26)]
            .map { Summary.Point(x: String($0.0), sort: $0.0, series: $0.1, min: $0.2) },
        daily: [], today_totals: [], week_totals: [])
    let card = WidgetView(store: store)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.13).opacity(0.92)))
        .padding(28)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.42, green: 0.24, blue: 0.38)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    let view = NSHostingView(rootView: card)
    view.frame = NSRect(origin: .zero, size: view.fittingSize)
    // Charts lay out asynchronously: host the view in an offscreen window and let the run loop turn briefly.
    let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: view.frame.width, height: view.frame.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
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
