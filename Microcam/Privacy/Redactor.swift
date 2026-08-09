import Foundation

struct Redactor: Sendable {
    private struct Rule: @unchecked Sendable {
        let regex: NSRegularExpression
        let replacement: String
    }

    private let rules: [Rule]
    private let maximumLength: Int

    init(
        customTerms: [String] = [],
        customPatterns: [String] = [],
        username: String = NSUserName(),
        maximumLength: Int = 240
    ) {
        self.maximumLength = maximumLength

        var definitions: [(String, String, NSRegularExpression.Options)] = [
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[邮箱]", [.caseInsensitive]),
            (#"https?://[^\s]+"#, "[网址]", [.caseInsensitive]),
            (#"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])"#, "[IP]", []),
            (#"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){2,7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:])"#, "[IP]", []),
            (#"(?:/Users/[^/\s]+|~)(?:/[^\s/]+)+"#, "[文件路径]", []),
            (#"(?<!\d)(?:\+?\d[\s().-]?){7,15}(?!\d)"#, "[电话]", []),
            (#"\b\d{8,}\b"#, "[编号]", []),
            (#"\b(?:sk|pk|api|token|key)[-_][A-Za-z0-9_-]{8,}\b"#, "[密钥]", [.caseInsensitive]),
            (#"\b[A-Za-z0-9_=-]{32,}\b"#, "[疑似令牌]", [])
        ]

        if !username.isEmpty {
            definitions.append((NSRegularExpression.escapedPattern(for: username), "[用户名]", [.caseInsensitive]))
        }

        for term in customTerms where !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            definitions.append((NSRegularExpression.escapedPattern(for: term), "[自定义敏感词]", [.caseInsensitive]))
        }

        for pattern in customPatterns where !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            definitions.append((pattern, "[自定义隐藏]", [.caseInsensitive]))
        }

        rules = definitions.compactMap { pattern, replacement, options in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
            return Rule(regex: regex, replacement: replacement)
        }
    }

    func redact(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        value = String(value.prefix(maximumLength * 4))

        for rule in rules {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            value = rule.regex.stringByReplacingMatches(
                in: value,
                options: [],
                range: range,
                withTemplate: rule.replacement
            )
        }

        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return String(value.prefix(maximumLength))
    }
}
