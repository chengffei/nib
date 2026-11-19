import SwiftUI

/// 标签上改文件名：双击标签或右键「重新命名…」。
/// 已存盘的文档原地改名（走 NSDocument.move，文件协调、最近使用、窗口标题都跟着更新）；
/// 没存过的「未命名」没有文件可改，按新名字弹出存储面板。
@MainActor
enum DocumentRename {
    static func rename(_ window: NSWindow, to input: String) {
        guard let document = NSDocumentController.shared.document(for: window) else { return }
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            if !name.isEmpty { NSSound.beep() }
            return
        }
        guard let url = document.fileURL else {
            // 未命名：存储面板默认用显示名作文件名。
            if (name as NSString).pathExtension.isEmpty { name += ".md" }
            document.displayName = name
            document.save(nil)
            return
        }
        // 没写扩展名就沿用原来的，免得改完变成别的程序打开的文件。
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        guard name != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        // 只改大小写时目标在不区分大小写的磁盘上「已存在」，其实是同一个文件，放行。
        let sameFile = target.path.lowercased() == url.path.lowercased()
        if FileManager.default.fileExists(atPath: target.path), !sameFile {
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(name)” already exists.")
            alert.informativeText = String(localized: "Choose a different name.")
            alert.beginSheetModal(for: window)
            return
        }
        document.move(to: target) { error in
            if let error { NSApp.presentError(error) }
            NibApp.log("renamed \(error == nil ? "ok" : "failed")")
        }
    }
}

/// 改名输入框：一出现就聚焦并选中不含扩展名的部分（和访达一样）。回车确认，Esc 或点别处放弃。
struct RenameField: NSViewRepresentable {
    let initial: String
    let finish: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: initial)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.alignment = .center
        field.font = .systemFont(ofSize: 12, weight: .medium)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        // 双击的第二下松开时会落到刚出现的输入框上、把选区改成光标，等它过去再选。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // 同一组的每个窗口都有一条标签条，只在屏幕上那个里接管键盘。
            guard let window = field.window, window.isVisible, window.makeFirstResponder(field) else { return }
            context.coordinator.focused = true
            let base = (initial as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.finish = finish
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var finish: (String?) -> Void
        var focused = false
        private var done = false

        init(finish: @escaping (String?) -> Void) { self.finish = finish }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                end(control.stringValue)
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                end(nil)
                return true
            }
            return false
        }

        /// 点到别处失去焦点：放弃，不偷偷改名。
        func controlTextDidEndEditing(_ obj: Notification) { if focused { end(nil) } }

        private func end(_ value: String?) {
            guard focused, !done else { return }
            done = true
            let finish = finish
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(value) } }
        }
    }
}
