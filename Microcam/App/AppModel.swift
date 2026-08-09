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
    @Published private(set) var diaries: [DiaryEntry] = []
    @Published private(set) var isGenerating = false
    @Published private(set) var operationMessage: String?
    @Published private(set) var promptPreview = "暂无活动可预览"
    @Published private(set) var lastRefresh = Date()

    private let store: SQLiteStore
    private let diaryService: DiaryService
    private let aiClient = AIClient()
    private var started = false
    private var lastAutomaticCheck: Date?

    init() {
        let settings = SettingsStore()
        self.settings = settings
        loginItemManager = LoginItemManager()

        do {
            let cryptoBox = try CryptoBox.loadOrCreate()
            let store = try SQLiteStore(cryptoBox: cryptoBox)
            self.store = store
            monitor = ActivityMonitor(settings: settings, store: store)
            diaryService = DiaryService(store: store)
        } catch {
            fatalError("Microcam 无法初始化本地加密存储：\(error.localizedDescription)")
        }

        monitor.onDidPersist = { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshToday() }
        }
        monitor.onWake = { [weak self] in
            Task { @MainActor [weak self] in await self?.checkAutomaticDiaryGeneration() }
        }

        Task { @MainActor [weak self] in
            await self?.start()
        }
    }

    var todayActiveSeconds: TimeInterval {
        todaySegments.reduce(0) { $0 + $1.activeSeconds }
    }

    var uniqueApplications: [(bundleID: String, name: String)] {
        var names: [String: String] = [:]
        for segment in todaySegments { names[segment.bundleID] = segment.appName }
        return names.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
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
        await monitor.start()
        await cleanupExpiredActivity()
        await refreshAll()
        await checkAutomaticDiaryGeneration()
    }

    func shutdown() async {
        await monitor.stop()
    }

    func refreshAll() async {
        await refreshToday()
        await refreshDiaries()
        loginItemManager.refresh()
    }

    func refreshToday() async {
        let interval = todayInterval()
        do {
            todaySegments = try await store.fetchSegments(from: interval.start, to: interval.end)
            lastRefresh = Date()
            updatePromptPreview()
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

    func generateDiary(for date: Date, replacingExisting: Bool = false, automatic: Bool = false) async {
        guard !isGenerating else { return }
        guard settings.promptValidationMessage == nil else {
            operationMessage = settings.promptValidationMessage
            return
        }
        isGenerating = true
        if !automatic { operationMessage = "正在生成日记…" }
        defer { isGenerating = false }

        do {
            try settings.saveAISecret()
            _ = try await diaryService.generate(
                for: date,
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
        updatePromptPreview()
    }

    func deleteAllActivities() async {
        let wasPaused = monitor.isPaused
        if !wasPaused { await monitor.pause(for: nil) }
        do {
            try await store.deleteActivities()
            await refreshToday()
            operationMessage = "活动记录已删除"
        } catch {
            operationMessage = error.localizedDescription
        }
        if !wasPaused { await monitor.resume() }
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

    func refreshPromptPreview() {
        updatePromptPreview()
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

    private func checkAutomaticDiaryGeneration() async {
        guard
            settings.autoGenerate,
            settings.aiDataSharingConfirmed,
            settings.aiConfiguration.isConfigured,
            !isGenerating
        else { return }
        let calendar = Calendar.autoupdatingCurrent
        let now = Date()
        if let lastAutomaticCheck, now.timeIntervalSince(lastAutomaticCheck) < 60 { return }
        lastAutomaticCheck = now
        let startOfToday = calendar.startOfDay(for: now)
        var scheduleComponents = DateComponents()
        scheduleComponents.hour = settings.generationHour
        scheduleComponents.minute = settings.generationMinute
        let todaySchedule = calendar.date(byAdding: scheduleComponents, to: startOfToday) ?? startOfToday
        let offset = now >= todaySchedule ? -1 : -2
        guard let targetDate = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { return }
        let day = DateCoding.dayString(targetDate)
        guard !settings.hasAutoAttempted(day: day) else { return }

        let interval = dayInterval(containing: targetDate)
        guard let segments = try? await store.fetchSegments(from: interval.start, to: interval.end), !segments.isEmpty else {
            return
        }
        do {
            if let diary = try await store.diary(for: day), diary.status == .succeeded {
                settings.markAutoAttempt(for: day)
                return
            }
        } catch {
            operationMessage = error.localizedDescription
            return
        }

        settings.markAutoAttempt(for: day)
        await generateDiary(for: targetDate, automatic: true)
    }

    private func updatePromptPreview() {
        let payload = DiaryAggregator.aggregate(segments: todaySegments, date: Date())
        promptPreview = (try? PromptRenderer.render(template: settings.promptTemplate, payload: payload))
            ?? settings.promptValidationMessage
            ?? "无法生成预览"
    }

    private func todayInterval() -> DateInterval {
        dayInterval(containing: Date())
    }

    private func dayInterval(containing date: Date) -> DateInterval {
        let calendar = Calendar.autoupdatingCurrent
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }
}
