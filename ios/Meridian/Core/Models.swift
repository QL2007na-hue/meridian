//
//  Models.swift
//  Meridian — the data contract between the UI, the store and the server.
//
//  Everything here is Codable and transport-agnostic. The wire format is
//  documented in docs/API.md; this file is the single source of truth for it.
//

import Foundation

// MARK: - Task

/// One agenda item. `id` is stable across devices: the server issues a UUID and
/// the app keeps it, so a task completed on the iPad is completed on the phone.
struct AgendaTask: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var note: String
    /// Local calendar day, `yyyy-MM-dd`. The agenda is day-scoped: a clock on a
    /// wall answers "what is today", not "what is in the backlog".
    var day: String
    var due: Date?
    var priority: Priority
    var isDone: Bool
    var updatedAt: Date
    var origin: Origin
    var durationMinutes: Int?

    enum Priority: Int, Codable, CaseIterable, Hashable {
        case normal = 0
        case notable = 1
        case critical = 2
    }

    enum Origin: String, Codable, Hashable {
        case local
        case remote
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        note: String = "",
        day: String = DayKey.today(),
        due: Date? = nil,
        priority: Priority = .normal,
        isDone: Bool = false,
        updatedAt: Date = Date(),
        origin: Origin = .local,
        durationMinutes: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.day = day
        self.due = due
        self.priority = priority
        self.isDone = isDone
        self.updatedAt = updatedAt
        self.origin = origin
        self.durationMinutes = durationMinutes
    }

    /// Display order inside a day: open before done, then by due time, then by
    /// priority, then by insertion.
    static func ordered(_ a: AgendaTask, _ b: AgendaTask) -> Bool {
        if a.isDone != b.isDone { return !a.isDone }
        switch (a.due, b.due) {
        case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
        case (nil, _?): return false
        case (_?, nil): return true
        default: break
        }
        if a.priority.rawValue != b.priority.rawValue {
            return a.priority.rawValue > b.priority.rawValue
        }
        return a.updatedAt > b.updatedAt
    }
}

// MARK: - Server

struct ServerConfig: Codable, Equatable {
    /// e.g. `http://192.168.1.10:8787` or `https://clock.example.com`.
    var baseURL: String = ""
    var token: String = ""
    /// Seconds between background polls. The SSE stream does the realtime work;
    /// polling is the safety net for networks that eat long-lived connections.
    var syncInterval: Double = 90
    var autoSync: Bool = true

    var endpoint: URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Accept what a human types: `192.168.1.10/meridian`, `http://host:8787/`,
        // `https://host`. A missing scheme used to produce a scheme-less URL that
        // URLSession refuses with an "unsupported URL" nobody can see.
        let lower = trimmed.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: trimmed)
    }

    var isConfigured: Bool { endpoint != nil }

    /// Tolerant decoding: a stored state file written by an older build must
    /// keep loading when fields are added, otherwise the user loses a day of
    /// agenda on upgrade.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = (try? c.decodeIfPresent(String.self, forKey: .baseURL)) ?? ""
        token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? ""
        syncInterval = (try? c.decodeIfPresent(Double.self, forKey: .syncInterval)) ?? 90
        autoSync = (try? c.decodeIfPresent(Bool.self, forKey: .autoSync)) ?? true
    }
}

// MARK: - Sync

enum SyncPhase: Equatable {
    case idle
    case syncing
    case live(Date)
    case polling(Date)
    case offline
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "未连接"
        case .syncing: return "同步中"
        case .live: return "已连接"
        case .polling: return "已连接"
        case .offline: return "离线"
        case .failed: return "异常"
        }
    }

    var isConnected: Bool {
        switch self {
        case .live, .polling, .syncing: return true
        default: return false
        }
    }
}

// MARK: - Settings

struct AppSettings: Codable, Equatable {
    var use24Hour: Bool = true
    var showSeconds: Bool = true
    var showSecondRing: Bool = true
    var showLunar: Bool = true
    var clockStyle: ClockStyle = .stacked
    /// After dusk the canvas drops a stop in brightness and the chrome recedes.
    var dimAtNight: Bool = true
    var nightStartHour: Int = 23
    var nightEndHour: Int = 7
    /// Slow 1px drift so a panel left on for a week does not burn in.
    var burnInDrift: Bool = true
    var keepAwake: Bool = true
    /// Accept the server's self-signed certificate (https://<ip>). On by default
    /// because a personal server reached by IP has no other usable certificate,
    /// and every extra iPad would otherwise need a CA profile installed.
    var allowSelfSignedCertificates: Bool = true
    /// Ambient-light adaptation: dim the canvas as the room darkens. The reading
    /// comes from the screen backlight by default (free); `ambientPrecise` adds
    /// short camera probes on top, because a permanently open camera costs real
    /// battery on a device that is on all day.
    var ambientAdaptive: Bool = false
    /// Use the front camera for a few hundred milliseconds every half minute
    /// instead of relying on the screen backlight alone.
    var ambientPrecise: Bool = false
    /// Background treatment behind the clock. Independent of the skin: the skin
    /// colours the numerals, the background colours the room.
    var background: BackgroundStyle = .graphite
    /// 0 = barely there, 1 = the gradient is the point.
    var backgroundIntensity: Double = 0.55
    /// Hue rotation applied to the background wash, in turns (-0.5...0.5).
    var backgroundHueShift: Double = 0
    /// The whole look of the clock. See Core/Skin.swift for the presets.
    var skin: ClockSkin = ClockSkin.graphite

    /// A background is a shape plus the two knobs worth exposing: how strong it
    /// is, and which way its colour leans.
    enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
        case graphite
        case aurora
        case vignette
        case gradient
        case grid
        case flat

