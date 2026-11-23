import Combine
import SwiftUI

/// Nib manages its own tabs instead of using system tab groups: with two or more tabs the system forces its own tab bar, which would make the top two rows tall.
/// Each document is still its own NSDocument window (saving and Versions are unchanged); the tabs of a group are stacked in the same spot, only the selected one is on screen and the rest are tucked away.
@MainActor
final class WindowTabs {
    static let shared = WindowTabs()
    static let changed = Notification.Name("NibTabsChanged")

    private final class Group {
        var windows: [NSWindow] = []
        weak var selected: NSWindow?
    }

    private var groups: [Group] = []
    /// The document window being renamed (the tab strip shows a text field).
    weak var renaming: NSWindow? { didSet { if oldValue !== renaming { post() } } }
    private weak var lastActive: Group?
    /// Closed tabs, most recent last; ⇧⌘T reopens them in that order. New unsaved documents have no path and are not recorded.
    private var closedURLs: [URL] = []
    /// Observers that wait for the unsaved-changes sheet to go away during a bulk close, keyed by window and removed after use.
    private var sheetObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    /// When a new window comes on screen the system makes old and new windows take focus in turn; focus changes in this period are not treated as tab switches.
    private var adopting = 0

    private init() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { WindowTabs.shared.remove(window) }
        }
        // A tucked-away tab brought to the front from the Window menu or elsewhere also counts as switching to it.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { WindowTabs.shared.didActivate(window) }
        }
    }

    /// A new document window arrives: join the group currently in use, placed after the selected tab and stacked in the same spot.
    func adopt(_ window: NSWindow) {
        guard group(of: window) == nil else { return }
        AppDelegate.showInDock()
        ExplicitSave.apply(to: window)
        window.tabbingMode = .disallowed
        // Switching tabs hides one window and shows another; the system's window pop-up animation would make it look like a new window opened.
        window.animationBehavior = .none
        // The document just opened is added to Recents; cleared if that is turned off in Settings. Window restoration is also aligned with the setting here.
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
        // The system first offsets the new window (cascade); keep it transparent and reveal it after aligning, otherwise you would see it jump.
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
            // The cascade may only take effect after this, so align once more on the next tick, then reveal it and tuck away the old one.
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

    /// Whether this window is the one currently shown in its group.
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

    /// Switch to the previous or next tab, wrapping around at the ends.
    func selectAdjacent(_ offset: Int) {
        guard let group = activeGroup(), group.windows.count > 1, let current = group.selected,
              let index = group.windows.firstIndex(where: { $0 === current }) else { return }
        let count = group.windows.count
        select(group.windows[(index + offset + count) % count])
    }

    /// ⌘1 to ⌘8 switch by position; ⌘9 goes to the last one.
    func select(number: Int) {
        guard let group = activeGroup(), !group.windows.isEmpty else { return }
        let index = number == 9 ? group.windows.count - 1 : number - 1
        guard index < group.windows.count else { return }
        NibApp.log("select tab \(number) of \(group.windows.count)")
        select(group.windows[index])
    }

    /// Close a tab. A tucked-away tab is switched to first and then closed: the unsaved-changes sheet must attach to a visible window.
    func close(_ window: NSWindow) {
        select(window)
        window.performClose(nil)
    }

    /// Close the other tabs in the group (with only = nil, only those to its right). It is brought to the front first; the rest are in the background.
    /// Tabs with unsaved changes are switched to one by one and asked about; if the user cancels, stop and leave the remaining ones open.
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
                // After the sheet goes away the window only closes on the next tick; if it is still there, the user cancelled, so stop on it.
                DispatchQueue.main.async {
                    guard tabs.group(of: window) == nil else { return }
                    tabs.closeInTurn(rest, thenSelect: keep)
                }
            }
        }
        window.performClose(nil)
    }

    /// ⇧⌘T: reopen the most recently closed tab. Files that were deleted or moved are skipped and the search continues; one that is already open is just brought to the front by the system.
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
        // Nib keeps running with no windows: give the closed tab's engine back to the pool (see EditorPool.recycle).
        EditorHibernator.shared.recycle(in: window)
        if NibApp.debug {
            weak var gone = window
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NibApp.log("after close: window alive=\(gone != nil) engines=\(EditorWebView.all.allObjects.count)")
            }
        }
        guard let group = group(of: window), let index = group.windows.firstIndex(where: { $0 === window }) else { return }
        if let url = NSDocumentController.shared.document(for: window)?.fileURL {
            closedURLs.removeAll { $0 == url }
            closedURLs.append(url)
        }
        group.windows.remove(at: index)
        if group.windows.isEmpty {
            groups.removeAll { $0 === group }
            if groups.isEmpty { AppDelegate.hideFromDockIfIdle() }
        } else if group.selected === window || group.selected == nil {
            // The tab being closed is the visible one: bring its neighbour to the front before it disappears, so a window is always on screen and the app does not conclude everything was closed.
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

/// Data for the tab strip at the top of a window.
@MainActor
final class TabStripModel: ObservableObject {
    struct Tab: Equatable {
        let id: ObjectIdentifier
        let title: String
        let edited: Bool
        let selected: Bool
        /// A new unsaved document has no path; the path items in the context menu are greyed out.
        let url: URL?
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var windowWidth: CGFloat = 860
    private weak var window: NSWindow?
    /// Weak: the model lives in the window's own title bar, so strong references would keep every closed tab's window alive.
    private struct WeakWindow { weak var window: NSWindow? }
    private var windowRefs: [ObjectIdentifier: WeakWindow] = [:]
    private var windows: [ObjectIdentifier: NSWindow] { windowRefs.compactMapValues(\.window) }
    private var becameKey = Date.distantPast
    private var pendingRename: DispatchWorkItem?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(window: NSWindow) {
        self.window = window
        // didUpdate fires very often, but it only publishes when the content changed, at the cost of comparing a few strings; renames, unsaved dots and window width all keep up through it.
        let names: [Notification.Name] = [WindowTabs.changed, NSWindow.didUpdateNotification, NSWindow.didResizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameKey = Date() }
        })
        // Stop renaming when the window loses focus (as Finder does).
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pendingRename?.cancel() }
        })
        refresh()
    }

    /// Like Finder: clicking the name of the already selected tab and waiting one double-click interval with no second click starts renaming; double-click, clicking another tab or the window losing focus cancel it.
    /// Clicking an unselected tab only switches to it. A click that just brought the window to the front (within 0.3 s) does not count, so switching back to Nib does not start a rename.
    /// Use only a single-click gesture and detect double-clicks via the event's clickCount: when SwiftUI has both single- and double-click gestures, the single click waits for the double-click timeout, so tab switching would lag.
    func click(_ id: ObjectIdentifier) {
        pendingRename?.cancel()
        pendingRename = nil
        guard let target = windows[id], let window else { return }
        let clicks = NSApp.currentEvent?.clickCount ?? 1
        NibApp.log("tab click count=\(clicks) selected=\(target === window)")
        guard target === window else {
            if clicks == 1 { select(id) }
            return
        }
        guard clicks == 1, renaming == nil, window.isKeyWindow, Date().timeIntervalSince(becameKey) > 0.3 else { return }
        let work = DispatchWorkItem { [weak self] in self?.beginRename(id) }
        pendingRename = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        guard let window else { return }
        let (list, selected) = WindowTabs.shared.tabs(for: window)
        windowRefs = Dictionary(uniqueKeysWithValues: list.map { (ObjectIdentifier($0), WeakWindow(window: $0)) })
        let next = list.map { Tab(id: ObjectIdentifier($0), title: $0.title, edited: $0.isDocumentEdited, selected: $0 === selected,
                                     url: NSDocumentController.shared.document(for: $0)?.fileURL) }
        if next != tabs { tabs = next }
        let editing = WindowTabs.shared.renaming.map(ObjectIdentifier.init)
        if editing != renaming { renaming = editing }
        if window.frame.width != windowWidth { windowWidth = window.frame.width }
    }

    /// Total width of the tab strip: at most 180 per tab, and no more than fits centred in the window (each side leaves room for the mode switch, about 300 in total).
    var stripWidth: CGFloat {
        // With only one document, show just the document icon and file name (as Typora does), leaving extra width for long file names.
        if tabs.count <= 1 { return max(60, min(420, windowWidth - 300)) }
        let count = CGFloat(max(tabs.count, 1))
        return max(60, min(count * 180 + (count - 1) + TabMetrics.inset * 2, windowWidth - 300))
    }

    /// Split evenly if wide enough (≥90); otherwise the selected tab keeps 120 so its title is legible and the rest share what is left, squeezing narrower like Safari.
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

    /// The tab being renamed. The state lives on WindowTabs: renaming an unselected tab first switches to it, after which the tab strip of another window is what is displayed.
    @Published private(set) var renaming: ObjectIdentifier?

    func beginRename(_ id: ObjectIdentifier) {
        pendingRename?.cancel()
        pendingRename = nil
        NibApp.log("rename begin")
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

/// The tab strip hangs directly on the title bar rather than in the toolbar: when the toolbar judges from an old width that it does not fit, it collapses the strip together with the mode switch into "»" and never restores it.
/// On the title bar its width is computed by itself, so it always fits.
@MainActor
enum TabStripInstaller {
    static let backdropID = NSUserInterfaceItemIdentifier("NibTitlebarBackdrop")
    private static var installed = Set<ObjectIdentifier>()
    private static var subscriptions: [ObjectIdentifier: AnyCancellable] = [:]
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]

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
        // Width follows the tab strip without taking more: the rest of the title bar must stay draggable.
        let width = host.widthAnchor.constraint(equalToConstant: model.stripWidth)
        width.isActive = true
        let subscription = model.objectWillChange.sink { [weak model] in
            DispatchQueue.main.async { if let model { width.constant = model.stripWidth } }
        }
        subscriptions[ObjectIdentifier(window)] = subscription

        // The mode switch also hangs on the right of the title bar, for the same reason: in the toolbar it would be collapsed into "»" when the window narrows.
        let hover = TitlebarHover()
        let tracker = TitlebarTracker(hover: hover)
        tracker.frame = titlebar.bounds
        tracker.autoresizingMask = [.width, .height]
        titlebar.addSubview(tracker, positioned: .below, relativeTo: nil)
        let modes = NSHostingView(rootView: TitlebarTools(controller: controller, hover: hover))
        modes.translatesAutoresizingMaskIntoConstraints = false
        titlebar.addSubview(modes)
        // The sidebar toggle sits to the right of the traffic lights (as in Finder and Safari) and is likewise hidden normally.
        if let zoom = window.standardWindowButton(.zoomButton) {
            let toggle = NSHostingView(rootView: SidebarToggle(hover: hover, controller: controller))
            toggle.translatesAutoresizingMaskIntoConstraints = false
            titlebar.addSubview(toggle)
            NSLayoutConstraint.activate([
                toggle.leadingAnchor.constraint(equalTo: zoom.trailingAnchor, constant: 14),
                toggle.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            modes.trailingAnchor.constraint(equalTo: titlebar.trailingAnchor, constant: -12),
            modes.centerYAnchor.constraint(equalTo: close.centerYAnchor),
        ])
        // The block must not capture the window: NotificationCenter keeps it until removed, which kept every closed
        // window (and its editor engine, 60 MB or more) alive once Nib stopped quitting after the last window.
        let id = ObjectIdentifier(window)
        closeObservers[id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated {
                installed.remove(id)
                subscriptions[id] = nil
                if let token = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(token) }
            }
        }
    }
}

