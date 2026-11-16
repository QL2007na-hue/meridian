//
//  AppModel.swift
//  Meridian — the single observable store.
//
//  Owns: the agenda, the settings, the server config, the focus session and
//  the immersive (chrome-less) state. Nothing in the view layer mutates these
//  directly; every mutation goes through a method here so persistence and sync
//  see it.
//
//  Sync lives in Sync/AppModel+Sync.swift (a teammate owns that file).
//

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {

    // MARK: Published state

    @Published var tasks: [AgendaTask] = []
    @Published var settings: AppSettings = AppSettings()
    @Published var config: ServerConfig = ServerConfig()
    @Published var syncPhase: SyncPhase = .idle
    /// Why the last sync failed, in words a person can act on. The phase says
    /// "offline"; this says whether it was ATS, TLS, DNS or a timeout.
    @Published var syncDetail: String?
    @Published var lastSyncedAt: Date?
    @Published var focus: FocusSession?
    @Published var activePanel: PanelID = .agenda
    /// True while the user is looking at nothing but the time. Any touch ends it.
    @Published var immersive: Bool = false
    /// Immersive, but the agenda has been pulled forward into a focused card.
    /// Only meaningful while `immersive` is true — the two together are the
    /// three-stage model: panel → glance → focus.
    @Published var agendaFocus: Bool = false

    /// 0 = dark room, 1 = bright room. Filled by LightSensor when the user turns
    /// on ambient adaptation; 0.5 is the neutral fallback.
    @Published var ambientLevel: Double = 0.5
    /// True once the sensor actually produced a reading. Without it the UI
    /// cannot tell "room is mid-bright" from "sensor never started".
    @Published var ambientAvailable: Bool = false
    /// The task currently demanding attention. Stays until the user answers it:
    /// no auto-dismiss, because a reminder that disappears on its own is a
    /// reminder the user missed.
    @Published var alertTask: AgendaTask?
    /// Tasks already announced this launch, so one due time fires once.
    var alertedTaskIDs: Set<String> = []
    /// Demo mode for the anti-burn-in drift: visible movement instead of the
    /// invisible 1pt/30min cycle. Transient — never persisted.
    @Published var burnInPreview: Bool = false
    /// The newest published build, if it is newer than the one running.
    @Published var availableUpdate: UpdateInfo?
    /// When the last update check finished, successful or not. Drives the
    /// "已检查" line so a failed check never looks like "up to date".
    @Published var updateCheckedAt: Date?
    @Published var showingSettings: Bool = false
    @Published var banner: String?

    /// Sync runtime is owned by the sync extension; declared here so the store
    /// has one lifetime and the view never touches it.
    let runtime = SyncRuntime()

    private let store = LocalStore()

    // MARK: Init

    init() {
        if let snapshot = store.load() {
            tasks = snapshot.tasks
            settings = snapshot.settings
            config = snapshot.config
            lastSyncedAt = snapshot.lastSyncedAt
            focus = snapshot.focus
        }
    }

    // MARK: Derived agenda

    var todayKey: String { DayKey.today() }

    var todayTasks: [AgendaTask] {
        tasks.filter { $0.day == todayKey }.sorted(by: AgendaTask.ordered)
    }

    var openTodayTasks: [AgendaTask] {
        todayTasks.filter { !$0.isDone }
    }

    var nextTask: AgendaTask? {
        let upcoming = openTodayTasks.filter { task in
            guard let due = task.due else { return false }
            return due > Date()
        }
        return upcoming.first
    }

    var completionToday: Double {
        let all = todayTasks
        guard !all.isEmpty else { return 0 }
        return Double(all.filter(\.isDone).count) / Double(all.count)
    }

    var doneTodayCount: Int { todayTasks.filter(\.isDone).count }

    func tasks(on day: String) -> [AgendaTask] {
        tasks.filter { $0.day == day }.sorted(by: AgendaTask.ordered)
    }

    // MARK: Mutations

    func addTask(title: String, day: String? = nil, priority: AgendaTask.Priority = .normal, due: Date? = nil) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var task = AgendaTask(
            title: trimmed,
            day: day ?? todayKey,
            due: due,
            priority: priority,
            origin: .local
        )
        task.updatedAt = Date()
        tasks.append(task)
        persist()
        pushMutation(task)
    }

    func toggle(_ task: AgendaTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index].isDone.toggle()
        tasks[index].updatedAt = Date()
        let updated = tasks[index]
        persist()
        pushMutation(updated)
        if updated.isDone { Haptics.tap() }
    }

    func update(_ task: AgendaTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        var next = task
        next.updatedAt = Date()
        tasks[index] = next
        persist()
        pushMutation(next)
    }

    func delete(_ task: AgendaTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks.remove(at: index)
        persist()
        sendDeletion(task.id)
    }

    func restore(_ task: AgendaTask) {
        guard !tasks.contains(where: { $0.id == task.id }) else { return }
        tasks.append(task)
        persist()
    }

    // MARK: Settings

    func saveSettings() {
        persist()
        applyIdleTimer()
    }

    func saveConfig() {
        // Write back the normalised form (scheme added, trailing slash removed)
        // so the field afterwards shows exactly what the app is talking to.
        if let normalised = config.endpoint?.absoluteString {
            config.baseURL = normalised
        }
        persist()
        restartSyncIfNeeded()
    }

    /// Selecting a preset replaces the whole skin, including its type face and
    /// ring. Editing one field afterwards only marks the skin as custom.
    func applyPreset(_ id: String) {
        guard let preset = SkinLibrary.preset(id: id) else { return }
        settings.skin = preset
        saveSettings()
    }

    func markSkinCustom() {
        settings.skin.presetID = "custom"
        settings.skin.name = "自定义"
    }

    func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepAwake
    }

    // MARK: Focus

    func startFocus(minutes: Int, label: String = "专注") {
        focus = FocusSession(startedAt: Date(), minutes: minutes, label: label)
        persist()
        Haptics.commit()
    }

    func cancelFocus() {
        focus = nil
        persist()
    }

    func finishFocus() {
        guard let session = focus else { return }
        focus = nil
        persist()
        Haptics.success()
        banner = "\(session.label) \(session.minutes) 分钟已完成"
    }

    // MARK: Immersive

    func toggleImmersive() {
        withAnimation(Motion.settle) { immersive.toggle() }
    }

    /// One tap on the glass walks the three stages backwards:
    /// focus → glance → panel → glance → focus …
    ///
    /// The clock is the anchor, so a tap always returns *towards* the time —
    /// never deeper into the agenda. Going deeper is the glance's own job.
    func advanceStage() {
        withAnimation(Motion.settle) {
            if agendaFocus {
                agendaFocus = false
            } else if immersive {
                immersive = false
            } else {
                immersive = true
            }
        }
        Haptics.tap()
    }

    /// Tapping the glance strip: keep the chrome away and pull the agenda up.
    func focusAgenda() {
        withAnimation(Motion.settle) {
            immersive = true
            agendaFocus = true
        }
        Haptics.commit()
    }

    func closeFocus() {
        withAnimation(Motion.settle) {
            agendaFocus = false
        }
        Haptics.tap()
    }

    // MARK: Due alerts

    /// Announced once per due task. Called about once a second while the app is
    /// in the foreground; cheap because it only touches the open tasks.
    func announceDueTasks(now: Date = Date()) {
        guard alertTask == nil else { return }   // one at a time, in order
        let due = openTodayTasks
            .filter { task in
                guard let date = task.due else { return false }
                return date <= now && !alertedTaskIDs.contains(task.id)
            }
            .sorted { ($0.due ?? now) < ($1.due ?? now) }
        guard let next = due.first else { return }
        alertedTaskIDs.insert(next.id)
        // No haptic here: the reminder view owns the whole feedback pattern
        // (warning, then a pulse that keeps going until the user answers).
        // Two generators fighting over the same moment read as a stutter.
        withAnimation(Motion.settle) { alertTask = next }
    }

    /// 完成了 / 十分钟后 / 知道了
    func resolveAlert(_ action: TaskAlertAction) {
        guard let task = alertTask else { return }
        switch action {
        case .done:
            toggle(task)
        case .snooze:
            var moved = task
            let base = max(Date(), task.due ?? Date())
            moved.due = base.addingTimeInterval(10 * 60)
            update(moved)
            alertedTaskIDs.remove(task.id)
        case .dismiss:
            break
        }
        withAnimation(Motion.settle) { alertTask = nil }
        // The closing haptic belongs to AlertHaptics as well: it fires exactly
        // once when the reminder is dismissed.
    }

    // MARK: Persistence

    func persist() {
        store.save(
            LocalStore.Snapshot(
                tasks: tasks,
                settings: settings,
                config: config,
                lastSyncedAt: lastSyncedAt,
                focus: focus
            )
        )
    }
}

// MARK: - Local store

/// A single JSON file in Application Support. Deliberately not CoreData or
/// SwiftData: the whole dataset is a day's agenda, and a readable file is
/// easier to debug from a bug report than a sqlite blob.
struct LocalStore {
    struct Snapshot: Codable {
        var tasks: [AgendaTask] = []
        var settings: AppSettings = AppSettings()
        var config: ServerConfig = ServerConfig()
        var lastSyncedAt: Date?
        var focus: FocusSession?
    }

    private var directory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Meridian", isDirectory: true)
    }

    private var fileURL: URL? {
        directory?.appendingPathComponent("state.json")
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func load() -> Snapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(Snapshot.self, from: data)
    }

    func save(_ snapshot: Snapshot) {
        guard let dir = directory, let url = fileURL else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Haptics

/// Feedback only where it is earned: a tick on completion, a firmer tap on
/// commit, a success pattern when a focus block ends.
enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func commit() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// Sync hooks (bootstrapSync / syncNow / restartSyncIfNeeded / pushMutation /
// sendDeletion) live in Sync/AppModel+Sync.swift — same module, same type,
// separate file, separate owner.
