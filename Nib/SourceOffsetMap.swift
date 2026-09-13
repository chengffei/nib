import Foundation
import Markdown

/// swift-markdown 的 SourceLocation 是 1-based 行号 + 1-based UTF-8 字节列号；
/// NSTextStorage 用 UTF-16 偏移。此表做一次换算，每行起点预算好，单点换算 O(行内长度)。
struct SourceOffsetMap {
    private let string: String
    private let lineStartIndex: [String.Index]
    private let lineStartUTF16: [Int]

    init(_ string: String) {
        self.string = string
        var starts: [String.Index] = [string.startIndex]
        var utf16Starts: [Int] = [0]
        var utf16Count = 0
        var i = string.utf8.startIndex
        let utf8 = string.utf8
        while i < utf8.endIndex {
            let byte = utf8[i]
            // 只在 UTF-8 起始字节处累加 UTF-16 长度：ASCII 1、2/3 字节序列 1、4 字节序列 2
            if byte & 0xC0 != 0x80 {
                utf16Count += byte >= 0xF0 ? 2 : 1
            }
            i = utf8.index(after: i)
            if byte == UInt8(ascii: "\n") {
                starts.append(i)
                utf16Starts.append(utf16Count)
            }
        }
        lineStartIndex = starts
        lineStartUTF16 = utf16Starts
    }

    func utf16Offset(of location: SourceLocation) -> Int? {
        let lineIndex = location.line - 1
        guard lineIndex >= 0, lineIndex < lineStartIndex.count else { return nil }
        let lineStart = lineStartIndex[lineIndex]
        guard let index = string.utf8.index(lineStart, offsetBy: location.column - 1, limitedBy: string.endIndex)
        else { return nil }
        return lineStartUTF16[lineIndex] + string.utf16.distance(from: lineStart, to: index)
    }

    func nsRange(of range: SourceRange) -> NSRange? {
        guard let start = utf16Offset(of: range.lowerBound),
              let end = utf16Offset(of: range.upperBound),
              end >= start
        else { return nil }
        return NSRange(location: start, length: end - start)
    }
}
