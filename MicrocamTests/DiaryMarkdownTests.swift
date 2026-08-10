import Testing
@testable import Microcam

@Suite struct DiaryMarkdownTests {
    @Test func parsesCommonAIDiaryMarkdownBlocks() {
        let markdown = """
        # 今日回顾

        完成了 **重要任务**，并整理了 [资料](https://example.com)。

        > 保持专注，也留出了休息时间。

        - 写完功能
          - 补充测试
        - [x] 检查结果
        - [ ] 明天继续
        3. 导出日记

        ---

        ```swift
        let result = "done"
        ```
        """

        let blocks = DiaryMarkdownParser.parse(markdown)

        #expect(blocks == [
            .heading(level: 1, text: "今日回顾"),
            .paragraph("完成了 **重要任务**，并整理了 [资料](https://example.com)。"),
            .blockquote("保持专注，也留出了休息时间。"),
            .unorderedListItem(text: "写完功能", depth: 0, checked: nil),
            .unorderedListItem(text: "补充测试", depth: 1, checked: nil),
            .unorderedListItem(text: "检查结果", depth: 0, checked: true),
            .unorderedListItem(text: "明天继续", depth: 0, checked: false),
            .orderedListItem(number: 3, text: "导出日记", depth: 0),
            .thematicBreak,
            .codeBlock(language: "swift", code: "let result = \"done\"")
        ])
    }

    @Test func joinsSoftWrappedParagraphAndPreservesQuotedLineBreaks() {
        let markdown = """
        第一行
        第二行

        > 引用一
        > 引用二
        """

        #expect(DiaryMarkdownParser.parse(markdown) == [
            .paragraph("第一行 第二行"),
            .blockquote("引用一\n引用二")
        ])
    }

    @Test func unclosedFenceStillProducesCodeBlock() {
        let markdown = """
        ~~~json
        {"ok": true}
        """

        #expect(DiaryMarkdownParser.parse(markdown) == [
            .codeBlock(language: "json", code: "{\"ok\": true}")
        ])
    }
}
