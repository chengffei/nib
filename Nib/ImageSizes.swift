import Foundation
import ImageIO

/// Intrinsic sizes of the local images a document references, read from file headers only (no decoding).
/// Sent to the web page before the text loads, so each image takes its final size before it has loaded and nothing below it jumps.
/// Keys are absolute file paths, matching the editor's `sizeKey` (the decoded path of the image's nib-file URL).
enum ImageSizes {
    static let limit = 500

    static func scan(_ text: String, base: String?) -> [String: [Int]] {
        guard text.contains("!["), let pattern = try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(\s*(<[^>\n]*>|[^)\s]+)"#) else { return [:] }
        var out: [String: [Int]] = [:]
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).prefix(limit) {
            guard let path = resolve(ns.substring(with: match.range(at: 1)), base: base), out[path] == nil,
                  let size = size(atPath: path) else { continue }
            out[path] = size
        }
        return out
    }

    /// Same rules as the editor's resolveImage: remote images are skipped, relative paths resolve against the document folder.
    static func resolve(_ source: String, base: String?) -> String? {
        var raw = source.trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("<"), raw.hasSuffix(">") { raw = String(raw.dropFirst().dropLast()) }
        let lower = raw.lowercased()
        if raw.isEmpty || lower.hasPrefix("http:") || lower.hasPrefix("https:") || lower.hasPrefix("data:") { return nil }
        if lower.hasPrefix("file:") { return URL(string: raw)?.standardizedFileURL.path }
        let decoded = raw.removingPercentEncoding ?? raw
        let path: String
        if decoded.hasPrefix("/") { path = decoded } else if let base { path = (base as NSString).appendingPathComponent(decoded) } else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Pixel size from the header, with EXIF orientation applied (rotated photos swap width and height).
    static func size(atPath path: String) -> [Int]? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? [height, width] : [width, height]
    }
}
