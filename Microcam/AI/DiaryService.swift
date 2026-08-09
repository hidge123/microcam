import Foundation

enum DiaryServiceError: LocalizedError {
    case noActivity
    case notConfigured
    case alreadyExists
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .noActivity: "当天没有可用于生成日记的活动"
        case .notConfigured: "请先完成 AI 接口配置"
        case .alreadyExists: "当天日记已经存在"
        case let .underlying(error): error.localizedDescription
        }
    }
}

actor DiaryService {
    private let store: SQLiteStore
    private let client: AIClient
    private let calendar: Calendar

    init(store: SQLiteStore, client: AIClient = AIClient(), calendar: Calendar = .autoupdatingCurrent) {
        self.store = store
        self.client = client
        self.calendar = calendar
    }

    func generate(
        for date: Date,
        configuration: AIConfiguration,
        promptTemplate: String,
        replacingExisting: Bool
    ) async throws -> DiaryEntry {
        guard configuration.isConfigured else { throw DiaryServiceError.notConfigured }
        let day = DateCoding.dayString(date)
        let existing = try await store.diary(for: day)
        if existing?.status == .succeeded && !replacingExisting {
            throw DiaryServiceError.alreadyExists
        }

        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let segments = try await store.fetchSegments(from: start, to: end)
        guard !segments.isEmpty else { throw DiaryServiceError.noActivity }
        let payload = DiaryAggregator.aggregate(segments: segments, date: date, calendar: calendar)
        let renderedPrompt = try PromptRenderer.render(template: promptTemplate, payload: payload)

        if existing?.status != .succeeded {
            try await store.save(DiaryEntry(
                day: day,
                status: .pending,
                content: nil,
                model: configuration.model,
                generatedAt: nil,
                errorCode: nil
            ))
        }

        var lastError: AIClientError?
        for attempt in 1...3 {
            do {
                let content = try await client.generate(
                    configuration: configuration,
                    renderedPrompt: renderedPrompt,
                    payload: payload
                )
                let diary = DiaryEntry(
                    day: day,
                    status: .succeeded,
                    content: content,
                    model: configuration.model,
                    generatedAt: Date(),
                    errorCode: nil
                )
                try await store.save(diary)
                return diary
            } catch let error as AIClientError {
                lastError = error
                guard error.shouldRetry, attempt < 3 else { break }
                try? await Task.sleep(for: .seconds(attempt == 1 ? 2 : 10))
            } catch {
                throw DiaryServiceError.underlying(error)
            }
        }

        let failure = lastError ?? .invalidResponse
        if existing?.status != .succeeded {
            try await store.save(DiaryEntry(
                day: day,
                status: .failed,
                content: nil,
                model: configuration.model,
                generatedAt: Date(),
                errorCode: failure.nonSensitiveCode
            ))
        }
        throw DiaryServiceError.underlying(failure)
    }
}
