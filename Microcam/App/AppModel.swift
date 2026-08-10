import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let settings: SettingsStore
    let loginItemManager: LoginItemManager
    let monitor: ActivityMonitor

    @Published private(set) var todaySegments: [ActivitySegment] = []
    @Published private(set) var activityDays: [ActivityDaySummary] = []
    @Published private(set) var diaries: [DiaryEntry] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var generatingDay: String?
    @Published private(set) var operationMessage: String?
    @Published private(set) var lastRefresh = Date()

    private let store: SQLiteStore
    private let diaryService: DiaryService
    private let aiClient = AIClient()
    private var started = false
    private var lastAutomaticEvaluationDay: String?
    private var liveRefreshTask: Task<Void, Never>?
    private var lastLiveRefresh = Date.distantPast

    private static let liveRefreshInterval: TimeInterval = 120
    private static let recentActivityLimit = 8
    private static let promptPreviewCharacterLimit = 8_000

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    init() {
        let settings = SettingsStore()
        self.settings = settings
        loginItemManager = LoginItemManager()

        do {
            let cryptoBox = Self.isRunningTests ? CryptoBox.ephemeral() : try CryptoBox.loadOrCreate()
            let store: SQLiteStore
            if Self.isRunningTests {
                let testDatabase = FileManager.default.temporaryDirectory
                    .appendingPathComponent("microcam-test-host-\(ProcessInfo.processInfo.processIdentifier).sqlite")
                store = try SQLiteStore(cryptoBox: cryptoBox, databaseURL: testDatabase)
            } else {
                store = try SQLiteStore(cryptoBox: cryptoBox)
            }
            self.store = store
            monitor = ActivityMonitor(settings: settings, store: store)
            diaryService = DiaryService(store: store)
        } catch {
            fatalError("Microcam 无法初始化本地加密存储：\(error.localizedDescription)")
        }

        monitor.onDidPersist = { [weak self] in
            self?.scheduleLiveRefresh()
        }
        monitor.onWake = { [weak self] in
            Task { @MainActor [weak self] in await self?.checkAutomaticDiaryGeneration(force: true) }
        }
        monitor.onPeriodicMaintenance = { [weak self] in
            Task { @MainActor [weak self] in await self?.checkAutomaticDiaryGeneration() }
        }

        if !Self.isRunningTests {
            Task { @MainActor [weak self] in
                await self?.start()
            }
        }
    }

    var todayActiveSeconds: TimeInterval {
        activityDays.first(where: { $0.isToday })?.activeSeconds ?? 0
    }

    var knownApplications: [(bundleID: String, name: String)] {
        var names: [String: String] = [:]
        for day in activityDays {
            for application in day.applications {
                names[application.bundleID] = application.appName
            }
        }
        for bundleID in settings.capturePolicies.keys where names[bundleID] == nil {
            names[bundleID] = bundleID
        }
        return names.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    var diaryRecords: [DiaryDayRecord] {
        let activityByDay = Dictionary(uniqueKeysWithValues: activityDays.map { ($0.day, $0) })
        let diaryByDay = Dictionary(uniqueKeysWithValues: diaries.map { ($0.day, $0) })
        return Set(activityByDay.keys).union(diaryByDay.keys).sorted(by: >).map { day in
            DiaryDayRecord(day: day, activity: activityByDay[day], diary: diaryByDay[day])
        }
    }

    var nextGenerationDate: Date {
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let start = calendar.startOfDay(for: now)
        var components = DateComponents()
        components.hour = settings.generationHour
        components.minute = settings.generationMinute
        let todaySchedule = calendar.date(byAdding: components, to: start) ?? start
        if todaySchedule > now { return todaySchedule }
        return calendar.date(byAdding: .day, value: 1, to: todaySchedule) ?? todaySchedule
    }

    func start() async {
        guard !started else { return }
        started = true
        lastLiveRefresh = Date()
        await monitor.start()
        await cleanupExpiredActivity()
        await refreshAll()
        await checkAutomaticDiaryGeneration()
    }

    func shutdown() async {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        await monitor.stop()
    }

    func refreshAll() async {
        cancelScheduledLiveRefresh()
        await refreshActivityDays()
        await refreshToday()
        await refreshDiaries()
        loginItemManager.refresh()
    }

    func refreshActivityData() async {
        cancelScheduledLiveRefresh()
        await refreshActivityDays()
        await refreshToday()
    }

    func refreshActivityDays() async {
        do {
            activityDays = try await store.fetchActivityDaySummaries()
            lastRefresh = Date()
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func refreshToday() async {
        let day = DateCoding.dayString(Date())
        let crossedMidnight = activityDays.contains { $0.isToday && $0.day != day }
        do {
            let recentPage = try await store.fetchSegmentPage(
                forDay: day,
                limit: Self.recentActivityLimit
            )
            let todaySummary = try await store.fetchActivityDaySummary(forDay: day)
            // Keep only the rows displayed by the overview. Detailed history is loaded
            // separately in bounded pages when the user opens the activity panel.
            todaySegments = Array(recentPage.segments.reversed())
            if crossedMidnight {
                activityDays = try await store.fetchActivityDaySummaries()
            } else {
                patchTodaySummary(todaySummary)
            }
            lastRefresh = Date()
            lastLiveRefresh = lastRefresh
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func refreshDiaries() async {
        do {
            diaries = try await store.fetchDiaries()
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func activitySegmentPage(
        forDay day: String,
        offset: Int = 0,
        limit: Int = 50
    ) async throws -> ActivitySegmentPage {
        try await store.fetchSegmentPage(forDay: day, offset: offset, limit: limit)
    }

    func generateDiary(forDay day: String, replacingExisting: Bool = false, automatic: Bool = false) async {
        guard !isGenerating else { return }
        guard settings.promptValidationMessage == nil else {
            operationMessage = settings.promptValidationMessage
            return
        }
        guard
            let date = DateCoding.date(fromDay: day),
            date < Calendar.autoupdatingCurrent.startOfDay(for: Date())
        else {
            operationMessage = "今天的活动日志仍在记录中，需在当天结束后生成"
            return
        }
        if !activityDays.contains(where: { $0.day == day && $0.activeSeconds > 0 }) {
            await refreshActivityDays()
        }
        guard activityDays.contains(where: { $0.day == day && $0.activeSeconds > 0 }) else {
            operationMessage = "该日期的活动明细不存在或已过期，无法生成日记"
            return
        }
        isGenerating = true
        generatingDay = day
        if !automatic { operationMessage = "正在生成日记…" }
        defer {
            isGenerating = false
            generatingDay = nil
        }

        do {
            try settings.saveAISecret()
            _ = try await diaryService.generate(
                forDay: day,
                configuration: settings.aiConfiguration,
                promptTemplate: settings.promptTemplate,
                replacingExisting: replacingExisting
            )
            operationMessage = "日记已生成"
            await refreshDiaries()
        } catch {
            operationMessage = error.localizedDescription
            await refreshDiaries()
        }
    }

    func testAIConnection() async {
        guard !isGenerating else { return }
        isGenerating = true
        operationMessage = "正在测试 AI 接口…"
        defer { isGenerating = false }
        do {
            try settings.saveAISecret()
            let response = try await aiClient.test(configuration: settings.aiConfiguration)
            operationMessage = "连接成功：\(String(response.prefix(40)))"
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func saveRedactionSettings() {
        do {
            try settings.saveRedactionSecrets()
            operationMessage = "脱敏设置已安全保存"
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func deleteAllActivities() async {
        let wasPaused = monitor.isPaused
        if !wasPaused { await monitor.pause(for: nil) }
        do {
            try await store.deleteActivities()
            await refreshActivityData()
            operationMessage = "活动记录已删除"
        } catch {
            operationMessage = error.localizedDescription
        }
        if !wasPaused { await monitor.resume() }
    }

    func deleteActivityDay(_ day: String) async {
        let isToday = day == DateCoding.dayString(Date())
        let wasPaused = monitor.isPaused
        if isToday && !wasPaused { await monitor.pause(for: nil) }
        do {
            try await store.deleteActivities(forDay: day)
            await refreshActivityData()
            operationMessage = "\(day) 的活动日志已删除"
        } catch {
            operationMessage = error.localizedDescription
        }
        if isToday && !wasPaused { await monitor.resume() }
    }

    func deleteAllDiaries() async {
        do {
            try await store.deleteDiaries()
            await refreshDiaries()
            operationMessage = "日记已删除"
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func deleteDiary(_ day: String) async {
        do {
            try await store.deleteDiary(for: day)
            await refreshDiaries()
            operationMessage = "\(day) 的日记已删除"
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func resetAllData() async {
        let wasPaused = monitor.isPaused
        if !wasPaused { await monitor.pause(for: nil) }
        do {
            try await store.deleteAllData()
            try? KeychainStore.delete(.apiKey)
            try? KeychainStore.delete(.redactionTerms)
            settings.restoreDefaults()
            await refreshAll()
            operationMessage = "应用数据和设置已重置"
        } catch {
            operationMessage = error.localizedDescription
        }
        if !wasPaused { await monitor.resume() }
    }

    func export(_ diary: DiaryEntry) {
        guard let content = diary.content else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(diary.day).md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let markdown = "# \(diary.day)\n\n\(content)\n"
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            operationMessage = "已导出到 \(url.lastPathComponent)"
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    func sanitizedPreview(for value: String) -> String {
        settings.redactor.redact(value) ?? "（脱敏后为空）"
    }

    func savePromptTemplate(_ template: String) {
        settings.promptTemplate = template
        operationMessage = "提示词已保存"
    }

    func renderPromptPreview(template: String) async throws -> String {
        guard template.contains("{{activity_summary}}") else {
            throw PromptRendererError.missingActivitySummary
        }

        let now = Date()
        let day = DateCoding.dayString(now)
        let segments = try await store.fetchSegments(forDay: day)
        let rendered = try await Task.detached(priority: .userInitiated) {
            let payload = DiaryAggregator.aggregate(segments: segments, date: now)
            return try PromptRenderer.render(template: template, payload: payload)
        }.value
        if rendered.count > Self.promptPreviewCharacterLimit {
            return String(rendered.prefix(Self.promptPreviewCharacterLimit))
                + "\n\n[界面预览已截断；实际生成仍会使用完整聚合摘要]"
        }
        return rendered
    }

    func dismissOperationMessage() {
        operationMessage = nil
    }

    private func cleanupExpiredActivity() async {
        guard settings.retentionDays > 0 else { return }
        let cutoff = Calendar.autoupdatingCurrent.date(
            byAdding: .day,
            value: -settings.retentionDays,
            to: Date()
        )
        do {
            try await store.deleteActivities(olderThan: cutoff)
        } catch {
            operationMessage = error.localizedDescription
        }
    }

    private func checkAutomaticDiaryGeneration(force: Bool = false) async {
        guard
            settings.autoGenerate,
            settings.aiDataSharingConfirmed,
            settings.aiConfiguration.isConfigured,
            !isGenerating
        else { return }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        let evaluationDay = DateCoding.dayString(now, calendar: calendar)
        if !force, lastAutomaticEvaluationDay == evaluationDay { return }
        let startOfToday = calendar.startOfDay(for: now)
        var scheduleComponents = DateComponents()
        scheduleComponents.hour = settings.generationHour
        scheduleComponents.minute = settings.generationMinute
        let todaySchedule = calendar.date(byAdding: scheduleComponents, to: startOfToday) ?? startOfToday
        guard now >= todaySchedule else { return }
        lastAutomaticEvaluationDay = evaluationDay

        await refreshActivityDays()
        let diaryByDay = Dictionary(uniqueKeysWithValues: diaries.map { ($0.day, $0) })
        guard let candidate = activityDays.first(where: { summary in
            guard !summary.isToday, summary.startAt < startOfToday else { return false }
            let status = diaryByDay[summary.day]?.status
            return status != .succeeded && status != .pending
        }) else { return }
        let day = candidate.day
        guard !settings.hasAutoAttempted(day: day) else { return }

        settings.markAutoAttempt(for: day)
        await generateDiary(forDay: day, automatic: true)
    }

    private func scheduleLiveRefresh() {
        guard started, liveRefreshTask == nil else { return }
        let delay = max(0, Self.liveRefreshInterval - Date().timeIntervalSince(lastLiveRefresh))
        liveRefreshTask = Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, let self else { return }
            liveRefreshTask = nil
            await refreshToday()
        }
    }

    private func cancelScheduledLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func patchTodaySummary(_ todaySummary: ActivityDaySummary?) {
        let today = DateCoding.dayString(Date())
        var updated = activityDays.filter { $0.day != today }.map { summary in
            ActivityDaySummary(
                day: summary.day,
                startAt: summary.startAt,
                activeSeconds: summary.activeSeconds,
                segmentCount: summary.segmentCount,
                applications: summary.applications,
                isToday: false
            )
        }
        if let todaySummary { updated.append(todaySummary) }
        activityDays = updated.sorted { $0.day > $1.day }
    }
}