/// Whether the mouse is over the title bar. The right-hand tools follow Typora: hidden normally, shown when the mouse moves onto the title bar (can be made permanent in Settings).
@MainActor
final class TitlebarHover: ObservableObject {
    @Published var inside = false
}

/// A transparent view filling the title bar and laid at the very bottom, used only to sense the mouse entering and leaving. The tab strip and buttons above it do not affect the check.
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

/// The group on the right of the title bar: word count, outline, edit toggle. Source mode is reached via ⌘/ and the menu, keeping the title bar simple.
/// Hidden normally; shown only when the mouse enters the title bar or a panel is open.
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

/// The sidebar toggle on the left of the title bar; always lit while the sidebar is open, and when closed it appears only when the mouse enters the title bar, like the tools on the right.
struct SidebarToggle: View {
    @ObservedObject var hover: TitlebarHover
    @ObservedObject var controller: EditorController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        let visible = settings.alwaysShowTools || settings.showSidebar || hover.inside
        TitlebarItem(active: settings.showSidebar, help: "Show Sidebar", action: { settings.showSidebar.toggle() }) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 13))
                .foregroundStyle(settings.showSidebar ? .primary : .secondary)
        }
        .accessibilityLabel(Text("Show Sidebar"))
        .padding(TabMetrics.inset)
        .modifier(GlassCapsule())
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.easeOut(duration: visible ? 0.12 : 0.25), value: visible)
    }
}

