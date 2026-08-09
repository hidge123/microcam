import Foundation
import Testing
@testable import Microcam

@Suite struct DiaryAggregatorTests {
    @Test func segmentsAreSplitAcrossHourBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let date = try makeDate("2026-08-08T10:50:00+08:00")
        let segment = ActivitySegment(
            id: UUID(),
            startAt: date,
            endAt: date.addingTimeInterval(20 * 60),
            bundleID: "com.example.editor",
            appName: "Editor",
            sanitizedTitle: "Project",
            capturePolicy: .title
        )

        let payload = DiaryAggregator.aggregate(segments: [segment], date: date, calendar: calendar)
        #expect(payload.activeMinutes == 20)
        #expect(payload.activities.count == 2)
        #expect(payload.activities.map(\.hour) == ["10:00", "11:00"])
        #expect(payload.applicationBreakdown["Editor"] == 20)
    }

    @Test func outOfDayTimeIsClipped() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let date = try makeDate("2026-08-08T00:00:00+08:00")
        let segment = ActivitySegment(
            id: UUID(),
            startAt: date.addingTimeInterval(-10 * 60),
            endAt: date.addingTimeInterval(10 * 60),
            bundleID: "com.example.editor",
            appName: "Editor",
            sanitizedTitle: nil,
            capturePolicy: .durationOnly
        )
        let payload = DiaryAggregator.aggregate(segments: [segment], date: date, calendar: calendar)
        #expect(payload.activeMinutes == 10)
    }

    private func makeDate(_ value: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: value))
    }
}
