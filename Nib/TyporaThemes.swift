import AppKit

/// Typora theme: one .css plus a same-named folder (fonts, images).
/// Only looked up in Nib's own theme folder; what is compatible is the Typora theme format, and Typora the app's folders are not read.
enum TyporaThemes {
    struct Theme: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }
        /// Same naming as in the Typora menu: github → Github, konayuki-dark → Konayuki Dark.
        var name: String {
            url.deletingPathExtension().lastPathComponent
                .split(whereSeparator: { $0 == "-" || $0 == "_" })
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    static var nibFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Nib/themes", isDirectory: true)
    }

    /// Themes in the theme folder. base.user.css and xxx.user.css are Typora user overrides, not themes.
    static func all() -> [Theme] {
        let files = (try? FileManager.default.contentsOfDirectory(at: nibFolder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension.lowercased() == "css" && !$0.lastPathComponent.hasSuffix(".user.css") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Theme.init)
    }

    /// Whether the selected theme is in the theme folder; themes previously selected from the Typora folder are no longer recognised.
    static func isInFolder(_ path: String) -> Bool {
        URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == nibFolder.standardizedFileURL.path
    }

    @MainActor
    /// Open the theme guide bundled with the app (docs/themes*.md). Copy it to the cache directory first and then open it, so edits made inside the app bundle are not lost.
    static func openGuide() {
        let zh = AppSettings.currentLanguage.hasPrefix("zh")
        guard let src = Bundle.main.url(forResource: zh ? "themes.zh-Hans" : "themes", withExtension: "md", subdirectory: "docs") else { return }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Nib", isDirectory: true)
        let dest = cache.appendingPathComponent(zh ? "Nib 主题说明.md" : "Nib Themes.md")
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: dest)
        guard (try? FileManager.default.copyItem(at: src, to: dest)) != nil else { return }
        NSDocumentController.shared.openDocument(withContentsOf: dest, display: true) { _, _, _ in }
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: nibFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(nibFolder)
    }

    /// Read out the whole CSS that can be fed straight to the web page: expand @import, replace relative-path url() with nib-file addresses the page can read,
    /// and append base.user.css and "themename.user.css" at the end by Typora's rules. Returns nil if unreadable.
    static func bundledCSS(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard var css = load(url, depth: 0) else { return nil }
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        for extra in ["base.user.css", "\(name).user.css"] {
            if let more = load(folder.appendingPathComponent(extra), depth: 0) { css += "\n" + more }
        }
        return css
    }

    private static func load(_ url: URL, depth: Int) -> String? {
        guard depth < 5, var css = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let folder = url.deletingLastPathComponent()
        // @import url("x.css"); / @import 'x.css';
        css = replace(in: css, pattern: #"@import\s+(?:url\(\s*)?["']?([^"')\s;]+)["']?\s*\)?\s*;"#) { match in
            let target = match[1]
            if target.hasPrefix("http") { return "" }
            return load(folder.appendingPathComponent(target).standardizedFileURL, depth: depth + 1) ?? ""
        }
        // url(...): network addresses, data: and #id are left alone; the rest resolve against the directory of the CSS file.
        css = replace(in: css, pattern: #"url\(\s*(["']?)([^"')]+)\1\s*\)"#) { match in
            let target = match[2].trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("data:") || target.hasPrefix("http") || target.hasPrefix("#") || target.hasPrefix("nib-file:") {
                return match[0]
            }
            let clean = target.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? target
            let file = (clean.hasPrefix("/") ? URL(fileURLWithPath: clean) : folder.appendingPathComponent(clean.removingPercentEncoding ?? clean))
                .standardizedFileURL
            let encoded = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file.path
            return "url(\"nib-file://local\(encoded)\")"
        }
        return css
    }

    private static func replace(in text: String, pattern: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        result += source.substring(from: last)
        return result
    }
}