        var id: String { rawValue }

        var label: String {
            switch self {
            case .graphite: return "石墨"
            case .aurora: return "极光"
            case .vignette: return "暗角"
            case .gradient: return "渐变"
            case .grid: return "细网格"
            case .flat: return "纯色"
            }
        }

        var detail: String {
            switch self {
            case .graphite: return "一点暖光 + 地平线，默认"
            case .aurora: return "两层冷色辉光缓慢呼吸"
            case .vignette: return "中心亮、四角暗，聚焦时间"
            case .gradient: return "自上而下的单色渐变"
            case .grid: return "极淡的 1px 网格，像工程纸"
            case .flat: return "只有底色，最省电"
            }
        }
    }

    enum ClockStyle: String, Codable, CaseIterable, Identifiable {
        case stacked   // date above, huge time below
        case inline    // date and time on one baseline
        case minimal   // time only

        var id: String { rawValue }

        var label: String {
            switch self {
            case .stacked: return "层叠"
            case .inline: return "并排"
            case .minimal: return "极简"
            }
        }
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        use24Hour = (try? c.decodeIfPresent(Bool.self, forKey: .use24Hour)) ?? true
        showSeconds = (try? c.decodeIfPresent(Bool.self, forKey: .showSeconds)) ?? true
        showSecondRing = (try? c.decodeIfPresent(Bool.self, forKey: .showSecondRing)) ?? true
        showLunar = (try? c.decodeIfPresent(Bool.self, forKey: .showLunar)) ?? true
        clockStyle = (try? c.decodeIfPresent(ClockStyle.self, forKey: .clockStyle)) ?? .stacked
        dimAtNight = (try? c.decodeIfPresent(Bool.self, forKey: .dimAtNight)) ?? true
        nightStartHour = (try? c.decodeIfPresent(Int.self, forKey: .nightStartHour)) ?? 23
        nightEndHour = (try? c.decodeIfPresent(Int.self, forKey: .nightEndHour)) ?? 7
        burnInDrift = (try? c.decodeIfPresent(Bool.self, forKey: .burnInDrift)) ?? true
        keepAwake = (try? c.decodeIfPresent(Bool.self, forKey: .keepAwake)) ?? true
        allowSelfSignedCertificates = (try? c.decodeIfPresent(Bool.self, forKey: .allowSelfSignedCertificates)) ?? true
        ambientAdaptive = (try? c.decodeIfPresent(Bool.self, forKey: .ambientAdaptive)) ?? false
        ambientPrecise = (try? c.decodeIfPresent(Bool.self, forKey: .ambientPrecise)) ?? false
        background = (try? c.decodeIfPresent(BackgroundStyle.self, forKey: .background)) ?? .graphite
        backgroundIntensity = (try? c.decodeIfPresent(Double.self, forKey: .backgroundIntensity)) ?? 0.55
        backgroundHueShift = (try? c.decodeIfPresent(Double.self, forKey: .backgroundHueShift)) ?? 0
        skin = (try? c.decodeIfPresent(ClockSkin.self, forKey: .skin)) ?? ClockSkin.graphite
    }
}

// MARK: - Panels

enum PanelID: String, CaseIterable, Identifiable, Codable {
    case agenda
    case next
    case focus
    case world
    case server

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agenda: return "今日"
        case .next: return "接下来"
        case .focus: return "专注"
        case .world: return "世界时钟"
        case .server: return "服务器"
        }
    }

    var symbol: String {
        switch self {
        case .agenda: return "checklist"
        case .next: return "arrow.turn.down.right"
        case .focus: return "timer"
        case .world: return "globe.asia.australia"
        case .server: return "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Focus
struct FocusSession: Codable, Equatable {
    var startedAt: Date
    var minutes: Int
    var label: String

    var endsAt: Date { startedAt.addingTimeInterval(Double(minutes) * 60) }

    func remaining(at now: Date) -> TimeInterval {
        max(0, endsAt.timeIntervalSince(now))
    }

    var isFinished: Bool { remaining(at: Date()) == 0 }
}

// MARK: - Day key helpers

/// Day keys are always local-calendar, always `yyyy-MM-dd`, always POSIX —
/// never the device locale. Two devices in different locales must produce the
/// same key for the same day or the sync will duplicate tasks.
enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }

    static func today() -> String {
        formatter.string(from: Date())
    }

    static func date(from key: String) -> Date? {
        formatter.date(from: key)
    }

    static func tomorrow() -> String {
        string(from: Date().addingTimeInterval(86_400))
    }

    static func shift(_ key: String, byDays days: Int) -> String {
        guard let d = date(from: key) else { return key }
        return string(from: d.addingTimeInterval(Double(days) * 86_400))
    }
}

// MARK: - Wire format

/// The full server snapshot. One request, one atomic picture — cheaper than
/// three round trips when a screen refreshes every 90 seconds all day.
struct SnapshotPayload: Codable {
    var serverTime: Date
    var rev: Int
    var tasks: [AgendaTask]
    var message: String?
    var weather: WeatherNote?
}

struct WeatherNote: Codable, Hashable {
    var text: String
    var celsius: Int?
}

/// Body sent when the iPad changes a task. The server merges by `updatedAt`;
/// last writer wins, and the client never sends a field it did not touch.
struct TaskMutation: Codable {
    var id: String
    var title: String?
    var note: String?
    var day: String?
    var due: Date?
    var priority: Int?
    var isDone: Bool?
    var updatedAt: Date
    var deleted: Bool?
}

// MARK: - Alerts

/// What the user did with a due-task reminder.
enum TaskAlertAction {
    case done
    case snooze
    case dismiss
}
