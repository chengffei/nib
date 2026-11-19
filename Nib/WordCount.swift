import SwiftUI

/// 一段文字的统计，口径见 Web/src/wordCount.js（照 Typora：一个汉字算一个词，词数不算 Markdown 符号）。
struct TextStats: Equatable {
    var words = 0
    var chars = 0
    var lines = 0

    init() {}

    init(_ body: [String: Any]) {
        words = body["words"] as? Int ?? 0
        chars = body["chars"] as? Int ?? 0
        lines = body["lines"] as? Int ?? 0
    }

    /// 阅读时间（分钟），不足一分钟按一分钟。
    func minutes(speed: Int) -> Int {
        words == 0 ? 0 : max(1, Int((Double(words) / Double(max(speed, 1))).rounded()))
    }

    func value(_ unit: WordCountUnit, speed: Int) -> Int {
        switch unit {
        case .words: words
        case .chars: chars
        case .lines: lines
        case .minutes: minutes(speed: speed)
        }
    }
}

enum WordCountUnit: String, CaseIterable, Identifiable {
    case words, chars, lines, minutes
    var id: String { rawValue }

    var name: LocalizedStringKey {
        switch self {
        case .words: "Words"
        case .chars: "Characters"
        case .lines: "Lines"
        case .minutes: "Reading Time"
        }
    }

    /// 按钮上的「5765 词」。四个分开写才走本地化。
    func label(_ n: Int) -> Text {
        switch self {
        case .words: Text("\(n) words")
        case .chars: Text("\(n) characters")
        case .lines: Text("\(n) lines")
        case .minutes: Text("\(n) min")
        }
    }
}

/// 标题栏右侧的字数按钮：显示选定的一项，选中文字时显示选中部分（强调色）；点开列出全部统计，点一行换按钮上显示的那项。
/// 外框由 TitlebarTools 统一画，这里只是组里的一项。
struct WordCountButton: View {
    @ObservedObject var controller: EditorController
    @ObservedObject private var settings = AppSettings.shared

    private var unit: WordCountUnit { WordCountUnit(rawValue: settings.wordCountUnit) ?? .words }

    var body: some View {
        let shown = controller.selectionStats ?? controller.stats
        TitlebarItem(active: controller.showWordCount, help: "Word Count", action: { controller.showWordCount.toggle() }) {
            unit.label(shown.value(unit, speed: settings.readingSpeed))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(controller.selectionStats == nil ? .secondary : Color.accentColor)
                .padding(.horizontal, 10)
        }
        .popover(isPresented: $controller.showWordCount, arrowEdge: .bottom) {
            WordCountPanel(controller: controller, settings: settings)
        }
    }
}

private struct WordCountPanel: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var settings: AppSettings

    var body: some View {
        let selection = controller.selectionStats
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 6) {
            if selection != nil {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Selection").foregroundStyle(.secondary)
                    Text("Document").foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            ForEach(WordCountUnit.allCases) { unit in
                let current = settings.wordCountUnit == unit.rawValue
                GridRow {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).opacity(current ? 1 : 0)
                        Text(unit.name)
                    }
                    .fixedSize()
                    .gridColumnAlignment(.leading)
                    if let selection { cell(selection, unit) }
                    cell(controller.stats, unit)
                }
                .contentShape(Rectangle())
                .onTapGesture { settings.wordCountUnit = unit.rawValue }
            }
        }
        .font(.system(size: 13))
        .fixedSize()
        .padding(14)
    }

    private func cell(_ stats: TextStats, _ unit: WordCountUnit) -> some View {
        let value = stats.value(unit, speed: settings.readingSpeed)
        return (unit == .minutes ? unit.label(value) : Text(verbatim: value.formatted())).monospacedDigit()
    }
}
