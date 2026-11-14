import SwiftUI

@main
struct NibApp: App {
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
        // 只对 Nib 生效：打开文稿时总是合并成标签页，不受系统「偏好标签页」设置影响。
        UserDefaults.standard.set("always", forKey: "AppleWindowTabbingMode")
        // 启动时不恢复上次的窗口：点开一篇就只加载这一篇。
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
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
        .commands { EditorCommands() }

        Settings { SettingsView() }
    }
}

struct EditorControllerKey: FocusedValueKey {
    typealias Value = EditorController
}

extension FocusedValues {
    var editorController: EditorController? {
        get { self[EditorControllerKey.self] }
        set { self[EditorControllerKey.self] = newValue }
    }
}

/// 菜单命令发给当前窗口的编辑器。撤销重做不用 SwiftUI 自带的：那套走文档的 UndoManager，管不到网页里的编辑历史。
struct EditorCommands: Commands {
    @FocusedValue(\.editorController) private var controller

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            item("Undo", "nib.undo()", "z")
            item("Redo", "nib.redo()", "z", [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            item("Find…", "nib.find()", "f")
        }
        CommandGroup(before: .toolbar) {
            item("Toggle Editing", "nib.toggleEdit()", "e")
            item("Toggle Source Mode", "nib.toggleSource()", "/")
            Divider()
            Button("Zoom In") { AppSettings.shared.zoom(1) }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { AppSettings.shared.zoom(-1) }.keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { AppSettings.shared.zoom(0) }.keyboardShortcut("0", modifiers: .command)
            Divider()
        }
        CommandGroup(before: .windowList) {
            // ⌘1 到 ⌘8 按位置切标签，⌘9 固定去最后一个，和 Safari 一致。
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Show Last Tab" : "Show Tab \(number)") { Self.selectTab(number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            Divider()
        }
    }

    @MainActor
    private static func selectTab(_ number: Int) {
        // 先看 tabbedWindows 再碰 tabGroup，原因见 EditorHost.isSelectedTab。
        let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        guard let window = candidates.first(where: { $0.tabbedWindows != nil }), let tabs = window.tabbedWindows else {
            NibApp.log("select tab \(number): no tabbed window")
            return
        }
        let target = number == 9 ? tabs[tabs.count - 1] : (number <= tabs.count ? tabs[number - 1] : nil)
        NibApp.log("select tab \(number) of \(tabs.count)")
        guard let target else { return }
        window.tabGroup?.selectedWindow = target
        target.makeKeyAndOrderFront(nil)
    }

    private func item(_ title: String, _ script: String, _ key: KeyEquivalent, _ modifiers: EventModifiers = .command) -> some View {
        Button(title) { controller?.run(script) }
            .keyboardShortcut(key, modifiers: modifiers)
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
            .focusedSceneValue(\.editorController, controller)
            .task(id: fileURL) { controller.watch(fileURL) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker("Mode", selection: Binding(get: { controller.mode }, set: { controller.setMode($0) })) {
                        Image(systemName: "book").help("Read").tag(EditorMode.read)
                        Image(systemName: "square.and.pencil").help("Edit").tag(EditorMode.edit)
                        Image(systemName: "chevron.left.forwardslash.chevron.right").help("Source").tag(EditorMode.source)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
    }
}