/// Edit toggle: while reading, click to enter edit mode; while editing or in source mode, click to return to reading. In edit or source mode the button has a background fill to show it is "on".
/// In source mode the icon changes to a source symbol so you can tell which mode it is.
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

/// While ⌘ is held on its own, ⌘1, ⌘2… show on the tabs; they disappear as soon as it is released or another modifier joins.
@MainActor
final class CommandHint: ObservableObject {
    static let shared = CommandHint()
    @Published private(set) var visible = false
    nonisolated(unsafe) private var monitor: Any?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let only = event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
            MainActor.assumeIsolated { CommandHint.shared.set(only) }
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CommandHint.shared.set(false) }
        }
    }

    private func set(_ value: Bool) {
        if visible != value { visible = value }
    }

    /// The number shown on the tab at this position: ⌘1 to ⌘8 by position, ⌘9 on the last tab when there are more than eight.
    static func number(at index: Int, of count: Int) -> Int? {
        if index < 8 { return index + 1 }
        return index == count - 1 ? 9 : nil
    }
}

/// The tab strip's shape matches the mode switch on the right: same capsule, same selected fill and height.
enum TabMetrics {
    // Measured from the mode switch: outer frame 24 pt, selected block 20 pt.
    static let height: CGFloat = 20
    static let inset: CGFloat = 2
}

