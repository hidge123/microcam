import AppKit
import SwiftUI

private enum SidebarSection: String, CaseIterable, Identifiable {
    case overview = "概览"
    case activity = "活动"
    case diaries = "日记"
    case settings = "设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .activity: "clock.arrow.circlepath"
        case .diaries: "book.pages"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var monitor: ActivityMonitor
    @State private var selection: SidebarSection? = .overview
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    init(model: AppModel) {
        self.model = model
        settings = model.settings
        monitor = model.monitor
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(SidebarSection.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(systemName: monitor.displayState.symbolName)
                        .foregroundStyle(statusColor)
                    Text(monitor.displayState.title)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView(model: model)
                case .activity: ActivityView(model: model)
                case .diaries: DiariesView(model: model)
                case .settings: SettingsView(model: model)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message = model.operationMessage {
                    HStack {
                        Image(systemName: "info.circle")
                        Text(message).lineLimit(2)
                        Spacer()
                        Button("关闭") { model.dismissOperationMessage() }
                            .buttonStyle(.plain)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(.regularMaterial)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: Binding(
            get: { !settings.onboardingComplete },
            set: { if !$0 { settings.onboardingComplete = true } }
        )) {
            OnboardingView(model: model)
        }
    }

    private var statusColor: Color {
        switch monitor.displayState {
        case .recording: .green
        case .paused, .idle: .orange
        case .permissionLimited: .yellow
        case .stopped: .secondary
        }
    }
}

struct OverviewView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var monitor: ActivityMonitor
    @ObservedObject private var settings: SettingsStore

    init(model: AppModel) {
        self.model = model
        monitor = model.monitor
        settings = model.settings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("概览").font(.largeTitle.bold())

                HStack(spacing: 14) {
                    MetricCard(
                        title: "今日有效使用",
                        value: formatDuration(model.todayActiveSeconds),
                        symbol: "timer",
                        tint: .blue
                    )
                    MetricCard(
                        title: "记录状态",
                        value: monitor.displayState.title,
                        symbol: monitor.displayState.symbolName,
                        tint: .green
                    )
                    MetricCard(
                        title: "下次生成",
                        value: settings.autoGenerate
                            ? model.nextGenerationDate.formatted(date: .abbreviated, time: .shortened)
                            : "自动生成已关闭",
                        symbol: "sparkles",
                        tint: .purple
                    )
                }

                GroupBox("隐私与权限") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            monitor.accessibilityGranted ? "已允许读取当前窗口标题" : "未允许窗口标题；当前仅记录应用时长",
                            systemImage: monitor.accessibilityGranted ? "checkmark.shield" : "exclamationmark.shield"
                        )
                        Text("Microcam 不读取键盘、鼠标内容、截图、URL、文件内容、摄像头或麦克风。")
                            .foregroundStyle(.secondary)
                        if !monitor.accessibilityGranted {
                            Button("了解并启用窗口标题采集") {
                                monitor.requestAccessibilityPermission()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                HStack {
                    Text("最近活动").font(.title2.bold())
                    Spacer()
                    Text("更新于 \(model.lastRefresh.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.todaySegments.isEmpty {
                    ContentUnavailableView("尚无活动", systemImage: "clock", description: Text("开始使用其他应用后，活动会出现在这里。"))
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.todaySegments.suffix(8).reversed()) { segment in
                            ActivityRow(segment: segment)
                            if segment.id != model.todaySegments.suffix(8).first?.id { Divider() }
                        }
                    }
                    .padding(.horizontal)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
        }
        .navigationTitle("概览")
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            Text(value).font(.headline).lineLimit(2)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ActivityRow: View {
    let segment: ActivitySegment

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(bundleID: segment.bundleID, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(segment.appName).fontWeight(.medium)
                Text(segment.sanitizedTitle ?? policyDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(formatDuration(segment.activeSeconds)).monospacedDigit()
                Text(segment.startAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var policyDescription: String {
        segment.capturePolicy == .durationOnly ? "窗口标题已隐藏" : "无窗口标题"
    }
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let totalMinutes = max(0, Int(seconds / 60))
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes) 分钟" }
    if minutes == 0 { return "\(hours) 小时" }
    return "\(hours) 小时 \(minutes) 分"
}
