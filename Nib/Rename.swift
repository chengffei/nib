import SwiftUI

/// Rename a file from its tab: double-click the tab or right-click "Rename…".
/// A saved document is renamed in place (via NSDocument.move, so file coordination, recents and the window title all update);
/// an unsaved "Untitled" has no file to rename, so a save panel is presented with the new name.
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
            // Untitled: the save panel uses the display name as the file name by default.
            if (name as NSString).pathExtension.isEmpty { name += ".md" }
            document.displayName = name
            document.save(nil)
            return
        }
        // If no extension is given, keep the original, so renaming does not turn the file into one opened by another program.
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        guard name != url.lastPathComponent else { return }
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        // When only the case changes, the target "exists" on a case-insensitive disk but is the same file; allow it.
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

/// Rename text field: focuses as soon as it appears and selects the part without the extension (like Finder). Return confirms; Esc or clicking elsewhere abandons.
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
        // The second click of a double-click lands on the just-appeared text field on release and turns the selection into a caret; wait for it to pass, then select.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            // Every window in the same group has a tab strip; only the one on screen takes over the keyboard.
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

        /// Focus lost by clicking elsewhere: abandon, do not rename silently.
        func controlTextDidEndEditing(_ obj: Notification) { if focused { end(nil) } }

        private func end(_ value: String?) {
            guard focused, !done else { return }
            done = true
            let finish = finish
            DispatchQueue.main.async { MainActor.assumeIsolated { finish(value) } }
        }
    }
}
