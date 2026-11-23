import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownDocument = UTType(importedAs: "net.daringfireball.markdown")
}

/// The source file is the single source of truth: the document model is just one string. Line endings (LF/CRLF) are kept as in the original, with no normalisation.
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

/// Unsaved changes must be visible and closing the window must ask: turn off "autosave in place".
/// With autosave in place the system writes changes back to the original file within seconds, the unsaved dot flashes by, and closing a window never asks.
/// With it off, changes are first autosaved to the system's backup location (recoverable after a crash or power loss), and the original file is written only on ⌘S or when choosing "Save" while closing.
/// Cost: Versions browsing under "Revert To" is unavailable.
/// SwiftUI's DocumentGroup does not allow swapping the NSDocument subclass, so the only way is to change its class method autosavesInPlace at runtime.
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

/// What the document's file holds on disk, to tell whether the text in the editor really differs from it.
/// The file is read again only when its size or modification date changes (after a save, Save As or an outside edit), so most checks cost one stat.
/// Bytes are compared rather than strings: Swift string equality treats composed and decomposed characters as equal, but the file would still change.
@MainActor
final class DiskSnapshot {
    private var url: URL?
    private var stamp: (Date, Int)?
    private var data = Data()

    /// A new document that was never saved matches when it is empty or only whitespace.
    func matches(_ text: String, url: URL?) -> Bool {
        guard let url else { return text.allSatisfy(\.isWhitespace) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int else { return false }
        if url != self.url || stamp?.0 != date || stamp?.1 != size {
            guard let fresh = try? Data(contentsOf: url) else { return false }
            self.url = url
            stamp = (date, size)
            data = fresh
        }
        let bytes = text.utf8
        return bytes.count == data.count && bytes.elementsEqual(data)
    }
}
