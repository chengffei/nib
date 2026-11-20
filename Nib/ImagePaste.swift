import AppKit
import UniformTypeIdentifiers

/// Pasting images (requirement S3: paste a screenshot straight into the document).
/// The image is written next to the document, by default into "./<document name>.assets/", and a relative markdown
/// image link is inserted. A `typora-copy-images-to:` line in the front matter overrides the folder, as in Typora.
@MainActor
enum ImagePaste {
    /// Returns the markdown to insert, or nil when the pasteboard holds nothing this should handle (normal paste goes on).
    /// Throws when it should handle it but cannot (e.g. the document was never saved).
    static func markdown(from pasteboard: NSPasteboard, documentURL: URL?, text: String) throws -> String? {
        let files = imageFiles(on: pasteboard)
        let bitmap = files.isEmpty ? bitmapPNG(on: pasteboard) : nil
        guard !files.isEmpty || bitmap != nil else { return nil }
        guard let documentURL else { throw PasteError.unsaved }

        let documentFolder = documentURL.deletingLastPathComponent()
        let relativeFolder = folderTemplate(in: text)
            .replacingOccurrences(of: "${filename}", with: documentURL.deletingPathExtension().lastPathComponent)
        let folder = URL(fileURLWithPath: relativeFolder, relativeTo: documentFolder).standardizedFileURL
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var written: [URL] = []
        if let bitmap {
            let target = unique(folder.appendingPathComponent("image-\(timestamp()).png"))
            try bitmap.write(to: target)
            written.append(target)
        }
        for file in files {
            let target = unique(folder.appendingPathComponent(file.lastPathComponent))
            try FileManager.default.copyItem(at: file, to: target)
            written.append(target)
        }
        return written.map { "![](\(link(to: $0, from: documentFolder)))" }.joined(separator: "\n")
    }

    enum PasteError: LocalizedError {
        case unsaved
        var errorDescription: String? { String(localized: "Save the document before pasting images.") }
        var recoverySuggestion: String? { String(localized: "Images are stored in a folder next to the document, so it needs a location first.") }
    }

    /// Image files copied in Finder.
    private static func imageFiles(on pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }

    /// Raw image data (a screenshot copied to the clipboard). Skipped when text or HTML is also there: copying from
    /// a web page or another editor carries a picture too, and the text is what is wanted then.
    private static func bitmapPNG(on pasteboard: NSPasteboard) -> Data? {
        let types = pasteboard.types ?? []
        if types.contains(.string) || types.contains(.html) || types.contains(.rtf) { return nil }
        if let png = pasteboard.data(forType: .png) { return png }
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// Front matter `typora-copy-images-to:` wins; otherwise "./${filename}.assets".
    static func folderTemplate(in text: String) -> String {
        let fallback = "./${filename}.assets"
        guard text.hasPrefix("---") else { return fallback }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().prefix(100) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" || trimmed == "..." { break }
            guard trimmed.hasPrefix("typora-copy-images-to:") else { continue }
            var value = trimmed.dropFirst("typora-copy-images-to:".count).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            // Typora's "upload" setting means an image uploader, which Nib does not have.
            if !value.isEmpty, !value.hasPrefix("::") { return value }
        }
        return fallback
    }

    /// Relative path from the document folder; wrapped in <> when it has spaces or brackets, which a bare link cannot hold.
    static func link(to file: URL, from folder: URL) -> String {
        let base = folder.standardizedFileURL.path + "/"
        let path = file.standardizedFileURL.path
        let relative = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        return relative.contains(where: { " ()<>".contains($0) }) ? "<\(relative)>" : relative
    }

    private static func unique(_ url: URL) -> URL {
        var candidate = url
        var n = 2
        let stem = url.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(stem)-\(n)").appendingPathExtension(url.pathExtension)
            n += 1
        }
        return candidate
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return formatter.string(from: Date())
    }
}
