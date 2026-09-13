import Foundation
import Testing
@testable import Nib

@Suite struct HighlighterPerformanceTests {
    /// §4.1 要求增量解析；阶段 1 先量一下全篇重解析在 2 万行上的成本，作为后续增量改造的基线。
    @Test func fullReparseOf20kLines() {
        let paragraph = "第 %d 段：中英混排 **粗体** 与 `code`，还有 [链接](https://example.com) 和 *强调*。\n\n"
        var source = ""
        for i in 0..<10_000 { source += String(format: paragraph, i) }
        let lineCount = source.split(separator: "\n", omittingEmptySubsequences: false).count
        let start = ContinuousClock.now
        let runs = MarkdownHighlighter.runs(for: source)
        let elapsed = ContinuousClock.now - start
        print("PERF lines=\(lineCount) runs=\(runs.count) elapsed=\(elapsed)")
        #expect(runs.count == 40_000)
        #expect(elapsed < .seconds(2))
    }
}
