import Testing
@testable import Microcam

@Suite struct RedactorTests {
    @Test func builtInSensitiveValuesAreRemoved() throws {
        let input = "alex@example.com /Users/alex/Secret/file.md https://example.com/private sk-live_1234567890abcdef 192.168.1.9"
        let output = try #require(Redactor(username: "alex").redact(input))

        #expect(!output.contains("alex@example.com"))
        #expect(!output.contains("/Users/alex"))
        #expect(!output.contains("https://example.com/private"))
        #expect(!output.contains("1234567890abcdef"))
        #expect(!output.contains("192.168.1.9"))
        #expect(output.contains("[邮箱]"))
        #expect(output.contains("[文件路径]"))
    }

    @Test func customTermsAndPatterns() throws {
        let redactor = Redactor(
            customTerms: ["Project Phoenix"],
            customPatterns: [#"TICKET-\d+"#],
            username: ""
        )
        let output = try #require(redactor.redact("Project Phoenix TICKET-2048"))
        #expect(output == "[自定义敏感词] [自定义隐藏]")
    }

    @Test func invalidCustomPatternIsIgnored() {
        let redactor = Redactor(customPatterns: ["(["], username: "")
        #expect(redactor.redact("ordinary title") == "ordinary title")
    }

    @Test func outputIsBounded() {
        let redactor = Redactor(username: "", maximumLength: 40)
        #expect((redactor.redact(String(repeating: "a", count: 10_000))?.count ?? 0) <= 40)
    }
}
