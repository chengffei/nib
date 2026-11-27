import SwiftUI

@main
struct NibApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    static let launchedAt = Date()
    static let debug = ProcessInfo.processInfo.environment["NIB_DEBUG"] != nil
    @MainActor static var evalOnce = debug ? ProcessInfo.processInfo.environment["NIB_EVAL"] : nil
    @MainActor static var actionOnce = true
    @MainActor static var finderOnce = debug ? (ProcessInfo.processInfo.environment["NIB_REVEAL"] ?? ProcessInfo.processInfo.environment["NIB_FINDER"]) : nil

    /// Debug output, written to standard error only under NIB_DEBUG.
    static func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("NIB \(Int(Date().timeIntervalSince1970 * 1000)) \(message())\n".utf8))
    }

    init() {
        _ = Self.launchedAt
        Self.log("app init")
        // Tabs are managed by WindowTabs, so system tab groups are turned off; clear the previously written "always merge into tabs".
        UserDefaults.standard.removeObject(forKey: "AppleWindowTabbingMode")
        // Launching (or reopening with no windows) goes straight to a new Untitled document instead of the open panel
        // that DocumentGroup shows when iCloud Drive is on.
        UserDefaults.standard.set(false, forKey: "NSShowAppCentricOpenPanelInsteadOfUntitledFile")
        // Recents and window restoration at launch follow the settings (by default record recents, do not restore windows).
        // NSDocumentController must not be touched yet: SwiftUI needs to create it first, and creating it earlier crashes at launch.
        // Clearing recents is done after launch finishes (AppDelegate).
        AppSettings.applyHistory(touchRecents: false)
        // While SwiftUI is still building windows, load the editor engine first.
        EditorPool.shared.prewarm()
        // The theme decides the window's light/dark; NSApp is not ready yet, so set it a tick later.
        DispatchQueue.main.async { AppSettings.shared.apply() }
    }

    var body: some Scene {
        // On macOS DocumentGroup is driven by NSDocument: autosave, Versions, window tabs and Open Recent all come for free.
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentView(text: file.$document.text, fileURL: file.fileURL)
        }
        .defaultSize(width: 860, height: 900)
        // No window title, toolbar compressed to compact height; the file name is read from the tab.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { EditorCommands() }

        Settings { SettingsView() }
    }
}

/// Keeps running after the last window closes (11-20 Felix 定, like TextEdit and Typora): a cold start takes about
/// 830 ms because WebKit has to start its processes, opening into a running Nib about 120 ms. Idle cost: the shell
/// (about 45 MB) plus one spare editor engine (about 39 MB), no CPU.
/// With no windows Nib leaves the Dock and the ⌘Tab switcher (accessory policy, 11-22 Felix 定) and comes back as
/// soon as a document opens. To quit it from there: open any document, then ⌘Q.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !AppSettings.shared.keepRunning }
    }

    /// Launching Nib again from Finder or Spotlight while it sits hidden: show it before SwiftUI puts up a window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showInDock()
        return true
    }

    @MainActor static func showInDock() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        // Switching back from accessory leaves the menu bar on the previous app until Nib is activated again.
        NSApp.activate(ignoringOtherApps: true)
        NibApp.log("dock: shown")
    }

    /// Called after a window closes; hides from the Dock only when no titled window is left (Settings counts).
    @MainActor static func hideFromDockIfIdle() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard AppSettings.shared.keepRunning, NSApp.activationPolicy() == .regular,
                  !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
            NSApp.setActivationPolicy(.accessory)
            NibApp.log("dock: hidden")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyHistory()
    }
}

/// Menu commands go to the editor of the current window. Undo and redo do not use SwiftUI's built-in ones: those go through the document's UndoManager, which cannot reach the edit history in the web page.
struct EditorCommands: Commands {
    // FocusedObject refreshes the menu as the controller's mode changes, so the checkmarks are correct.
    @FocusedObject private var controller: EditorController?
    /// Shortcuts can be changed in Settings; the menu refreshes accordingly.
    @ObservedObject private var shortcuts = ShortcutStore.shared
    @ObservedObject private var settings = AppSettings.shared

