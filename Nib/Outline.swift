import SwiftUI

struct OutlineItem: Identifiable, Equatable {
    /// 第几个标题，跳转时按它对应。
    let index: Int
    let level: Int
    let text: String
    var id: Int { index }
}

/// 标题栏组里的一项：20 点高，悬停或面板打开时垫一层浅底，和标签条、模式切换同一套外形。
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

/// 大纲按钮：点开是标题列表，当前一节高亮，点一项滚过去，面板不关，可以连着跳。
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
    /// 收起的标题（按 index）。面板关了再开会全部展开，和 Typora 一样只在这一次查看里有效。
    @State private var collapsed = Set<Int>()

    private var items: [OutlineItem] { controller.outline }
    /// 最浅的那级顶格，其余按相对层级缩进。
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

    /// 当前一节；它被收起时落到可见的上级。
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
