import Testing
@testable import Microcam

@Suite struct PromptAndAITests {
    private let payload = DiaryPayload(
        date: "2026-08-08",
        activeMinutes: 90,
        applicationBreakdown: ["Xcode": 60, "Safari": 30],
        activities: [DiarySummaryRow(hour: "10:00", application: "Xcode", activity: "Microcam", minutes: 60)]
    )

    @Test func promptRendering() throws {
        let template = "{{date}} {{active_time}}\n{{app_breakdown}}\n{{activity_summary}}"
        let result = try PromptRenderer.render(template: template, payload: payload)
        #expect(result.contains("2026-08-08"))
        #expect(result.contains("1 小时 30 分钟"))
        #expect(result.contains("Xcode"))
        #expect(result.contains("Microcam"))
    }

    @Test func promptRequiresActivitySummary() {
        do {
            _ = try PromptRenderer.render(template: "{{date}}", payload: payload)
            Issue.record("Expected a missingActivitySummary error")
        } catch let error as PromptRendererError {
            #expect(error == .missingActivitySummary)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unknownPlaceholderIsRejected() {
        do {
            _ = try PromptRenderer.render(template: "{{activity_summary}} {{private_data}}", payload: payload)
            Issue.record("Expected an unsupportedPlaceholder error")
        } catch let error as PromptRendererError {
            #expect(error == .unsupportedPlaceholder("private_data"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func endpointValidation() throws {
        let client = AIClient()
        #expect(try client.endpoint(for: "https://api.example.com/v1").absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(try client.endpoint(for: "http://127.0.0.1:11434/v1").absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        do {
            _ = try client.endpoint(for: "http://api.example.com/v1")
            Issue.record("Expected an insecure endpoint error")
        } catch let error as AIClientError {
            #expect(error == .insecureEndpoint)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func onlyTransientFailuresRetry() {
        #expect(AIClientError.httpStatus(429).shouldRetry)
        #expect(AIClientError.httpStatus(503).shouldRetry)
        #expect(AIClientError.network("offline").shouldRetry)
        #expect(!AIClientError.unauthorized.shouldRetry)
        #expect(!AIClientError.invalidResponse.shouldRetry)
    }
}