    var body: some Commands {
        // ⌘T opens a new tab like a browser: the new document window is merged into the current group by WindowTabs. ⌘N is unchanged.
        CommandGroup(after: .newItem) {
            Button("New Tab") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut(shortcuts.shortcut("New Tab"))
            Button("Reopen Closed Tab") { WindowTabs.shared.reopenClosed() }
                .keyboardShortcut(shortcuts.shortcut("Reopen Closed Tab"))
            Divider()
            Button("Quick Open…") { controller?.finder = controller?.finder == .files ? nil : .files }
                .keyboardShortcut(shortcuts.shortcut("Quick Open…"))
                .disabled(controller == nil)
            Button("Search in Workspace…") { controller?.finder = controller?.finder == .text ? nil : .text }
                .keyboardShortcut(shortcuts.shortcut("Search in Workspace…"))
                .disabled(controller == nil)
            Button("Add Folder to Workspace…") {
                let folder = NSDocumentController.shared.currentDocument?.fileURL?.deletingLastPathComponent()
                Workspace.chooseFolders(window: NSApp.keyWindow, startingAt: folder)
            }
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { export(.print) }
                .keyboardShortcut(shortcuts.shortcut("Print…"))
                .disabled(controller == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export as PDF…") { export(.pdf) }
                .keyboardShortcut(shortcuts.shortcut("Export as PDF…"))
                .disabled(controller == nil)
            Button("Export as HTML…") { export(.html) }
                .keyboardShortcut(shortcuts.shortcut("Export as HTML…"))
                .disabled(controller == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            item("Undo", "nib.undo()", icon: "arrow.uturn.backward")
            item("Redo", "nib.redo()", icon: "arrow.uturn.forward")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Find…", "nib.find()", icon: "magnifyingglass")
        }
        CommandGroup(before: .toolbar) {
            // The three modes are checkable menu items, with the current mode ticked (HIG: stateful commands show their state, instead of a name like "Toggle" whose direction is unclear).
            // Common items carry icons, following the macOS 26 system menus and Typora.
            modeItem("Read", .read, icon: "book") { controller?.setMode(.read) }
            modeItem("Editing", .edit, icon: "square.and.pencil") { controller?.run("nib.toggleEdit()") }
            modeItem("Source Mode", .source, icon: "chevron.left.forwardslash.chevron.right") { controller?.run("nib.toggleSource()") }
            Divider()
            settingToggle("Focus Mode", icon: "scope", isOn: $settings.focusMode)
            settingToggle("Typewriter Mode", icon: "character.cursor.ibeam", isOn: $settings.typewriterMode)
            Divider()
            settingToggle("Show Sidebar", icon: "sidebar.left", isOn: Binding(
                get: { controller?.sidebarVisible ?? settings.showSidebar },
                set: { on in
                    if let controller, controller.sidebarVisible != on { controller.toggleSidebar() } else if controller == nil { settings.showSidebar = on }
                }))
            Button { controller?.showOutline.toggle() } label: { Label("Show Outline", systemImage: "list.bullet.indent") }
                .keyboardShortcut(shortcuts.shortcut("Show Outline"))
                .disabled(controller == nil)
            Divider()
            Button { AppSettings.shared.zoom(0) } label: { Label("Actual Size", systemImage: "1.magnifyingglass") }
                .keyboardShortcut(shortcuts.shortcut("Actual Size"))
            Button { AppSettings.shared.zoom(1) } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                .keyboardShortcut(shortcuts.shortcut("Zoom In"))
            Button { AppSettings.shared.zoom(-1) } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                .keyboardShortcut(shortcuts.shortcut("Zoom Out"))
            Divider()
        }
        CommandGroup(before: .windowList) {
            // Like Safari: previous/next switching lives in the Window menu (⇧⌘[ ]; ⌃⇥ is swallowed by the web view as a focus change and was observed not to fire), and ⌘1 to ⌘9 go into a submenu so the Window menu does not grow long.
            Button("Show Previous Tab") { WindowTabs.shared.selectAdjacent(-1) }
                .keyboardShortcut(shortcuts.shortcut("Show Previous Tab"))
            Button("Show Next Tab") { WindowTabs.shared.selectAdjacent(1) }
                .keyboardShortcut(shortcuts.shortcut("Show Next Tab"))
            Menu("Go to Tab") {
                // ⌘1 to ⌘8 switch tabs by position, ⌘9 always goes to the last. The two titles are written separately: a ternary would turn them into plain strings that skip localization.
                ForEach(1...9, id: \.self) { number in
                    Group {
                        if number == 9 { Button("Show Last Tab") { Self.selectTab(number) } }
                        else { Button("Show Tab \(number)") { Self.selectTab(number) } }
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
            Divider()
        }
    }

    private func export(_ kind: Exporter.Kind) {
        guard let controller else { return }
        Exporter.run(kind, controller: controller, window: controller.webView?.window ?? NSApp.keyWindow)
    }

    @MainActor
    private static func selectTab(_ number: Int) {
        WindowTabs.shared.select(number: number)
    }

    /// title is the English menu title, both the localization key and the key of the shortcut setting.
    private func modeItem(_ title: String, _ mode: EditorMode, icon: String, action: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { controller?.mode == mode }, set: { _ in action() })) {
            Label(LocalizedStringKey(title), systemImage: icon)
        }
        .keyboardShortcut(shortcuts.shortcut(title))
        .disabled(controller == nil)
    }

    /// Switches stored in settings (focus, typewriter, sidebar); all windows change together.
    private func settingToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) { Label(LocalizedStringKey(title), systemImage: icon) }
            .keyboardShortcut(shortcuts.shortcut(title))
    }

    private func item(_ title: String, _ script: String, icon: String) -> some View {
        Button { controller?.run(script) } label: { Label(LocalizedStringKey(title), systemImage: icon) }
            .keyboardShortcut(shortcuts.shortcut(title))
            .disabled(controller == nil)
    }
}

extension DocumentView {
    /// Folds the sidebar when the window narrows past foldWidth, and unfolds it when there is room again.
    func fold(from old: CGFloat, to width: CGFloat) {
        guard settings.showSidebar else { return }
        if !controller.sidebarFolded, width < Self.foldWidth, old >= Self.foldWidth || old == 0 || old == width {
            controller.sidebarFolded = true
        } else if controller.sidebarFolded, width >= Self.foldWidth + settings.sidebarWidth + 10 {
            controller.sidebarFolded = false
        }
    }

