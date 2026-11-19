import Combine
import SwiftUI

/// Nib 自己管标签，不用系统标签组：系统标签组在两个以上标签时强制显示自带标签栏，顶部就成了两行。
/// 每篇文档仍是一个独立的 NSDocument 窗口，保存、Versions 照旧；一组标签叠在同一位置，只有选中的那个在屏幕上，其余收起来。
@MainActor
final class WindowTabs {
    static let shared = WindowTabs()
    static let changed = Notification.Name("NibTabsChanged")

    private final class Group {
        var windows: [NSWindow] = []
        weak var selected: NSWindow?
    }

    private var groups: [Group] = []
    /// 正在改名的文档窗口（标签条显示输入框）。
    weak var renaming: NSWindow? { didSet { if oldValue !== renaming { post() } } }
    private weak var lastActive: Group?
    /// 关掉的标签，后关的在最后，⇧⌘T 按这个顺序重新打开。没存过的新文档没有路径，不记。
    private var closedURLs: [URL] = []
    /// 批量关闭时等未保存询问框收起的监听，按窗口存，用完即删。
    private var sheetObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// 新窗口上屏前后系统会让新旧窗口轮流成为焦点，这段时间不把焦点变化当成切标签。
    private var adopting = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { WindowTabs.shared.remove(window) }
        }
        // 从「窗口」菜单或别处把收起的标签叫到前面，也当作切到它。
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { WindowTabs.shared.didActivate(window) }
        }
    }

    /// 新文档窗口进来：并进当前在用的那组，放在选中标签后面，叠到同一位置。
    func adopt(_ window: NSWindow) {
        guard group(of: window) == nil else { return }
        ExplicitSave.apply(to: window)
        window.tabbingMode = .disallowed
        // 切标签是收起一个、摆出另一个，系统的窗口弹出动画会让它看起来像开了新窗口。
        window.animationBehavior = .none
        // 刚打开的这篇会被记进「最近使用」；设置里关了就清掉。窗口能否恢复也在这里跟设置对齐。
        AppSettings.applyHistory(window: window)
        AppSettings.applyChrome(window)
        guard let target = activeGroup(), let current = target.selected, current !== window else {
            let group = Group()
            group.windows = [window]
            group.selected = window
            groups.append(group)
            lastActive = group
            post()
            return
        }
        let index = target.windows.firstIndex { $0 === current }.map { $0 + 1 } ?? target.windows.count
        target.windows.insert(window, at: index)
        target.selected = window
        lastActive = target
        let frame = current.frame
        window.setFrame(frame, display: false)
        // 系统会先把新窗口错开摆一下（层叠），先透明，对齐之后再显形，不然能看到它跳一下。
        window.alphaValue = 0
        adopting += 1
        NibApp.log("tabs adopt, group size \(target.windows.count)")
        DispatchQueue.main.async {
            self.adopting -= 1
            guard target.selected === window else {
                window.alphaValue = 1
                return
            }
            window.setFrame(frame, display: true)
            window.makeKeyAndOrderFront(nil)
            // 层叠可能在这之后才生效，下一拍再对齐一次，然后显形、收起旧的。
            DispatchQueue.main.async {
                if window.frame != frame { window.setFrame(frame, display: true) }
                window.alphaValue = 1
                for other in target.windows where other !== window && other.isVisible { other.orderOut(nil) }
                self.post()
            }
        }
    }

    func tabs(for window: NSWindow) -> (windows: [NSWindow], selected: NSWindow?) {
        guard let group = group(of: window) else { return ([window], window) }
        return (group.windows, group.selected)
    }

    /// 这个窗口是不是所在组里正显示的那个。
    func isSelected(_ window: NSWindow) -> Bool {
        guard let group = group(of: window) else { return true }
        return group.selected === window
    }

    func select(_ window: NSWindow) {
        guard let group = group(of: window) else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        lastActive = group
        guard let current = group.selected, current !== window else {
            window.makeKeyAndOrderFront(nil)
            return
        }
        group.selected = window
        window.setFrame(current.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        current.orderOut(nil)
        post()
    }

    /// 切到前一个或后一个标签，到头了绕回另一端。
    func selectAdjacent(_ offset: Int) {
        guard let group = activeGroup(), group.windows.count > 1, let current = group.selected,
              let index = group.windows.firstIndex(where: { $0 === current }) else { return }
        let count = group.windows.count
        select(group.windows[(index + offset + count) % count])
    }

    /// ⌘1 到 ⌘8 按位置切，⌘9 去最后一个。
    func select(number: Int) {
        guard let group = activeGroup(), !group.windows.isEmpty else { return }
        let index = number == 9 ? group.windows.count - 1 : number - 1
        guard index < group.windows.count else { return }
        NibApp.log("select tab \(number) of \(group.windows.count)")
        select(group.windows[index])
    }

    /// 关标签。收起的标签先切过来再关：有未保存改动时询问框要挂在看得见的窗口上。
    func close(_ window: NSWindow) {
        select(window)
        window.performClose(nil)
    }

    /// 关掉组里除它以外的标签（only = nil 时只关它右边的）。先把它摆出来，其余都在后台。
    /// 有未保存改动的一个个切过来问，用户点了取消就停下，后面的不再关。
    func closeOthers(keeping window: NSWindow, rightOnly: Bool) {
        guard let group = group(of: window), let index = group.windows.firstIndex(where: { $0 === window }) else { return }
        let targets = rightOnly ? Array(group.windows[(index + 1)...]) : group.windows.filter { $0 !== window }
        select(window)
        closeInTurn(targets, thenSelect: window)
    }

    private func closeInTurn(_ list: [NSWindow], thenSelect keep: NSWindow) {
        guard let window = list.first else {
            select(keep)
            return
        }
        let rest = Array(list.dropFirst())
        guard window.isDocumentEdited else {
            window.performClose(nil)
            closeInTurn(rest, thenSelect: keep)
            return
        }
        select(window)
        let key = ObjectIdentifier(window)
        sheetObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.didEndSheetNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                let tabs = WindowTabs.shared
                if let token = tabs.sheetObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(token) }
                // 询问框收起后窗口要下一拍才真正关掉；还在就是用户取消了，停在它上面。
                DispatchQueue.main.async {
                    guard tabs.group(of: window) == nil else { return }
                    tabs.closeInTurn(rest, thenSelect: keep)
                }
            }
        }
        window.performClose(nil)
    }

    /// ⇧⌘T：重新打开最近关掉的标签。文件已被删掉或移走的跳过，接着往前找；已经开着的系统只会把它切到前面。
    func reopenClosed() {
        while let url = closedURLs.popLast() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            NibApp.log("reopen closed tab")
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return
        }
    }

    private func didActivate(_ window: NSWindow) {
        guard adopting == 0, let group = group(of: window) else { return }
        lastActive = group
        if group.selected !== window { select(window) }
    }

    private func remove(_ window: NSWindow) {
        guard let group = group(of: window), let index = group.windows.firstIndex(where: { $0 === window }) else { return }
        if let url = NSDocumentController.shared.document(for: window)?.fileURL {
            closedURLs.removeAll { $0 == url }
            closedURLs.append(url)
        }
        group.windows.remove(at: index)
        if group.windows.isEmpty {
            groups.removeAll { $0 === group }
        } else if group.selected === window || group.selected == nil {
            // 关的是正显示的标签：在它消失前把旁边那个摆出来，屏幕上始终有窗口，app 不会误判成全关了。
            let next = group.windows[min(index, group.windows.count - 1)]
            group.selected = next
            next.setFrame(window.frame, display: true)
            next.makeKeyAndOrderFront(nil)
        }
        post()
    }

    private func group(of window: NSWindow) -> Group? {
        groups.first { $0.windows.contains { $0 === window } }
    }

    private func activeGroup() -> Group? {
        for window in [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }) {
            if let group = group(of: window) { return group }
        }
        if let lastActive, groups.contains(where: { $0 === lastActive }) { return lastActive }
        return groups.last
    }

    private func post() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

