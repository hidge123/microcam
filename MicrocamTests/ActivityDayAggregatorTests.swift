import Foundation
import Testing
@testable import Microcam

@Suite struct ActivityDayAggregatorTests {
    @Test func crossMidnightSegmentIsClippedIntoTwoDays() throws {
        let calendar = try calendar(timeZone: "Asia/Shanghai")
        let start = try date("2026-08-08T23:50:00+08:00")
        let records = [ActivityIntervalRecord(
            startAt: start,
            endAt: start.addingTimeInterval(20 * 60),
            bundleID: "com.example.editor",
            appName: "Editor"
        )]

        let result = ActivityDayAggregator.summarize(
            records,
            calendar: calendar,
            now: try date("2026-08-09T12:00:00+08:00")
        )

        #expect(result.map(\.day) == ["2026-08-09", "2026-08-08"])
        #expect(result.allSatisfy { $0.activeSeconds == 600 })
        #expect(result[0].isToday)
        #expect(!result[1].isToday)
    }

    @Test func summariesAreSortedAndAggregateApplications() throws {
        let calendar = try calendar(timeZone: "Asia/Shanghai")
        let morning = try date("2026-08-08T09:00:00+08:00")
        let records = [
            ActivityIntervalRecord(
                startAt: morning,
                endAt: morning.addingTimeInterval(30 * 60),
                bundleID: "com.example.editor",
                appName: "Editor"
            ),
            ActivityIntervalRecord(
                startAt: morning.addingTimeInterval(60 * 60),
                endAt: morning.addingTimeInterval(75 * 60),
                bundleID: "com.example.browser",
                appName: "Browser"
            ),
            ActivityIntervalRecord(
                startAt: morning,
                endAt: morning,
                bundleID: "com.example.zero",
                appName: "Zero"
            )
        ]

        let summary = try #require(ActivityDayAggregator.summarize(
            records,
            calendar: calendar,
            now: morning
        ).first)
        #expect(summary.activeSeconds == 45 * 60)
        #expect(summary.applicationCount == 2)
        #expect(summary.segmentCount == 2)
        #expect(summary.applications.map(\.bundleID) == ["com.example.editor", "com.example.browser"])
    }

    @Test func daylightSavingDayUsesCalendarBoundary() throws {
        let calendar = try calendar(timeZone: "America/Los_Angeles")
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let result = ActivityDayAggregator.summarize(
            [ActivityIntervalRecord(
                startAt: start,
                endAt: end,
                bundleID: "com.example.editor",
                appName: "Editor"
            )],
            calendar: calendar,
            now: start
        )

        #expect(result.count == 1)
        #expect(result[0].day == "2026-03-08")
        #expect(result[0].activeSeconds == 23 * 60 * 60)
    }

    @Test func diaryRecordStatesRespectTodayAndExpiredActivity() throws {
        let calendar = try calendar(timeZone: "Asia/Shanghai")
        let today = try date("2026-08-09T12:00:00+08:00")
        let summary = ActivityDaySummary(
            day: "2026-08-09",
            startAt: calendar.startOfDay(for: today),
            activeSeconds: 60,
            segmentCount: 1,
            applications: [],
            isToday: true
        )
        #expect(DiaryDayRecord(day: summary.day, activity: summary, diary: nil).state == .recording)

        let diary = DiaryEntry(
            day: "2026-08-08",
            status: .succeeded,
            content: "日记",
            model: "test",
            generatedAt: today,
            errorCode: nil
        )
        let expired = DiaryDayRecord(day: diary.day, activity: nil, diary: diary)
        #expect(expired.state == .activityExpired)
        #expect(!expired.canGenerate)
    }

    private func calendar(timeZone identifier: String) throws -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = try #require(TimeZone(identifier: identifier))
        return value
    }

    private func date(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
