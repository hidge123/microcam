import Foundation
import Testing
@testable import Microcam

@Suite struct DiaryServiceTests {
    @Test func todayAndFutureCannotGenerate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = DiaryService(store: fixture.store)
        let calendar = Calendar.autoupdatingCurrent
        let today = DateCoding.dayString(Date(), calendar: calendar)
        let futureDate = try #require(calendar.date(byAdding: .day, value: 1, to: Date()))

        for day in [today, DateCoding.dayString(futureDate, calendar: calendar)] {
            do {
                _ = try await service.generate(
                    forDay: day,
                    configuration: configuration,
                    promptTemplate: MicrocamDefaults.promptTemplate,
                    replacingExisting: false
                )
                Issue.record("Expected \(day) to be rejected")
            } catch let error as DiaryServiceError {
                guard case .incompleteDay = error else {
                    Issue.record("Unexpected error for \(day): \(error)")
                    continue
                }
            }
        }
    }

    @Test func missingAndInvalidActivityLogCannotGenerate() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = DiaryService(store: fixture.store)
        let yesterday = try #require(Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: Date()))

        do {
            _ = try await service.generate(
                forDay: DateCoding.dayString(yesterday),
                configuration: configuration,
                promptTemplate: MicrocamDefaults.promptTemplate,
                replacingExisting: false
            )
            Issue.record("Expected an empty activity log to be rejected")
        } catch let error as DiaryServiceError {
            guard case .noActivity = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }

        do {
            _ = try await service.generate(
                forDay: "not-a-day",
                configuration: configuration,
                promptTemplate: MicrocamDefaults.promptTemplate,
                replacingExisting: false
            )
            Issue.record("Expected an invalid day to be rejected")
        } catch let error as DiaryServiceError {
            guard case .invalidDay = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    private var configuration: AIConfiguration {
        AIConfiguration(
            baseURL: "https://example.com/v1",
            apiKey: "",
            model: "test",
            temperature: 0,
            maxTokens: 128,
            timeout: 15
        )
    }

    private func makeFixture() throws -> (directory: URL, store: SQLiteStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("microcam-diary-service-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteStore(
            cryptoBox: .ephemeral(),
            databaseURL: directory.appendingPathComponent("test.sqlite")
        )
        return (directory, store)
    }
}
