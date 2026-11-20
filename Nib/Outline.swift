import SwiftUI

struct OutlineItem: Identifiable, Equatable {
    /// Index of the heading, used to match it when jumping.
    let index: Int
    let level: Int
    let text: String
    var id: Int { index }
}

/// One item in the title-bar group: 20 pt high, with a light fill on hover or when the panel is open, the same shape as the tab strip and mode switch.
struct TitlebarItem<Label: View>: View {
    var active = false
    let help: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(minWidth: 30, minHeight: TabMetrics.height)
                .background(Capsule(style: .continuous).fill(Color.primary.opacity(active ? 0.1 : (hovering ? 0.05 : 0))))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Outline button: opens the heading list, the current section is highlighted, clicking an item scrolls to it, and the panel stays open so you can jump repeatedly.
struct OutlineButton: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        TitlebarItem(active: controller.showOutline, help: "Outline", action: { controller.showOutline.toggle() }) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 13))
                .foregroundStyle(controller.showOutline ? .primary : .secondary)
        }
        .accessibilityLabel(Text("Outline"))
        .popover(isPresented: $controller.showOutline, arrowEdge: .bottom) {
            OutlinePanel(controller: controller)
        }
    }
}

private struct OutlinePanel: View {
    @ObservedObject var controller: EditorController
    /// Collapsed headings (by index). Closing and reopening the panel expands all, like Typora: only valid within one viewing.
    @State private var collapsed = Set<Int>()

    private var items: [OutlineItem] { controller.outline }
    /// The shallowest level is flush left; the rest are indented by relative level.
    private var baseLevel: Int { items.map(\.level).min() ?? 1 }

    var body: some View {
        Group {
            if items.isEmpty {
                Text("No headings")
                    .foregroundStyle(.secondary)
                    .frame(width: 280, height: 80)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(visible) { item in row(item).id(item.index) }
                        }
                        .padding(8)
                    }
                    .frame(width: 300)
                    .frame(maxHeight: 520)
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
    }

    /// The current section; when it is collapsed, falls back to its visible ancestor.
    private var current: Int {
        var index = controller.outlineCurrent
        while index >= 0, !visible.contains(where: { $0.index == index }) { index = parent(of: index) ?? -1 }
        return index
    }

    private var visible: [OutlineItem] {
        var out: [OutlineItem] = []
        var hideBelow: Int?
        for item in items {
            if let level = hideBelow {
                if item.level > level { continue }
                hideBelow = nil
            }
            out.append(item)
            if collapsed.contains(item.index) { hideBelow = item.level }
        }
        return out
    }

    private func hasChildren(_ item: OutlineItem) -> Bool {
        let next = item.index + 1
        return next < items.count && items[next].level > item.level
    }

    private func parent(of index: Int) -> Int? {
        guard index < items.count else { return nil }
        let level = items[index].level
        return items[..<index].last(where: { $0.level < level })?.index
    }

    private func row(_ item: OutlineItem) -> some View {
        let selected = item.index == current
        let indent = CGFloat(item.level - baseLevel) * 14
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Group {
                if hasChildren(item) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed.contains(item.index) ? 0 : 90))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) {
                                if collapsed.contains(item.index) { collapsed.remove(item.index) } else { collapsed.insert(item.index) }
                            }
                        }
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            Text(item.text.isEmpty ? " " : item.text)
                .font(.system(size: 13, weight: item.level == baseLevel ? .semibold : .regular))
                .foregroundStyle(selected ? Color.primary : (item.level > baseLevel + 1 ? .secondary : .primary))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, indent + 4)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor.opacity(0.16) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { controller.run("nib.gotoHeading(\(item.index))") }
    }
}
