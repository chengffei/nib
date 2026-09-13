import SwiftUI
import AppKit

/// P0 阶段 1：纯源码编辑器。NSTextView + TextKit 2，后续的语法染色与混合渲染都在这个视图上做。
struct EditorView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true

        let textView = scrollView.documentView as! NSTextView
        // TextKit 2：scrollableTextView() 在 macOS 15+ 默认即 TextKit 2；显式确认，避免回落到 TextKit 1。
        _ = textView.textLayoutManager
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 24, height: 32)

        // Markdown 语法容不下系统的"智能"替换：引号、破折号、链接、文本替换全部关掉，拼写检查保留。
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true

        textView.string = text
        textView.typingAttributes = MarkdownHighlighter.baseAttributes
        if let storage = textView.textStorage { MarkdownHighlighter.apply(to: storage) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 只在外部（如 Versions 回滚、磁盘重载）改动时回写，避免每次按键重置光标。
        if textView.string != text {
            textView.string = text
            if let storage = textView.textStorage { MarkdownHighlighter.apply(to: storage) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            // 中文输入法组字期间（marked text）不重染：改属性会打断候选框定位。提交后会再来一次 textDidChange。
            guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            MarkdownHighlighter.apply(to: storage)
            textView.typingAttributes = MarkdownHighlighter.baseAttributes
        }
    }
}
