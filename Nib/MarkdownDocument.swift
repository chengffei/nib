import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}

/// 源文件是唯一真相：文档模型只有一个字符串。换行符（LF/CRLF）随原文保留，不做规范化。
struct MarkdownDocument: FileDocument {
    var text: String

    init(text: String = "") {
        self.text = text
    }

    static let readableContentTypes: [UTType] = [.markdownDocument, .plainText]

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// 改了没存要看得见、关窗要问：关掉「原地自动保存」（11-19 Felix 定）。
/// 原地自动保存时系统几秒就把改动写回原文件，未保存点一闪而过，关窗也从不询问。
/// 关掉后改动先自动存到系统的备份位置（崩溃、断电照样能恢复），原文件只在 ⌘S 或关窗选「保存」时才写。
/// 代价：「复原到」里的 Versions 版本浏览不可用。
/// SwiftUI 的 DocumentGroup 不让换 NSDocument 子类，只能在运行时改它的类方法 autosavesInPlace。
@MainActor
enum ExplicitSave {
    private static var patched = Set<ObjectIdentifier>()

    static func apply(to window: NSWindow) {
        guard let document = NSDocumentController.shared.document(for: window) else { return }
        patch(type(of: document))
    }

    private static func patch(_ cls: AnyClass) {
        guard patched.insert(ObjectIdentifier(cls)).inserted, let meta = object_getClass(cls) else { return }
        let selector = #selector(getter: NSDocument.autosavesInPlace)
        let block: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_replaceMethod(meta, selector, imp_implementationWithBlock(block), "c@:")
        NibApp.log("autosavesInPlace off for \(NSStringFromClass(cls))")
    }
}