struct TabStrip: View {
    @ObservedObject var model: TabStripModel
    @ObservedObject private var hint = CommandHint.shared
    @State private var hovered: ObjectIdentifier?

    var body: some View {
        if model.tabs.count == 1, let tab = model.tabs.first {
            DocumentTitle(tab: tab, renaming: model.renaming == tab.id, finish: { model.finishRename(tab.id, to: $0) })
                .contentShape(Rectangle())
                .onTapGesture { model.click(tab.id) }
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
                          select: { model.click(tab.id) }, close: { model.close(tab.id) },
                          renaming: model.renaming == tab.id, rename: { model.beginRename(tab.id) },
                          finish: { model.finishRename(tab.id, to: $0) },
                          shortcut: hint.visible ? CommandHint.number(at: index, of: model.tabs.count) : nil)
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

    /// Thin vertical separator between tabs; not drawn next to the selected or hovered tab, like the system segmented control.
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
    /// With only one tab it is just a title: no selected fill and no close button (close the window with the red light or ⌘W).
    let single: Bool
    let hovering: Bool
    let select: () -> Void
    let close: () -> Void
    var renaming = false
    var rename: () -> Void = {}
    var finish: (String?) -> Void = { _ in }
    /// Shown on the right while ⌘ is held (see CommandHint).
    var shortcut: Int? = nil

    var body: some View {
        ZStack {
            if let shortcut, !renaming, width >= 40 {
                HStack {
                    Spacer(minLength: 0)
                    Text(verbatim: "⌘\(shortcut)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.08)))
                }
                .padding(.trailing, 4)
            }
            if renaming {
                RenameField(initial: tab.title, finish: finish)
                    .padding(.horizontal, 22)
            } else {
            Text(tab.title)
                .font(.system(size: 12, weight: tab.selected ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(tab.selected ? .primary : .secondary)
                // Narrow tabs give up margin for the close button; if too narrow (<40), draw no text at all rather than leave only an ellipsis.
                .padding(.horizontal, min(24, width * 0.2))
                .opacity(width < 40 ? 0 : 1)
            }
            // Left slot: close on hover, a dot when there are unsaved changes; the title stays centred and does not jump.
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
        // Click: an unselected tab is switched to; the selected one waits a moment and then enters rename (see TabStripModel.click).
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

/// Title for a single document: document icon plus file name, no capsule, like the system title bar and Typora. When unsaved, the file name is followed by "Edited".
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

/// Tab context menu: close actions on top, path actions below, same order as Safari's tab menu.
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

/// Same glass capsule background as the mode switch in the toolbar. On macOS 26 and later it uses the system Liquid Glass; earlier systems fall back to a translucent material.
struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            content.background(.regularMaterial, in: Capsule(style: .continuous))
        }
    }
}