/// 一个窗口顶部标签条的数据。
@MainActor
final class TabStripModel: ObservableObject {
    struct Tab: Equatable {
        let id: ObjectIdentifier
        let title: String
        let edited: Bool
        let selected: Bool
        /// 未保存过的新文档没有路径，右键菜单里的路径项置灰。
        let url: URL?
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var windowWidth: CGFloat = 860
    private weak var window: NSWindow?
    private var windows: [ObjectIdentifier: NSWindow] = [:]
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        // didUpdate 很密，但只在内容变了才发布，代价是比较几个字符串；改名、未保存点、窗口宽度都靠它跟上。
        let names: [Notification.Name] = [WindowTabs.changed, NSWindow.didUpdateNotification, NSWindow.didResizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        guard let window else { return }
        let (list, selected) = WindowTabs.shared.tabs(for: window)
        windows = Dictionary(uniqueKeysWithValues: list.map { (ObjectIdentifier($0), $0) })
        let next = list.map { Tab(id: ObjectIdentifier($0), title: $0.title, edited: $0.isDocumentEdited, selected: $0 === selected,
                                     url: NSDocumentController.shared.document(for: $0)?.fileURL) }
        if next != tabs { tabs = next }
        let editing = WindowTabs.shared.renaming.map(ObjectIdentifier.init)
        if editing != renaming { renaming = editing }
        if window.frame.width != windowWidth { windowWidth = window.frame.width }
    }