    /// While the sidebar is hidden, resting the pointer on the window's left edge slides it out over the document;
    /// it slides back 0.16 s after the pointer leaves it.
    /// One hover region that grows from a 6 pt edge strip to the panel's width, so the pointer never "leaves" while it opens.
    var peekLayer: some View {
        ZStack(alignment: .leading) {
            if peeking {
                FileSidebar(documentURL: fileURL, tree: tree)
                    .frame(width: settings.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .background(.regularMaterial)
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 10, topTrailingRadius: 10))
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: peeking ? settings.sidebarWidth : 6, alignment: .leading)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in peek(inside) }
        .animation(.easeOut(duration: 0.18), value: peeking)
    }

    func peek(_ inside: Bool) {
        peekClose?.cancel()
        if inside {
            peeking = true
            return
        }
        let close = DispatchWorkItem { peeking = false }
        peekClose = close
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: close)
    }
}

struct DocumentView: View {
    @Binding var text: String
    let fileURL: URL?
    @StateObject private var controller = EditorController()
    @ObservedObject private var settings = AppSettings.shared

    @StateObject private var tree = FileTree()
    @State private var disk = DiskSnapshot()

    @State private var peeking = false
    @State private var peekClose: DispatchWorkItem?

    /// Below this window width an open sidebar folds away; it comes back only once there is room for it plus a margin,
    /// so unfolding never makes the document narrower than the width that folded it.
    static let foldWidth: CGFloat = 900

    var body: some View {
        let shown = settings.showSidebar && !controller.sidebarFolded
        HStack(spacing: 0) {
            if shown {
                FileSidebar(documentURL: fileURL, tree: tree)
                    .frame(width: settings.sidebarWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                SidebarDivider()
            }
            EditorView(text: $text, baseDirectory: fileURL?.deletingLastPathComponent().path, controller: controller)
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { old, width in fold(from: old, to: width) }
        .onChange(of: settings.showSidebar) { if !settings.showSidebar { controller.sidebarFolded = false } }
        .overlay(alignment: .leading) { if !shown { peekLayer } }
            .overlay(alignment: .top) {
                if let kind = controller.finder {
                    FinderPanel(kind: kind, current: fileURL) {
                        controller.finder = nil
                        if let webView = controller.webView { webView.window?.makeFirstResponder(webView) }
                    }
                    .id(kind)
                    .padding(.top, 10)
                }
            }
            .background(settings.backgroundColor)
            .frame(minWidth: 480, minHeight: 320)
            .focusedSceneObject(controller)
            .task(id: fileURL) { controller.watch(fileURL) }
            // Edits that bring the text back to what is on disk (typed and then deleted again) count as no change, so the dot goes away and closing does not ask.
            // Checked when the document's undo manager closes an edit or undoes/redoes one: that is when NSDocument updates its change count, which may come
            // well after the text binding changed. Checking earlier would be overwritten by that update.
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup).merge(with:
                NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange),
                NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange))) { note in
                guard let window = controller.webView?.window,
                      let document = NSDocumentController.shared.document(for: window), note.object as? UndoManager === document.undoManager else { return }
                DispatchQueue.main.async {
                    guard document.isDocumentEdited, disk.matches(text, url: document.fileURL) else { return }
                    document.updateChangeCount(.changeCleared)
                }
            }
            .toolbar(removing: .title)
            // The toolbar draws no background of its own, letting the window background show (= body background, see AppSettings.applyChrome), so the top and the body are one colour.
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                // Only an invisible placeholder goes in the toolbar, to hold up the title-bar height; the tab strip and mode switch hang on the title bar (see TabStripInstaller),
                // since in the toolbar they would be collapsed into "»" when the window narrows.
                // The placeholder must not carry the glass background the system adds to toolbar items, otherwise a vertical line appears in the middle of the window.
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                }
            }
    }
}
