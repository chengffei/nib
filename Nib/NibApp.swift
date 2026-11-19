import SwiftUI

@main
struct NibApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    static let launchedAt = Date()
    static let debug = ProcessInfo.processInfo.environment["NIB_DEBUG"] != nil
    @MainActor static var evalOnce = debug ? ProcessInfo.processInfo.environment["NIB_EVAL"] : nil

    /// 调试输出，只在 NIB_DEBUG 下写到标准错误。
    static func log(_ message: @autoclosure () -> String) {
        guard debug else { return }
        FileHandle.standardError.write(Data("NIB \(Int(Date().timeIntervalSince1970 * 1000)) \(message())\n".utf8))
    }

    init() {
        _ = Self.launchedAt
        Self.log("app init")
        // 标签由 WindowTabs 自己管，系统标签组关掉；清掉以前写的「总是合并成标签页」。
        UserDefaults.standard.removeObject(forKey: "AppleWindowTabbingMode")
        // 最近打开、启动时恢复窗口都按设置来（默认记最近打开、不恢复窗口）。
        // 这时还不能碰 NSDocumentController：SwiftUI 要自己先建它，抢先建了启动就崩（11-16 关掉最近打开后每次启动都崩）。
        // 最近打开的清理放到启动完成之后（AppDelegate）。
        AppSettings.applyHistory(touchRecents: false)
        // 趁 SwiftUI 还在搭窗口，先把编辑器内核加载起来。
        EditorPool.shared.prewarm()
        // 主题决定窗口深浅色；NSApp 这时还没建好，等一拍再设。
        DispatchQueue.main.async { AppSettings.shared.apply() }
    }

    var body: some Scene {
        // DocumentGroup 在 macOS 上由 NSDocument 驱动：自动保存、Versions、窗口标签页、Open Recent 全部白送。
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            DocumentView(text: file.$document.text, fileURL: file.fileURL)
        }
        .defaultSize(width: 860, height: 900)
        // 不显示窗口标题，工具栏压成紧凑高度；文件名看标签页。
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands { EditorCommands() }

        Settings { SettingsView() }
    }
}

/// 最后一个文档窗口关掉就退出，不留空跑的 app。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.applyHistory()
    }
}

/// 菜单命令发给当前窗口的编辑器。撤销重做不用 SwiftUI 自带的：那套走文档的 UndoManager，管不到网页里的编辑历史。
struct EditorCommands: Commands {
    // FocusedObject 会跟着 controller 的 mode 变化刷新菜单，勾选状态才对。
    @FocusedObject private var controller: EditorController?
    /// 快捷键可在设置里改，改了菜单跟着刷新。
    @ObservedObject private var shortcuts = ShortcutStore.shared

    var body: some Commands {
        // ⌘T 和浏览器一样开新标签：新文档窗口会被 WindowTabs 并进当前组。⌘N 照旧。
        CommandGroup(after: .newItem) {
            Button("New Tab") { NSDocumentController.shared.newDocument(nil) }
                .keyboardShortcut(shortcuts.shortcut("New Tab"))
            Button("Reopen Closed Tab") { WindowTabs.shared.reopenClosed() }
                .keyboardShortcut(shortcuts.shortcut("Reopen Closed Tab"))
        }
        CommandGroup(replacing: .undoRedo) {
            item("Undo", "nib.undo()")
            item("Redo", "nib.redo()")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Find…", "nib.find()")
        }
        CommandGroup(before: .toolbar) {
            // 三种模式做成带勾的菜单项，当前模式打勾（HIG：有状态的命令显示状态，不用「切换」这种说不清方向的名字）。
            modeItem("Read", .read) { controller?.setMode(.read) }
            modeItem("Editing", .edit) { controller?.run("nib.toggleEdit()") }
            modeItem("Source Mode", .source) { controller?.run("nib.toggleSource()") }
            Divider()
            Button("Show Outline") { controller?.showOutline.toggle() }
                .keyboardShortcut(shortcuts.shortcut("Show Outline"))
                .disabled(controller == nil)
            Divider()
            Button("Zoom In") { AppSettings.shared.zoom(1) }.keyboardShortcut(shortcuts.shortcut("Zoom In"))
            Button("Zoom Out") { AppSettings.shared.zoom(-1) }.keyboardShortcut(shortcuts.shortcut("Zoom Out"))
            Button("Actual Size") { AppSettings.shared.zoom(0) }.keyboardShortcut(shortcuts.shortcut("Actual Size"))
            Divider()
        }
        CommandGroup(before: .windowList) {
            // 和 Safari 一样：前后切换放在窗口菜单里（⇧⌘[ ]；⌃⇥ 会被网页视图当成焦点切换吃掉，实测不触发），⌘1 到 ⌘9 收进子菜单，不把窗口菜单撑长。
            Button("Show Previous Tab") { WindowTabs.shared.selectAdjacent(-1) }
                .keyboardShortcut(shortcuts.shortcut("Show Previous Tab"))
            Button("Show Next Tab") { WindowTabs.shared.selectAdjacent(1) }
                .keyboardShortcut(shortcuts.shortcut("Show Next Tab"))
            Menu("Go to Tab") {
                // ⌘1 到 ⌘8 按位置切标签，⌘9 固定去最后一个。两个标题分开写：三目运算会让它们变成普通字符串，不走本地化。
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

    @MainActor
    private static func selectTab(_ number: Int) {
        WindowTabs.shared.select(number: number)
    }

    /// title 是英文菜单标题，既是本地化 key 也是快捷键设置的 key。
    private func modeItem(_ title: String, _ mode: EditorMode, action: @escaping () -> Void) -> some View {
        Toggle(LocalizedStringKey(title), isOn: Binding(get: { controller?.mode == mode }, set: { _ in action() }))
            .keyboardShortcut(shortcuts.shortcut(title))
            .disabled(controller == nil)
    }

    private func item(_ title: String, _ script: String) -> some View {
        Button(LocalizedStringKey(title)) { controller?.run(script) }
            .keyboardShortcut(shortcuts.shortcut(title))
            .disabled(controller == nil)
    }
}

struct DocumentView: View {
    @Binding var text: String
    let fileURL: URL?
    @StateObject private var controller = EditorController()
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        EditorView(text: $text, baseDirectory: fileURL?.deletingLastPathComponent().path, controller: controller)
            .background(settings.backgroundColor)
            .frame(minWidth: 480, minHeight: 320)
            .focusedSceneObject(controller)
            .task(id: fileURL) { controller.watch(fileURL) }
            .toolbar(removing: .title)
            // 工具栏不画自己的底色，露出窗口底色（= 正文底色，见 AppSettings.applyChrome），顶部和正文一个颜色。
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar {
                // 工具栏里只放一个看不见的占位，撑出标题栏高度；标签条和模式切换都挂在标题栏上（见 TabStripInstaller），
                // 放在工具栏里窗口一窄就会被收进「»」。
                // 占位项不能带系统给工具栏项加的玻璃底，不然窗口正中会多出一道竖线（11-17 Felix 反馈）。
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1) }
                }
            }
    }
}
