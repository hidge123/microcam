import AppKit
import SwiftUI

struct ActivityView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var monitor: ActivityMonitor
    @State private var showingDeleteConfirmation = false

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        monitor = model.monitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading) {
                    Text("今日活动").font(.largeTitle.bold())
                    Text("所有标题均为本地脱敏后的内容").foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { Task { await model.refreshToday() } }
                Button("删除活动记录", role: .destructive) { showingDeleteConfirmation = true }
            }

            captureStatus

            HStack(spacing: 14) {
                GroupBox("时间线") {
                    if model.todaySegments.isEmpty {
                        ContentUnavailableView("尚无活动", systemImage: "clock")
                    } else {
                        List(model.todaySegments.reversed()) { segment in
                            ActivityRow(segment: segment)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                GroupBox("应用采集策略") {
                    if model.uniqueApplications.isEmpty {
                        ContentUnavailableView("暂无应用", systemImage: "square.grid.2x2")
                    } else {
                        List(model.uniqueApplications, id: \.bundleID) { app in
                            VStack(alignment: .leading, spacing: 7) {
                                Text(app.name).fontWeight(.medium)
                                Text(app.bundleID).font(.caption2).foregroundStyle(.secondary)
                                Picker("采集", selection: Binding(
                                    get: { settings.policy(for: app.bundleID) },
                                    set: { settings.setPolicy($0, for: app.bundleID) }
                                )) {
                                    ForEach(AppCapturePolicy.allCases) { policy in
                                        Text(policy.localizedName).tag(policy)
                                    }
                                }
                                .labelsHidden()
                            }
                            .padding(.vertical, 4)
                        }
                        .listStyle(.inset)
                    }
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
            }
        }
        .padding(28)
        .alert("删除全部活动记录？", isPresented: $showingDeleteConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { Task { await model.deleteAllActivities() } }
        } message: {
            Text("此操作不可撤销。已生成的日记不会被删除。")
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

            if let lastRecordedAt = monitor.lastRecordedAt {
                Text("最近写入：\(lastRecordedAt.formatted(date: .omitted, time: .standard))")
                    .foregroundStyle(.secondary)
            } else {
                Text("等待首次活动写入")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DiariesView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDay: String?
    @State private var generationDate = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    @State private var showingDatePicker = false
    @State private var showingReplaceConfirmation = false

    private var selectedDiary: DiaryEntry? {
        model.diaries.first { $0.day == selectedDay }
    }

    private var diaryForGenerationDate: DiaryEntry? {
        let day = DateCoding.dayString(generationDate)
        return model.diaries.first { $0.day == day && $0.status == .succeeded }
    }

    var body: some View {
        VStack(spacing: 0) {
            diaryToolbar
            Divider()

            HStack(spacing: 0) {
                diaryListPane
                    .frame(width: 248)
                    .frame(maxHeight: .infinity)

                Divider()

                diaryDetailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("日记")
        .onAppear {
            selectDiaryIfNeeded()
        }
        .onChange(of: model.diaries.map(\.day)) {
            selectDiaryIfNeeded()
        }
        .alert("替换已有日记？", isPresented: $showingReplaceConfirmation) {
            Button("取消", role: .cancel) {}
            Button("生成并替换") {
                Task { await model.generateDiary(for: generationDate, replacingExisting: true) }
            }
        } message: {
            Text("旧日记会保留到新内容成功生成后才被替换。")
        }
    }

    private var diaryToolbar: some View {
        HStack(spacing: 12) {
            Text("日记")
                .font(.largeTitle.bold())

            Spacer(minLength: 20)

            Button {
                showingDatePicker.toggle()
            } label: {
                Label(
                    generationDate.formatted(.dateTime.year().month().day()),
                    systemImage: "calendar"
                )
            }
            .controlSize(.large)
            .popover(isPresented: $showingDatePicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("选择生成日期")
                        .font(.headline)

                    DatePicker(
                        "生成日期",
                        selection: $generationDate,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .frame(width: 320, height: 300)

                    Divider()

                    HStack {
                        Text(generationDate.formatted(date: .complete, time: .omitted))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("完成") { showingDatePicker = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(18)
                .frame(width: 356)
            }

            Button {
                if diaryForGenerationDate != nil {
                    showingReplaceConfirmation = true
                } else {
                    Task { await model.generateDiary(for: generationDate) }
                }
            } label: {
                Label(model.isGenerating ? "生成中…" : "生成", systemImage: "sparkles")
            }
            .disabled(model.isGenerating)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var diaryListPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("全部日记")
                .font(.headline)
                .padding(.horizontal, 4)

            if model.diaries.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("尚无日记")
                        .font(.headline)
                    Text("选择日期后点击生成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(model.diaries, selection: $selectedDay) { diary in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(diary.day)
                            .fontWeight(.medium)
                        HStack(spacing: 5) {
                            Image(systemName: statusSymbol(diary.status))
                            Text(statusTitle(diary.status))
                            if let generatedAt = diary.generatedAt {
                                Text("· \(generatedAt.formatted(date: .omitted, time: .shortened))")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .tag(diary.day)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var diaryDetailPane: some View {
        if let diary = selectedDiary {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(diary.day)
                            .font(.largeTitle.bold())
                        Spacer()
                        if let content = diary.content {
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(content, forType: .string)
                            }
                            Button("导出 Markdown") { model.export(diary) }
                        }
                    }

                    if let content = diary.content {
                        Text(LocalizedStringKey(content))
                            .textSelection(.enabled)
                            .font(.body)
                            .lineSpacing(5)
                    } else {
                        ContentUnavailableView {
                            Label(statusTitle(diary.status), systemImage: statusSymbol(diary.status))
                        } description: {
                            if let errorCode = diary.errorCode {
                                Text("错误代码：\(errorCode)")
                            }
                        }
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选择一篇日记", systemImage: "book.pages")
        }
    }

    private func selectDiaryIfNeeded() {
        guard let selectedDay, model.diaries.contains(where: { $0.day == selectedDay }) else {
            self.selectedDay = model.diaries.first?.day
            return
        }
    }

    private func statusTitle(_ status: DiaryStatus) -> String {
        switch status {
        case .pending: "等待生成"
        case .succeeded: "已生成"
        case .failed: "生成失败"
        }
    }

    private func statusSymbol(_ status: DiaryStatus) -> String {
        switch status {
        case .pending: "clock"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}
