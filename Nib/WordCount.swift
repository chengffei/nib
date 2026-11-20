import SwiftUI

/// Statistics for a piece of text; the counting rules are in Web/src/wordCount.js (like Typora: one Chinese character counts as one word, and Markdown symbols are not counted).
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

    /// Reading time in minutes, rounded up to one minute at least.
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

    /// The "5765 words" on the button. The four are written separately so that they go through localization.
    func label(_ n: Int) -> Text {
        switch self {
        case .words: Text("\(n) words")
        case .chars: Text("\(n) characters")
        case .lines: Text("\(n) lines")
        case .minutes: Text("\(n) min")
        }
    }
}

/// The word-count button on the right of the title bar: shows the chosen item, or the selection's figure (in accent colour) when text is selected; clicking opens the full statistics, and clicking a row changes what the button shows.
/// The outer frame is drawn by TitlebarTools; this is just one item in the group.
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
