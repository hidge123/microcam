import Foundation

enum DiaryAggregator {
    private struct GroupKey: Hashable {
        let hour: Date
        let application: String
        let activity: String
    }

    static func aggregate(
        segments: [ActivitySegment],
        date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> DiaryPayload {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        var grouped: [GroupKey: TimeInterval] = [:]
        var applicationSeconds: [String: TimeInterval] = [:]
        var total: TimeInterval = 0

        for segment in segments {
            var cursor = max(segment.startAt, start)
            let segmentEnd = min(segment.endAt, end)
            guard cursor < segmentEnd else { continue }

            while cursor < segmentEnd {
                let hourInterval = calendar.dateInterval(of: .hour, for: cursor)
                let sliceEnd = min(hourInterval?.end ?? segmentEnd, segmentEnd)
                let seconds = max(0, sliceEnd.timeIntervalSince(cursor))
                let hour = hourInterval?.start ?? cursor
                let activity = segment.sanitizedTitle ?? "未记录窗口标题"
                grouped[GroupKey(hour: hour, application: segment.appName, activity: activity), default: 0] += seconds
                applicationSeconds[segment.appName, default: 0] += seconds
                total += seconds
                cursor = sliceEnd
            }
        }

        let hourFormatter = DateFormatter()
        hourFormatter.calendar = calendar
        hourFormatter.locale = Locale(identifier: "zh_CN")
        hourFormatter.timeZone = calendar.timeZone
        hourFormatter.dateFormat = "HH:00"

        let rows = grouped.map { key, seconds in
            DiarySummaryRow(
                hour: hourFormatter.string(from: key.hour),
                application: key.application,
                activity: key.activity,
                minutes: max(1, Int((seconds / 60).rounded()))
            )
        }.sorted {
            if $0.hour != $1.hour { return $0.hour < $1.hour }
            if $0.application != $1.application { return $0.application < $1.application }
            return $0.activity < $1.activity
        }

        return DiaryPayload(
            date: DateCoding.dayString(start),
            activeMinutes: Int((total / 60).rounded()),
            applicationBreakdown: applicationSeconds.mapValues { Int(($0 / 60).rounded()) },
            activities: Array(rows.prefix(500))
        )
    }
}

enum PromptRendererError: LocalizedError, Equatable {
    case missingActivitySummary
    case unsupportedPlaceholder(String)

    var errorDescription: String? {
        switch self {
        case .missingActivitySummary: "提示词必须包含 {{activity_summary}}"
        case let .unsupportedPlaceholder(value): "不支持提示词变量：{{\(value)}}"
        }
    }
}

enum PromptRenderer {
    private static let supported = ["date", "active_time", "app_breakdown", "activity_summary"]

    static func render(template: String, payload: DiaryPayload) throws -> String {
        guard template.contains("{{activity_summary}}") else {
            throw PromptRendererError.missingActivitySummary
        }

        let placeholderRegex = try NSRegularExpression(pattern: #"\{\{\s*([a-zA-Z0-9_]+)\s*\}\}"#)
        let range = NSRange(template.startIndex..<template.endIndex, in: template)
        for match in placeholderRegex.matches(in: template, range: range) {
            guard
                match.numberOfRanges == 2,
                let variableRange = Range(match.range(at: 1), in: template)
            else { continue }
            let variable = String(template[variableRange])
            guard supported.contains(variable) else {
                throw PromptRendererError.unsupportedPlaceholder(variable)
            }
        }

        let appBreakdown = payload.applicationBreakdown
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "- \($0.key)：\(format(minutes: $0.value))" }
            .joined(separator: "\n")

        var activitySummary = payload.activities
            .map { "- \($0.hour) · \($0.application) · \($0.activity)（\($0.minutes) 分钟）" }
            .joined(separator: "\n")
        if activitySummary.count > 12_000 {
            activitySummary = String(activitySummary.prefix(12_000)) + "\n- [摘要因长度限制已截断]"
        }

        return template
            .replacingOccurrences(of: "{{date}}", with: payload.date)
            .replacingOccurrences(of: "{{active_time}}", with: format(minutes: payload.activeMinutes))
            .replacingOccurrences(of: "{{app_breakdown}}", with: appBreakdown.isEmpty ? "无活动" : appBreakdown)
            .replacingOccurrences(of: "{{activity_summary}}", with: activitySummary.isEmpty ? "无活动" : activitySummary)
    }

    private static func format(minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder) 分钟" }
        if remainder == 0 { return "\(hours) 小时" }
        return "\(hours) 小时 \(remainder) 分钟"
    }
}