    /// 标签条总宽：每个最多 180，且不超过窗口里居中能放下的宽度（两侧各让出模式切换那么宽，合计约 300）。
    var stripWidth: CGFloat {
        // 只有一篇时只显示文档图标和文件名（照 Typora），给长文件名多留些宽度。
        if tabs.count <= 1 { return max(60, min(420, windowWidth - 300)) }
        let count = CGFloat(max(tabs.count, 1))
        return max(60, min(count * 180 + (count - 1) + TabMetrics.inset * 2, windowWidth - 300))
    }

    /// 平分够宽（≥90）就平分；不够时选中的留 120 让标题看得清，其余平分剩下的，像 Safari 一样挤窄。
    func tabWidth(selected: Bool) -> CGFloat {
        let count = CGFloat(max(tabs.count, 1))
        let available = stripWidth - (count - 1) - TabMetrics.inset * 2
        let even = available / count
        if even >= 90 || tabs.count == 1 { return min(180, even) }
        let first = min(120, available * 0.5)
        return selected ? first : (available - first) / (count - 1)
    }

    func select(_ id: ObjectIdentifier) {
        if let target = windows[id] { WindowTabs.shared.select(target) }
    }

    func close(_ id: ObjectIdentifier) {
        if let target = windows[id] { WindowTabs.shared.close(target) }
    }

    /// 正在改名的标签。状态记在 WindowTabs 上：改的是没选中的标签时要先切过去，切过去后显示的是另一个窗口的标签条。
    @Published private(set) var renaming: ObjectIdentifier?

    func beginRename(_ id: ObjectIdentifier) {
        guard let target = windows[id] else { return }
        WindowTabs.shared.renaming = target
        select(id)
        refresh()
    }

    func finishRename(_ id: ObjectIdentifier, to name: String?) {
        WindowTabs.shared.renaming = nil
        refresh()
        guard let name, let target = windows[id] else { return }
        DocumentRename.rename(target, to: name)
    }

    func closeOthers(_ id: ObjectIdentifier, rightOnly: Bool) {
        if let target = windows[id] { WindowTabs.shared.closeOthers(keeping: target, rightOnly: rightOnly) }
    }

    func hasTabsToRight(of id: ObjectIdentifier) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index < tabs.count - 1
    }
}

/// 标签条直接挂在标题栏上，不放进工具栏：工具栏按旧宽度判断放不下时，会把它连同模式切换整个收进「»」，之后不再恢复。
/// 挂在标题栏上宽度由自己算，永远放得下。
@MainActor
enum TabStripInstaller {
    static let backdropID = NSUserInterfaceItemIdentifier("NibTitlebarBackdrop")
    private static var installed = Set<ObjectIdentifier>()
    private static var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]

    static func install(in window: NSWindow, controller: EditorController) {
        guard !installed.contains(ObjectIdentifier(window)),
              let close = window.standardWindowButton(.closeButton), let titlebar = close.superview else { return }
        installed.insert(ObjectIdentifier(window))
        let model = TabStripModel(window: window)
        let host = NSHostingView(rootView: TabStrip(model: model))
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(host)
        NSLayoutConstraint.activate([
            host.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            host.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: TabMetrics.height + TabMetrics.inset * 2),
        ])
        // 宽度跟着标签条走，不多占：标题栏其余空白处还要能拖动窗口。
        let width = host.widthAnchor.constraint(equalToConstant: model.stripWidth)
        width.isActive = true
        let subscription = model.objectWillChange.sink { [weak model] in
            DispatchQueue.main.async { if let model { width.constant = model.stripWidth } }
        }
        subscriptions[ObjectIdentifier(window)] = subscription

        // 模式切换也挂在标题栏右侧，同理：放在工具栏里窗口一窄就会被收进「»」。
        let hover = TitlebarHover()
        let tracker = TitlebarTracker(hover: hover)
        tracker.frame = titlebar.bounds
        tracker.autoresizingMask = [.width, .height]
        titlebar.addSubview(tracker, positioned: .below, relativeTo: nil)
        let modes = NSHostingView(rootView: TitlebarTools(controller: controller, hover: hover))
        modes.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(modes)
        NSLayoutConstraint.activate([
            modes.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -12),
            modes.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                installed.remove(ObjectIdentifier(window))
                subscriptions[ObjectIdentifier(window)] = nil
            }
        }
    }
}

