import AppKit
import Markdown

/// 源码模式染色：只改属性不改字符，撤销栈与光标都不受影响。
/// 阶段 1 每次全篇重解析；增量按块解析是 §4.1 的要求，留到性能验收时做。
enum MarkdownHighlighter {
    enum Style: Equatable {
        case heading, strong, emphasis, strikethrough
        case inlineCode, codeBlock, html
        case link, image, blockQuote, thematicBreak
    }

    struct Run: Equatable {
        let range: NSRange
        let style: Style
    }

    static var baseFont: NSFont { .monospacedSystemFont(ofSize: 14, weight: .regular) }
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.clear]
    }

    /// 解析并产出染色区段。纯函数，方便测试。
    static func runs(for source: String) -> [Run] {
        let document = Document(parsing: source)
        var collector = Collector(map: SourceOffsetMap(source))
        collector.visit(document)
        return collector.runs
    }

    @MainActor
    static func apply(to storage: NSTextStorage) {
        let source = storage.string
        let runs = runs(for: source)
        storage.beginEditing()
        storage.setAttributes(baseAttributes, range: NSRange(location: 0, length: storage.length))
        for run in runs {
            storage.addAttributes(attributes(for: run.style), range: run.range)
        }
        storage.endEditing()
    }

    static func attributes(for style: Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading:
            return [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: NSColor.controlAccentColor]
        case .strong:
            return [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
        case .emphasis:
            return [.font: NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)]
        case .strikethrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: NSColor.secondaryLabelColor]
        case .inlineCode, .codeBlock:
            return [.backgroundColor: NSColor.quaternarySystemFill]
        case .html:
            return [.foregroundColor: NSColor.tertiaryLabelColor]
        case .link, .image:
            return [.foregroundColor: NSColor.linkColor]
        case .blockQuote:
            return [.foregroundColor: NSColor.secondaryLabelColor]
        case .thematicBreak:
            return [.foregroundColor: NSColor.tertiaryLabelColor]
        }
    }

    private struct Collector: MarkupWalker {
        let map: SourceOffsetMap
        var runs: [Run] = []

        private mutating func add(_ markup: Markup, _ style: Style) {
            if let range = markup.range, let nsRange = map.nsRange(of: range) {
                runs.append(Run(range: nsRange, style: style))
            }
        }

        mutating func visitHeading(_ h: Heading) { add(h, .heading); descendInto(h) }
        mutating func visitStrong(_ s: Strong) { add(s, .strong); descendInto(s) }
        mutating func visitEmphasis(_ e: Emphasis) { add(e, .emphasis); descendInto(e) }
        mutating func visitStrikethrough(_ s: Strikethrough) { add(s, .strikethrough); descendInto(s) }
        mutating func visitInlineCode(_ c: InlineCode) { add(c, .inlineCode) }
        mutating func visitCodeBlock(_ c: CodeBlock) { add(c, .codeBlock) }
        mutating func visitHTMLBlock(_ h: HTMLBlock) { add(h, .html) }
        mutating func visitInlineHTML(_ h: InlineHTML) { add(h, .html) }
        mutating func visitLink(_ l: Link) { add(l, .link); descendInto(l) }
        mutating func visitImage(_ i: Image) { add(i, .image) }
        mutating func visitBlockQuote(_ b: BlockQuote) { add(b, .blockQuote); descendInto(b) }
        mutating func visitThematicBreak(_ t: ThematicBreak) { add(t, .thematicBreak) }
    }
}
