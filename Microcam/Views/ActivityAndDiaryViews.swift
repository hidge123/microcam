import AppKit
import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var monitor: ActivityMonitor
    @State private var selectedDay: String?
    @State private var selectedSegments: [ActivitySegment] = []
    @State private var isLoadingDetails = false
    @State private var isLoadingMore = false
    @State private var nextSegmentOffset = 0
    @State private var hasMoreSegments = false
    @State private var showingDeleteAllConfirmation = false
    @State private var showingDeleteDayConfirmation = false

    private let timelinePageSize = 50

    init(model: AppModel) {
        self.model = model
        monitor = model.monitor
    }

    private var selectedSummary: ActivityDaySummary? {
        model.activityDays.first { $0.day == selectedDay }
    }

    var body: some View {
        VStack(spacing: 0) {
            activityToolbar
            Divider()

            HStack(spacing: 0) {
                dayListPane
                    .frame(width: 264)
                    .frame(maxHeight: .infinity)

                Divider()

                activityDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("活动")
        .task {
            await model.refreshActivityData()
            selectDayIfNeeded()
        }
        .task(id: selectedDay) {
            await loadSelectedDay(reset: true)
        }
        .onChange(of: model.activityDays.map(\.day)) {
            selectDayIfNeeded()
        }
        .alert("删除全部活动记录？", isPresented: $showingDeleteAllConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.deleteAllActivities() } }
        } message: {
            Text("此操作不可撤销。已生成的日记不会被删除。")
        }
        .alert("删除这一天的活动日志？", isPresented: $showingDeleteDayConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let selectedDay else { return }
                Task { await model.deleteActivityDay(selectedDay) }
            }
        } message: {
            Text("只删除所选日期的活动明细，不影响相邻日期或已经生成的日记。此操作不可撤销。")
        }
    }

    private var activityToolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每日活动日志").font(.largeTitle.bold())
                    Text("按本地日历日整理；进入某天后才会解密并读取脱敏标题")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") {
                    Task {
                        await model.refreshActivityData()
                        await loadSelectedDay(reset: true)
                    }
                }
                Button("删除全部", role: .destructive) { showingDeleteAllConfirmation = true }
            }
            captureStatus
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var dayListPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("活动日志")
                .font(.headline)
                .padding(.horizontal, 4)

            if model.activityDays.isEmpty {
                ContentUnavailableView("尚无活动日志", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.activityDays, selection: $selectedDay) { summary in
                    ActivityDayRow(summary: summary)
                        .tag(summary.day)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var activityDetailPane: some View {
        if let summary = selectedSummary {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(formattedLogDate(summary.day))
                                .font(.largeTitle.bold())
                            if summary.isToday {
                                Label("今天的日志正在实时记录", systemImage: "record.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        Spacer()
                        Button("删除当天日志", role: .destructive) {
                            showingDeleteDayConfirmation = true
                        }
                    }

                    HStack(spacing: 12) {
                        DailyMetric(title: "有效时长", value: formatDuration(summary.activeSeconds), symbol: "timer")
                        DailyMetric(title: "应用", value: "\(summary.applicationCount) 个", symbol: "square.grid.2x2")
                        DailyMetric(title: "活动段", value: "\(summary.segmentCount) 条", symbol: "list.bullet.rectangle")
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("应用分布").font(.title2.bold())
                        if summary.applications.isEmpty {
                            Text("没有应用用时数据").foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(summary.applications) { application in
                                    ApplicationUsageRow(
                                        application: application,
                                        totalSeconds: summary.activeSeconds
                                    )
                                }
                            }
                            .padding(16)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("详细时间线").font(.title2.bold())
                            Spacer()
                            if !selectedSegments.isEmpty {
                                Text("已显示最新 \(selectedSegments.count) 条")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if isLoadingDetails {
                            ProgressView("正在读取脱敏活动明细…")
                                .frame(maxWidth: .infinity, minHeight: 140)
                        } else if selectedSegments.isEmpty {
                            ContentUnavailableView("没有可显示的活动明细", systemImage: "clock")
                                .frame(maxWidth: .infinity, minHeight: 160)
                        } else {
                            LazyVStack(spacing: 0) {
                                ForEach(selectedSegments) { segment in
                                    ActivityRow(segment: segment)
                                    if segment.id != selectedSegments.last?.id { Divider() }
                                }
                            }
                            .padding(.horizontal, 16)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))

                            if hasMoreSegments {
                                Button {
                                    Task { await loadSelectedDay(reset: false) }
                                } label: {
                                    if isLoadingMore {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("再加载 \(timelinePageSize) 条")
                                    }
                                }
                                .disabled(isLoadingMore)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(maxWidth: 900, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选择一份活动日志", systemImage: "calendar")
        }
    }

    private var captureStatus: some View {
        HStack(spacing: 10) {
            if let error = monitor.lastPersistenceError {
                Label("活动保存失败：\(error)", systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
            } else if monitor.accessibilityGranted {
                Label("窗口标题采集已启用", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                Label("窗口标题权限未生效；应用名称与使用时长仍会记录", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text(monitor.lastRecordedAt.map {
                "最近写入：\($0.formatted(date: .omitted, time: .standard))"
            } ?? "等待首次活动写入")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func selectDayIfNeeded() {
        guard let selectedDay, model.activityDays.contains(where: { $0.day == selectedDay }) else {
            self.selectedDay = model.activityDays.first?.day
            return
        }
    }

    private func loadSelectedDay(reset: Bool) async {
        guard let requestedDay = selectedDay else {
            selectedSegments = []
            nextSegmentOffset = 0
            hasMoreSegments = false
            return
        }
        if reset {
            isLoadingDetails = true
            selectedSegments = []
            nextSegmentOffset = 0
            hasMoreSegments = false
        } else {
            guard hasMoreSegments, !isLoadingMore else { return }
            isLoadingMore = true
        }
        let offset = reset ? 0 : nextSegmentOffset
        defer {
            if selectedDay == requestedDay {
                isLoadingDetails = false
                isLoadingMore = false
            }
        }
        do {
            let page = try await model.activitySegmentPage(
                forDay: requestedDay,
                offset: offset,
                limit: timelinePageSize
            )
            guard !Task.isCancelled, selectedDay == requestedDay else { return }
            if reset {
                selectedSegments = page.segments
            } else {
                selectedSegments.append(contentsOf: page.segments)
            }
            nextSegmentOffset = page.nextOffset
            hasMoreSegments = page.hasMore
        } catch {
            guard selectedDay == requestedDay else { return }
            if reset { selectedSegments = [] }
        }
    }
}

struct DiariesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @State private var selectedDay: String?
    @State private var showingReplaceConfirmation = false
    @State private var showingDeleteConfirmation = false

    private var selectedRecord: DiaryDayRecord? {
        model.diaryRecords.first { $0.day == selectedDay }
    }

    init(model: AppModel) {
        self.model = model
        settings = model.settings
    }

    var body: some View {
        VStack(spacing: 0) {
            diaryToolbar
            Divider()

            HStack(spacing: 0) {
                diaryListPane
                    .frame(width: 264)
                    .frame(maxHeight: .infinity)

                Divider()

                diaryDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("日记")
        .task {
            await model.refreshActivityData()
            await model.refreshDiaries()
            selectRecordIfNeeded()
        }
        .onChange(of: model.diaryRecords.map(\.day)) {
            selectRecordIfNeeded()
        }
        .alert("替换已有日记？", isPresented: $showingReplaceConfirmation) {
            Button("取消", role: .cancel) {}
            Button("生成并替换") {
                guard let selectedDay else { return }
                Task { await model.generateDiary(forDay: selectedDay, replacingExisting: true) }
            }
        } message: {
            Text("旧日记会保留到新内容成功生成后才被替换。")
        }
        .alert("删除这篇日记？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                guard let selectedDay else { return }
                Task { await model.deleteDiary(selectedDay) }
            }
        } message: {
            Text("只删除日记正文，不会删除对应的活动日志。此操作不可撤销。")
        }
    }

    private var diaryToolbar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("日记").font(.largeTitle.bold())
                Text("日记只能从已经结束且仍保有明细的每日活动日志生成")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("刷新") {
                Task {
                    await model.refreshActivityData()
                    await model.refreshDiaries()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var diaryListPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("日志与日记")
                .font(.headline)
                .padding(.horizontal, 4)

            if model.diaryRecords.isEmpty {
                ContentUnavailableView("尚无每日活动日志", systemImage: "book.closed")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.diaryRecords, selection: $selectedDay) { record in
                    DiaryDayRow(
                        record: record,
                        isGenerating: model.generatingDay == record.day
                    )
                    .tag(record.day)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var diaryDetailPane: some View {
        if let record = selectedRecord {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 10) {
                        Spacer()
                        diaryActions(for: record)
                    }

                    Text(formattedLogDate(record.day))
                        .font(.largeTitle.bold())
                        .fixedSize(horizontal: false, vertical: true)

                    sourceStatus(for: record)

                    if let activity = record.activity {
                        HStack(spacing: 12) {
                            DailyMetric(title: "活动时长", value: formatDuration(activity.activeSeconds), symbol: "timer")
                            DailyMetric(title: "应用", value: "\(activity.applicationCount) 个", symbol: "square.grid.2x2")
                            DailyMetric(title: "活动段", value: "\(activity.segmentCount) 条", symbol: "list.bullet.rectangle")
                        }
                    }

                    if let diary = record.diary, let content = diary.content {
                        Divider()
                        Text(LocalizedStringKey(content))
                            .textSelection(.enabled)
                            .font(.body)
                            .lineSpacing(5)
                    } else {
                        diaryEmptyState(for: record)
                    }
                }
                .frame(maxWidth: 800, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选择一份日志", systemImage: "book.pages")
        }
    }

    @ViewBuilder
    private func diaryActions(for record: DiaryDayRecord) -> some View {
        if let diary = record.diary, let content = diary.content {
            Button("复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(content, forType: .string)
            }
            Button("导出 Markdown") { model.export(diary) }
            if record.activity != nil && !record.activity!.isToday {
                Button("重新生成") { showingReplaceConfirmation = true }
                    .disabled(model.isGenerating)
            }
            Button("删除日记", role: .destructive) { showingDeleteConfirmation = true }
        } else if record.canGenerate {
            Button {
                Task { await model.generateDiary(forDay: record.day) }
            } label: {
                Label(model.generatingDay == record.day ? "生成中…" : generationButtonTitle(record), systemImage: "sparkles")
            }
            .disabled(model.isGenerating)
        }
    }

    @ViewBuilder
    private func sourceStatus(for record: DiaryDayRecord) -> some View {
        if record.activity?.isToday == true {
            StatusBanner(
                title: "今天的活动日志正在记录中",
                detail: "当天结束后，这份日志才可用于生成日记。",
                symbol: "record.circle.fill",
                tint: .green
            )
        } else if record.activity == nil {
            StatusBanner(
                title: "活动明细已过期或被删除",
                detail: record.diary?.content == nil
                    ? "没有可用于生成日记的来源数据。"
                    : "已有日记会继续保留，但无法重新生成。",
                symbol: "archivebox",
                tint: .orange
            )
        } else if record.diary == nil, let reason = model.automaticDiaryGenerationBlockReason {
            StatusBanner(
                title: "自动生成暂不可用",
                detail: "\(reason)。仍可使用右上角按钮手动生成。",
                symbol: "exclamationmark.triangle",
                tint: .orange
            )
        } else if record.diary == nil {
            StatusBanner(
                title: "活动日志已完整保存",
                detail: "可将这份脱敏活动摘要发送给已配置的 AI 生成日记。",
                symbol: "checkmark.circle",
                tint: .blue
            )
        }
    }

    @ViewBuilder
    private func diaryEmptyState(for record: DiaryDayRecord) -> some View {
        if model.generatingDay == record.day {
            ProgressView("正在生成日记…")
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if record.diary?.status == .failed || record.diary?.status == .pending {
            ContentUnavailableView {
                Label(
                    record.diary?.status == .pending ? "上次生成未完成" : "生成失败",
                    systemImage: "exclamationmark.circle"
                )
            } description: {
                if let errorCode = record.diary?.errorCode {
                    Text("错误代码：\(errorCode)")
                } else {
                    Text("应用可能在生成过程中退出，可从原活动日志重新尝试。")
                }
            } actions: {
                if record.activity != nil {
                    Button("重试") { Task { await model.generateDiary(forDay: record.day) } }
                        .disabled(model.isGenerating)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else if record.activity?.isToday == true {
            ContentUnavailableView("记录中", systemImage: "clock", description: Text("今天结束前不能生成日记。"))
                .frame(maxWidth: .infinity, minHeight: 180)
        } else if record.activity == nil {
            ContentUnavailableView("无法生成日记", systemImage: "archivebox", description: Text("对应的活动明细已不可用。"))
                .frame(maxWidth: .infinity, minHeight: 180)
        } else {
            ContentUnavailableView {
                Label("尚未生成日记", systemImage: "book.closed")
            } description: {
                Text("从这份每日活动日志生成日记。")
            } actions: {
                Button("生成日记") { Task { await model.generateDiary(forDay: record.day) } }
                    .disabled(model.isGenerating)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func generationButtonTitle(_ record: DiaryDayRecord) -> String {
        record.diary?.status == .failed ? "重试" : "生成日记"
    }

    private func selectRecordIfNeeded() {
        guard let selectedDay, model.diaryRecords.contains(where: { $0.day == selectedDay }) else {
            self.selectedDay = model.diaryRecords.first?.day
            return
        }
    }
}

private struct ActivityDayRow: View {
    let summary: ActivityDaySummary

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(formattedLogDate(summary.day, compact: true)).fontWeight(.medium)
                Spacer()
                if summary.isToday {
                    Text("记录中")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                }
            }
            Text("\(formatDuration(summary.activeSeconds)) · \(summary.applicationCount) 个应用")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct DiaryDayRow: View {
    let record: DiaryDayRecord
    let isGenerating: Bool

    private var state: DiaryDayState {
        if isGenerating { return .generating }
        if record.diary?.status == .pending { return .failed }
        return record.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(formattedLogDate(record.day, compact: true)).fontWeight(.medium)
            Label(state.localizedName, systemImage: stateSymbol)
                .font(.caption)
                .foregroundStyle(stateColor)
        }
        .padding(.vertical, 4)
    }

    private var stateSymbol: String {
        switch state {
        case .recording: "record.circle"
        case .ready: "sparkles"
        case .generating: "hourglass"
        case .failed: "exclamationmark.circle"
        case .succeeded: "checkmark.circle"
        case .activityExpired: "archivebox"
        }
    }

    private var stateColor: Color {
        switch state {
        case .recording: .green
        case .failed: .red
        case .activityExpired: .orange
        default: .secondary
        }
    }
}

private struct DailyMetric: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(value).font(.headline)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ApplicationUsageRow: View {
    let application: ApplicationUsageSummary
    let totalSeconds: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                AppIconView(bundleID: application.bundleID, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(application.appName).fontWeight(.medium)
                    if application.appName != application.bundleID {
                        Text(application.bundleID).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(formatDuration(application.activeSeconds)).monospacedDigit()
            }
            ProgressView(value: application.activeSeconds, total: max(totalSeconds, 1))
                .tint(.blue)
        }
    }
}

private struct StatusBanner: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private func formattedLogDate(_ day: String, compact: Bool = false) -> String {
    guard let date = DateCoding.date(fromDay: day) else { return day }
    return compact
        ? date.formatted(.dateTime.month().day().weekday(.abbreviated))
        : date.formatted(.dateTime.year().month().day().weekday(.wide))
}