/// 鼠标是否在标题栏上。右侧工具照 Typora：平时藏着，移到标题栏才出现（设置里可改成常驻）。
@MainActor
final class TitlebarHover: ObservableObject {
    @Published var inside = false
}

/// 铺满标题栏、垫在最底下的透明视图，只用来感知鼠标进出。上面盖着的标签条、按钮不影响判断。
final class TitlebarTracker: NSView {
    let hover: TitlebarHover

    init(hover: TitlebarHover) {
        self.hover = hover
        super.init(frame: .zero)
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseEntered(with event: NSEvent) { hover.inside = true }
    override func mouseExited(with event: NSEvent) { hover.inside = false }
}

/// 标题栏右侧一组：字数、大纲、编辑开关（11-19 Felix 定：三段模式切换缩成一个开关，源码模式走 ⌘/ 和菜单，照 Typora 的简洁）。
/// 平时藏起来，鼠标进标题栏或面板开着时才出现（照 Typora）。
struct TitlebarTools: View {
    @ObservedObject var controller: EditorController
    @ObservedObject var hover: TitlebarHover
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let visible = settings.alwaysShowTools || hover.inside || controller.showOutline || controller.showWordCount
        HStack(spacing: 2) {
            WordCountButton(controller: controller)
            OutlineButton(controller: controller)
            EditToggle(controller: controller)
        }
        .padding(TabMetrics.inset)
        .modifier(GlassCapsule())
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: visible ? 0.12 : 0.25), value: visible)
    }
}

/// 编辑开关：阅读时点它进编辑，编辑或源码时点它回阅读；处在编辑或源码时按钮垫底色表示「开着」。
/// 源码模式时图标换成源码符号，看得出现在是哪种。
struct EditToggle: View {
    @ObservedObject var controller: EditorController

    var body: some View {
        let editing = controller.mode != .read
        TitlebarItem(active: editing, help: editing ? "Done Editing" : "Edit", action: {
            controller.setMode(editing ? .read : .edit)
        }) {
            Image(systemName: controller.mode == .source ? "chevron.left.forwardslash.chevron.right" : "square.and.pencil")
                .font(.system(size: 13))
                .foregroundStyle(editing ? .primary : .secondary)
        }
        .accessibilityLabel(Text("Edit"))
        .accessibilityAddTraits(editing ? [.isButton, .isSelected] : .isButton)
    }
}

/// 标签条的外形跟右边的模式切换对齐：同样的胶囊、同样的选中底色和高度。
enum TabMetrics {
    // 实测模式切换：外框 24 点，选中块 20 点。
    static let height: CGFloat = 20
    static let inset: CGFloat = 2
}

struct TabStrip: View {
    @ObservedObject var model: TabStripModel
    @State private var hovered: ObjectIdentifier?

