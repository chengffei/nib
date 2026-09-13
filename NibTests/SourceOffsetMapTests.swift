import Foundation
import Testing
@testable import Nib

@Suite struct SourceOffsetMapTests {
    private func run(_ source: String, _ style: MarkdownHighlighter.Style) -> String? {
        guard let run = MarkdownHighlighter.runs(for: source).first(where: { $0.style == style }) else { return nil }
        return (source as NSString).substring(with: run.range)
    }

    @Test func strongInsideCJK() {
        #expect(run("中文混排 **粗体** 之后", .strong) == "**粗体**")
    }

    @Test func headingAfterCJKLines() {
        let source = "第一行中文\n第二行 émoji 🙂 混排\n## 标题 Two\n正文"
        #expect(run(source, .heading) == "## 标题 Two")
    }

    @Test func inlineCodeAfterAstralPlaneCharacter() {
        // 🙂 是 4 字节 UTF-8 / 2 个 UTF-16 码元，最容易把偏移算错
        #expect(run("🙂 `code` 后缀", .inlineCode) == "`code`")
    }

    @Test func crlfLineEndings() {
        #expect(run("行一\r\n行二\r\n# 标题\r\n", .heading) == "# 标题")
    }

    @Test func linkAndFencedCode() {
        let source = "看 [链接](https://a.b) 吧\n\n```swift\nlet x = 1\n```\n"
        #expect(run(source, .link) == "[链接](https://a.b)")
        #expect(run(source, .codeBlock) == "```swift\nlet x = 1\n```")
    }

    @Test func rangesNeverExceedLength() {
        let source = "# a\n**b** *c* ~~d~~ `e` [f](g) ![h](i)\n> j\n\n---\n<div>k</div>\n"
        let length = (source as NSString).length
        for run in MarkdownHighlighter.runs(for: source) {
            #expect(NSMaxRange(run.range) <= length)
        }
    }
}
