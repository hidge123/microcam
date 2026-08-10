import Foundation

enum DiaryMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case blockquote(String)
    case unorderedListItem(text: String, depth: Int, checked: Bool?)
    case orderedListItem(number: Int, text: String, depth: Int)
    case codeBlock(language: String?, code: String)
    case thematicBreak
}

enum DiaryMarkdownParser {
    static func parse(_ markdown: String) -> [DiaryMarkdownBlock] {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var blocks: [DiaryMarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let fence = fenceStart(in: trimmed) {
                flushParagraph()
                var codeLines: [String] = []
                index += 1
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix(fence.marker) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.codeBlock(
                    language: fence.language,
                    code: codeLines.joined(separator: "\n")
                ))
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isThematicBreak(trimmed) {
                flushParagraph()
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoteLines: [String] = []
                while index < lines.count {
                    let quoteLine = lines[index].trimmingCharacters(in: .whitespaces)
                    guard quoteLine.hasPrefix(">") else { break }
                    var content = String(quoteLine.dropFirst())
                    if content.hasPrefix(" ") { content.removeFirst() }
                    quoteLines.append(content)
                    index += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            if let item = unorderedListItem(in: line) {
                flushParagraph()
                blocks.append(.unorderedListItem(
                    text: item.text,
                    depth: item.depth,
                    checked: item.checked
                ))
                index += 1
                continue
            }

            if let item = orderedListItem(in: line) {
                flushParagraph()
                blocks.append(.orderedListItem(
                    number: item.number,
                    text: item.text,
                    depth: item.depth
                ))
                index += 1
                continue
            }

            paragraphLines.append(trimmed)
            index += 1
        }

        flushParagraph()
        return blocks
    }

    private static func fenceStart(in line: String) -> (marker: String, language: String?)? {
        let marker: String
        if line.hasPrefix("```") {
            marker = "```"
        } else if line.hasPrefix("~~~") {
            marker = "~~~"
        } else {
            return nil
        }
        let language = line.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? nil : language)
    }

    private static func heading(in line: String) -> (level: Int, text: String)? {
        let level = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let separatorIndex = line.index(line.startIndex, offsetBy: level)
        guard separatorIndex < line.endIndex, line[separatorIndex].isWhitespace else { return nil }
        let text = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    private static func unorderedListItem(
        in line: String
    ) -> (text: String, depth: Int, checked: Bool?)? {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        guard
            let marker = content.first,
            "-*+".contains(marker),
            content.dropFirst().first?.isWhitespace == true
        else { return nil }

        var text = content.dropFirst().drop(while: { $0.isWhitespace }).description
        var checked: Bool?
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("[ ] ") {
            checked = false
            text = String(text.dropFirst(4))
        } else if lowercased.hasPrefix("[x] ") {
            checked = true
            text = String(text.dropFirst(4))
        }
        return (text, leadingSpaces / 2, checked)
    }

    private static func orderedListItem(
        in line: String
    ) -> (number: Int, text: String, depth: Int)? {
        let leadingSpaces = line.prefix(while: { $0 == " " || $0 == "\t" }).reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
        let content = line.drop(while: { $0 == " " || $0 == "\t" })
        let digits = content.prefix(while: { $0.isNumber })
        guard
            !digits.isEmpty,
            let number = Int(digits),
            digits.endIndex < content.endIndex
        else { return nil }

        let delimiter = content[digits.endIndex]
        guard delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = content.index(after: digits.endIndex)
        guard afterDelimiter < content.endIndex, content[afterDelimiter].isWhitespace else { return nil }
        let text = content[afterDelimiter...].drop(while: { $0.isWhitespace }).description
        return (number, text, leadingSpaces / 2)
    }
}