    var body: some View {
        if model.tabs.count == 1, let tab = model.tabs.first {
            DocumentTitle(tab: tab, renaming: model.renaming == tab.id, finish: { model.finishRename(tab.id, to: $0) })
                .onTapGesture(count: 2) { model.beginRename(tab.id) }
                .contextMenu { TabMenu(tab: tab, model: model) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            strip
        }
    }

    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(Array(model.tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { separator(between: model.tabs[index - 1], and: tab) }
                TabButton(tab: tab, width: model.tabWidth(selected: tab.selected), single: model.tabs.count == 1, hovering: hovered == tab.id,
                          select: { model.select(tab.id) }, close: { model.close(tab.id) },
                          renaming: model.renaming == tab.id, rename: { model.beginRename(tab.id) },
                          finish: { model.finishRename(tab.id, to: $0) })
                    .contextMenu { TabMenu(tab: tab, model: model) }
                    .onHover { inside in
                        if inside { hovered = tab.id } else if hovered == tab.id { hovered = nil }
                    }
            }
        }
        .padding(TabMetrics.inset)
        .modifier(GlassCapsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 标签之间的细竖线；挨着选中或悬停的标签就不画，和系统分段控件一样。
    private func separator(between left: TabStripModel.Tab, and right: TabStripModel.Tab) -> some View {
        let hidden = left.selected || right.selected || hovered == left.id || hovered == right.id
        return Rectangle()
            .fill(Color.primary.opacity(hidden ? 0 : 0.12))
            .frame(width: 1, height: 14)
    }
}

private struct TabButton: View {
    let tab: TabStripModel.Tab
    let width: CGFloat
    /// 只有一个标签时它只是标题，不画选中底色，也没有关闭按钮（关窗口用红灯或 ⌘W）。
    let single: Bool
    let hovering: Bool
    let select: () -> Void
    let close: () -> Void
    var renaming = false
    var rename: () -> Void = {}
    var finish: (String?) -> Void = { _ in }

    var body: some View {
        ZStack {
            if renaming {
                RenameField(initial: tab.title, finish: finish)
                    .padding(.horizontal, 22)
            } else {
            Text(tab.title)
                .font(.system(size: 12, weight: tab.selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tab.selected ? .primary : .secondary)
                // 窄标签让出给关闭按钮的边距，太窄（<40）干脆不放字，免得只剩一个省略号。
                .padding(.horizontal, min(24, width * 0.2))
                .opacity(width < 40 ? 0 : 1)
            }
            // 左边一格：悬停时是关闭，有未保存改动时是圆点，标题始终居中不跳。
            HStack {
                if hovering && !single {
                    CloseButton(action: close)
                } else if tab.edited {
                    Circle().fill(.secondary).frame(width: 6, height: 6).frame(width: 18)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
        }
        .frame(width: width, height: TabMetrics.height)
        .background(
            Capsule(style: .continuous)
                .fill(Color.primary.opacity(single ? 0 : (tab.selected ? 0.1 : (hovering ? 0.05 : 0))))
        )
        .contentShape(Capsule(style: .continuous))
        // 双击改名（照访达和 Safari 标签组）；单击照常切换。
        .onTapGesture(count: 2, perform: rename)
        .onTapGesture(perform: select)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.edited ? Text("\(tab.title), Edited") : Text(tab.title))
        .accessibilityAddTraits(tab.selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: Text("Close Tab"), close)
        .accessibilityAction(named: Text("Rename…"), rename)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: tab.selected)
    }
}

/// 只有一篇文档时的标题：文档图标加文件名，不画胶囊，和系统标题栏、Typora 一样。未保存时文件名后面跟「已编辑」。
private struct DocumentTitle: View {
    let tab: TabStripModel.Tab
    let renaming: Bool
    let finish: (String?) -> Void

    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: icon).resizable().frame(width: 15, height: 15)
            if renaming {
                RenameField(initial: tab.title, finish: finish).frame(width: 220)
            } else {
            Text(tab.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            if tab.edited && !renaming {
                Text("— Edited").font(.system(size: 13)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var icon: NSImage {
        if let url = tab.url { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .markdownDocument)
    }
}

/// 标签右键菜单：关闭类在上，路径类在下，和 Safari 的标签菜单一个顺序。
private struct TabMenu: View {
    let tab: TabStripModel.Tab
    let model: TabStripModel

    var body: some View {
        Button("Rename…") { model.beginRename(tab.id) }
        Divider()
        Button("Close Tab") { model.close(tab.id) }
        Button("Close Other Tabs") { model.closeOthers(tab.id, rightOnly: false) }
            .disabled(model.tabs.count < 2)
        Button("Close Tabs to the Right") { model.closeOthers(tab.id, rightOnly: true) }
            .disabled(!model.hasTabsToRight(of: tab.id))
        Divider()
        Button("Copy Path") {
            guard let path = tab.url?.path else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
        .disabled(tab.url == nil)
        Button("Reveal in Finder") {
            if let url = tab.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .disabled(tab.url == nil)
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Close Tab")
    }
}

/// 和工具栏里模式切换一样的玻璃胶囊底。macOS 26 起用系统的 Liquid Glass，更早的系统退回半透明材质。
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content.background(.regularMaterial, in: Capsule(style: .continuous))
        }
    }
}
