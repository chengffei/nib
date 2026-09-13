import SwiftUI

@main
struct NibApp: App {
    var body: some Scene {
        // DocumentGroup 在 macOS 上由 NSDocument 驱动：自动保存、Versions、窗口标签页、Open Recent 全部白送。
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            EditorView(text: file.$document.text)
        }
    }
}
