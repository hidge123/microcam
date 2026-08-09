import Foundation
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
}
