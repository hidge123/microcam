import Foundation
import SQLite3
import Testing
@testable import Microcam

@Suite struct SQLitePrivacyTests {
    @Test func sensitiveTitleAndDiaryAreNotStoredInPlaintext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(cryptoBox: .ephemeral(), databaseURL: databaseURL)
        let secretTitle = "Secret Project Phoenix alex@example.com"
        let secretDiary = "Today I completed Secret Project Phoenix."
        let now = Date()

        try await store.save(ActivitySegment(
            id: UUID(),
            startAt: now.addingTimeInterval(-60),
            endAt: now,
            bundleID: "com.example.editor",
            appName: "Editor",
            sanitizedTitle: secretTitle,
            capturePolicy: .title
        ))
        try await store.save(DiaryEntry(
            day: "2026-08-08",
            status: .succeeded,
            content: secretDiary,
            model: "test-model",
            generatedAt: now,
            errorCode: nil
        ))

        let fetchedSegments = try await store.fetchSegments(from: now.addingTimeInterval(-120), to: now.addingTimeInterval(1))
        let fetchedDiaries = try await store.fetchDiaries()
        #expect(fetchedSegments.first?.sanitizedTitle == secretTitle)
        #expect(fetchedDiaries.first?.content == secretDiary)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for file in files {
            let data = try Data(contentsOf: file)
            #expect(data.range(of: Data(secretTitle.utf8)) == nil, "title leaked in \(file.lastPathComponent)")
            #expect(data.range(of: Data(secretDiary.utf8)) == nil, "diary leaked in \(file.lastPathComponent)")
        }
    }

    @Test func databasePermissionsAreOwnerOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        _ = try SQLiteStore(cryptoBox: .ephemeral(), databaseURL: databaseURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func dailySummaryDoesNotReadEncryptedTitles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-summary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.sqlite")
        let store = try SQLiteStore(cryptoBox: .ephemeral(), databaseURL: databaseURL)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-08-08T10:00:00+08:00"))

        try await store.save(ActivitySegment(
            id: UUID(),
            startAt: now,
            endAt: now.addingTimeInterval(15 * 60),
            bundleID: "com.example.editor",
            appName: "Editor",
            sanitizedTitle: "encrypted title",
            capturePolicy: .title
        ))

        var database: OpaquePointer?
        #expect(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(
            database,
            "UPDATE activity_segments SET title_ciphertext = X'00';",
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        sqlite3_close(database)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let summaries = try await store.fetchActivityDaySummaries(calendar: calendar, now: now)
        #expect(summaries.count == 1)
        #expect(summaries.first?.activeSeconds == 900.0)
        let singleDaySummary = try await store.fetchActivityDaySummary(
            forDay: "2026-08-08",
            calendar: calendar,
            now: now
        )
        #expect(singleDaySummary?.activeSeconds == 900.0)

        do {
            _ = try await store.fetchSegments(forDay: "2026-08-08", calendar: calendar)
            Issue.record("Expected detailed loading to decrypt the corrupt title")
        } catch let error as SQLiteStoreError {
            guard case .corruptedEncryptedField = error else {
                Issue.record("Unexpected store error: \(error)")
                return
            }
        }
    }

    @Test func deletingOneDayPreservesAdjacentActivityAndDiary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-day-delete-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(
            cryptoBox: .ephemeral(),
            databaseURL: directory.appendingPathComponent("test.sqlite")
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let crossMidnight = try #require(ISO8601DateFormatter().date(from: "2026-08-08T23:50:00+08:00"))
        let nextMorning = try #require(ISO8601DateFormatter().date(from: "2026-08-09T09:00:00+08:00"))

        try await store.save(ActivitySegment(
            id: UUID(),
            startAt: crossMidnight,
            endAt: crossMidnight.addingTimeInterval(20 * 60),
            bundleID: "com.example.editor",
            appName: "Editor",
            sanitizedTitle: "Project",
            capturePolicy: .title
        ))
        try await store.save(ActivitySegment(
            id: UUID(),
            startAt: nextMorning,
            endAt: nextMorning.addingTimeInterval(10 * 60),
            bundleID: "com.example.browser",
            appName: "Browser",
            sanitizedTitle: nil,
            capturePolicy: .durationOnly
        ))
        try await store.save(DiaryEntry(
            day: "2026-08-08",
            status: .succeeded,
            content: "保留的日记",
            model: "test",
            generatedAt: nextMorning,
            errorCode: nil
        ))

        try await store.deleteActivities(forDay: "2026-08-08", calendar: calendar)

        #expect(try await store.fetchSegments(forDay: "2026-08-08", calendar: calendar).isEmpty)
        let nextDay = try await store.fetchSegments(forDay: "2026-08-09", calendar: calendar)
        #expect(nextDay.count == 2)
        #expect(nextDay.reduce(0) { $0 + $1.activeSeconds } == 20 * 60)
        #expect(try await store.diary(for: "2026-08-08")?.content == "保留的日记")

        try await store.deleteDiary(for: "2026-08-08")
        #expect(try await store.diary(for: "2026-08-08") == nil)
        #expect(try await store.fetchSegments(forDay: "2026-08-09", calendar: calendar).count == 2)
    }

    @Test func retentionCleanupKeepsPermanentDiary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-retention-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(
            cryptoBox: .ephemeral(),
            databaseURL: directory.appendingPathComponent("test.sqlite")
        )
        let oldDate = try #require(ISO8601DateFormatter().date(from: "2026-07-01T09:00:00+08:00"))
        let cutoff = try #require(ISO8601DateFormatter().date(from: "2026-08-01T00:00:00+08:00"))
        try await store.save(ActivitySegment(
            id: UUID(),
            startAt: oldDate,
            endAt: oldDate.addingTimeInterval(60),
            bundleID: "com.example.editor",
            appName: "Editor",
            sanitizedTitle: nil,
            capturePolicy: .durationOnly
        ))
        try await store.save(DiaryEntry(
            day: "2026-07-01",
            status: .succeeded,
            content: "永久保留",
            model: "test",
            generatedAt: oldDate,
            errorCode: nil
        ))

        try await store.deleteActivities(olderThan: cutoff)

        #expect(try await store.fetchSegments(from: oldDate, to: cutoff).isEmpty)
        #expect(try await store.diary(for: "2026-07-01")?.content == "永久保留")
    }

    @Test func detailedActivityLoadsInBoundedNewestFirstPages() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-pagination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteStore(
            cryptoBox: .ephemeral(),
            databaseURL: directory.appendingPathComponent("test.sqlite")
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let start = try #require(ISO8601DateFormatter().date(from: "2026-08-08T08:00:00+08:00"))

        for index in 0..<120 {
            let segmentStart = start.addingTimeInterval(TimeInterval(index * 60))
            try await store.save(ActivitySegment(
                id: UUID(),
                startAt: segmentStart,
                endAt: segmentStart.addingTimeInterval(30),
                bundleID: "com.example.editor",
                appName: "Editor",
                sanitizedTitle: "title-\(index)",
                capturePolicy: .title
            ))
        }

        let first = try await store.fetchSegmentPage(
            forDay: "2026-08-08",
            limit: 50,
            calendar: calendar
        )
        let second = try await store.fetchSegmentPage(
            forDay: "2026-08-08",
            offset: first.nextOffset,
            limit: 50,
            calendar: calendar
        )
        let third = try await store.fetchSegmentPage(
            forDay: "2026-08-08",
            offset: second.nextOffset,
            limit: 50,
            calendar: calendar
        )

        #expect(first.segments.count == 50)
        #expect(first.segments.first?.sanitizedTitle == "title-119")
        #expect(first.hasMore)
        #expect(second.segments.count == 50)
        #expect(second.segments.first?.sanitizedTitle == "title-69")
        #expect(second.hasMore)
        #expect(third.segments.count == 20)
        #expect(third.segments.last?.sanitizedTitle == "title-0")
        #expect(!third.hasMore)
        #expect(Set((first.segments + second.segments + third.segments).map(\.id)).count == 120)
    }
}
