import AppKit

/// Typora 主题：一个 .css 加一个同名文件夹（字体、图片）。从两处找：
/// Nib 自己的主题文件夹，和本机 Typora 的主题文件夹（装过 Typora 的话，那边的主题直接能用）。
enum TyporaThemes {
    struct Theme: Identifiable, Hashable {
        let url: URL
        var id: String { url.path }
        /// 和 Typora 菜单里一样的叫法：github → Github，konayuki-dark → Konayuki Dark。
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

    static var typoraFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("abnerworks.Typora/themes", isDirectory: true)
    }

    /// 两个文件夹里的主题。同名的以 Nib 文件夹为准。base.user.css 和 xxx.user.css 是 Typora 的用户覆盖，不算主题。
    static func all() -> [Theme] {
        var seen = Set<String>()
        var result: [Theme] = []
        for folder in [nibFolder, typoraFolder] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
            where file.pathExtension.lowercased() == "css" && !file.lastPathComponent.hasSuffix(".user.css") {
                let key = file.deletingPathExtension().lastPathComponent.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(Theme(url: file))
            }
        }
        return result
    }

    static func openFolder() {
        try? FileManager.default.createDirectory(at: nibFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(nibFolder)
    }

    /// 读出能直接塞进网页的整份 CSS：展开 @import，把相对路径的 url() 换成网页能读的 nib-file 地址，
    /// 末尾按 Typora 的规矩接上 base.user.css 和「主题名.user.css」。读不到返回 nil。
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
        // url(...)：网络地址、data:、#id 保持不动，其余按 CSS 文件所在目录解析。
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
