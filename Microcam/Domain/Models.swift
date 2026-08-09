import Foundation

enum AppCapturePolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case title
    case durationOnly
    case exclude

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .title: "应用与标题"
        case .durationOnly: "仅记录时长"
        case .exclude: "完全排除"
        }
    }
}

struct ActivitySegment: Identifiable, Equatable, Sendable {
    let id: UUID
    var startAt: Date
    var endAt: Date
    let bundleID: String
    let appName: String
    let sanitizedTitle: String?
    let capturePolicy: AppCapturePolicy

    var activeSeconds: TimeInterval {
        max(0, endAt.timeIntervalSince(startAt))
    }
}

struct ActivityIntervalRecord: Equatable, Sendable {
    let startAt: Date
    let endAt: Date
    let bundleID: String
    let appName: String
}

struct ApplicationUsageSummary: Identifiable, Equatable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let appName: String
    let activeSeconds: TimeInterval
}

struct ActivityDaySummary: Identifiable, Equatable, Sendable {
    var id: String { day }
    let day: String
    let startAt: Date
    let activeSeconds: TimeInterval
    let segmentCount: Int
    let applications: [ApplicationUsageSummary]
    let isToday: Bool

    var applicationCount: Int { applications.count }
}

enum DiaryStatus: String, Codable, Sendable {
    case pending
    case succeeded
    case failed
}

struct DiaryEntry: Identifiable, Equatable, Sendable {
    var id: String { day }
    let day: String
    let status: DiaryStatus
    let content: String?
    let model: String
    let generatedAt: Date?
    let errorCode: String?
}

enum DiaryDayState: Equatable, Sendable {
    case recording
    case ready
    case generating
    case failed
    case succeeded
    case activityExpired

    var localizedName: String {
        switch self {
        case .recording: "记录中"
        case .ready: "待生成"
        case .generating: "生成中"
        case .failed: "生成失败"
        case .succeeded: "已生成"
        case .activityExpired: "活动明细已过期"
        }
    }
}

struct DiaryDayRecord: Identifiable, Equatable, Sendable {
    var id: String { day }
    let day: String
    let activity: ActivityDaySummary?
    let diary: DiaryEntry?

    var state: DiaryDayState {
        guard let activity else { return .activityExpired }
        if activity.isToday { return .recording }
        switch diary?.status {
        case .pending: return .generating
        case .failed: return .failed
        case .succeeded: return .succeeded
        case nil: return .ready
        }
    }

    var canGenerate: Bool {
        activity != nil && activity?.isToday == false
    }
}

struct AIConfiguration: Equatable, Sendable {
    var baseURL: String
    var apiKey: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var timeout: TimeInterval

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DiarySummaryRow: Codable, Equatable, Sendable {
    let hour: String
    let application: String
    let activity: String
    let minutes: Int
}

struct DiaryPayload: Codable, Equatable, Sendable {
    let date: String
    let activeMinutes: Int
    let applicationBreakdown: [String: Int]
    let activities: [DiarySummaryRow]
}

enum MonitorDisplayState: Equatable, Sendable {
    case recording(appName: String?)
    case paused(until: Date?)
    case idle
    case permissionLimited
    case stopped

    var title: String {
        switch self {
        case let .recording(appName): appName.map { "正在记录：\($0)" } ?? "正在记录"
        case let .paused(until): until.map { "已暂停至 \($0.formatted(date: .omitted, time: .shortened))" } ?? "已暂停"
        case .idle: "空闲中"
        case .permissionLimited: "仅记录应用时长"
        case .stopped: "记录已关闭"
        }
    }

    var symbolName: String {
        switch self {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .idle: "moon.zzz.fill"
        case .permissionLimited: "exclamationmark.shield.fill"
        case .stopped: "stop.circle"
        }
    }
}

enum MicrocamDefaults {
    static let promptTemplate = """
    请根据 {{date}} 的电脑活动生成一篇中文日记。语气自然、克制，重点描述完成的事情、投入的时间和一天的节奏，不要逐条罗列日志，也不要编造活动中没有体现的事实。

    今日有效使用时间：{{active_time}}

    应用用时：
    {{app_breakdown}}

    活动摘要：
    {{activity_summary}}
    """

    static let sensitiveBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.Passwords",
        "com.apple.keychainaccess"
    ]
}

enum DateCoding {
    static func dayString(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func date(fromDay day: String, calendar: Calendar = .autoupdatingCurrent) -> Date? {
        let parts = day.split(separator: "-", omittingEmptySubsequences: false)
        guard
            parts.count == 3,
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let dayOfMonth = Int(parts[2]),
            let date = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)),
            dayString(date, calendar: calendar) == day
        else { return nil }
        return date
    }
}
