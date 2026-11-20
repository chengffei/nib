import SwiftUI

/// Quick Open (⇧⌘O, by file name) and Search in Workspace (⇧⌘F, by content), like VS Code's ⌘P and ⇧⌘F.
/// Both search the workspace folders; with an empty workspace they search the current document's folder.
enum FinderKind { case files, text }

/// Files under the workspace roots. Hidden folders, packages and node_modules are skipped.
struct WorkspaceFile: Sendable, Hashable {
    let url: URL
    let root: URL
    let modified: Date
    var name: String { url.lastPathComponent }
    /// Folder relative to the root, prefixed with the root name: "notes/2026/drafts".
    var folder: String {
        let parent = url.deletingLastPathComponent().path
        let rootPath = root.path
        let rest = parent.hasPrefix(rootPath) ? String(parent.dropFirst(rootPath.count)) : parent
        return root.lastPathComponent + rest
    }
}

struct TextHit: Sendable, Hashable, Identifiable {
    let file: WorkspaceFile
    let line: Int
    let snippet: String
    var id: String { "\(file.url.path)#\(line)" }
}

enum WorkspaceIndex {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    static let limit = 20000

    @MainActor
    static func roots(current: URL?) -> [URL] {
        let folders = AppSettings.shared.workspaceFolders.map { URL(fileURLWithPath: $0, isDirectory: true) }
        if !folders.isEmpty { return folders }
        return [current?.deletingLastPathComponent()].compactMap { $0 }
    }

    static func files(in roots: [URL]) -> [WorkspaceFile] {
        var out: [WorkspaceFile] = []
        var seen = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if url.lastPathComponent == "node_modules" { walker.skipDescendants(); continue }
                guard markdownExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true { continue }
                guard seen.insert(url.path).inserted else { continue }
                out.append(WorkspaceFile(url: url, root: root, modified: values?.contentModificationDate ?? .distantPast))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// Ranking: name contains the query (earlier is better) > name contains the letters in order > path contains them in order.
    /// Several words separated by spaces must all match. An empty query lists the most recently modified files.
    static func rank(_ files: [WorkspaceFile], query: String) -> [WorkspaceFile] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return Array(files.sorted { $0.modified > $1.modified }.prefix(50)) }
        var scored: [(WorkspaceFile, Int)] = []
        for file in files {
            let name = file.name.lowercased()
            let path = (file.folder + "/" + file.name).lowercased()
            var total = 0
            var ok = true
            for word in words {
                if let range = name.range(of: word) {
                    total += 1000 - name.distance(from: name.startIndex, to: range.lowerBound)
                } else if isSubsequence(word, of: name) {
                    total += 500
                } else if path.contains(word) {
                    total += 300
                } else if isSubsequence(word, of: path) {
                    total += 100
                } else { ok = false; break }
            }
            if ok { scored.append((file, total - name.count)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.modified > $1.0.modified }.prefix(50).map(\.0)
    }

    private static func isSubsequence(_ needle: String, of hay: String) -> Bool {
        var it = hay.makeIterator()
        for c in needle {
            var found = false
            while let h = it.next() { if h == c { found = true; break } }
            if !found { return false }
        }
        return true
    }

    /// Lines containing the query, case-insensitive. At most 5 per file and 300 in total; recently modified files first.
    /// Files are scanned in parallel; results keep the recency order.
    static func search(_ query: String, in files: [WorkspaceFile]) -> [TextHit] {
        let needle = Array(query.utf8).map(lowerASCII)
        let ordered = files.sorted { $0.modified > $1.modified }
        let slots = SlotBox(count: ordered.count)
        DispatchQueue.concurrentPerform(iterations: ordered.count) { index in
            let file = ordered[index]
            // Byte-level prefilter first (ASCII letters folded to lower case): decoding and case-insensitive
            // String search over a few thousand files takes seconds, a byte scan takes milliseconds.
            guard let data = try? Data(contentsOf: file.url, options: .mappedIfSafe),
                  contains(data, needle), let text = String(data: data, encoding: .utf8) else { return }
            var found: [TextHit] = []
            var number = 0
            text.enumerateLines { line, stop in
                number += 1
                guard line.range(of: query, options: .caseInsensitive) != nil else { return }
                found.append(TextHit(file: file, line: number, snippet: snippet(line, around: query)))
                if found.count >= 5 { stop = true }
            }
            slots.set(index, found)
        }
        return Array(slots.all.joined().prefix(300))
    }

    /// Per-file result slots written from concurrent workers.
    private final class SlotBox: @unchecked Sendable {
        private var slots: [[TextHit]]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: [], count: count) }
        func set(_ index: Int, _ hits: [TextHit]) { lock.lock(); slots[index] = hits; lock.unlock() }
        var all: [[TextHit]] { lock.lock(); defer { lock.unlock() }; return slots }
    }

    private static func lowerASCII(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }

    private static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        guard let first = needle.first, data.count >= needle.count else { return false }
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let last = bytes.count - needle.count
            // When the first byte has no case (CJK, digits, punctuation), memchr jumps straight to candidates.
            let caseless = !(first >= 97 && first <= 122)
            var i = 0
            while i <= last {
                if caseless {
                    guard let base = bytes.baseAddress,
                          let hit = memchr(base + i, Int32(first), last - i + 1) else { return false }
                    i = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                }
                if lowerASCII(bytes[i]) == first {
                    var j = 1
                    while j < needle.count && lowerASCII(bytes[i + j]) == needle[j] { j += 1 }
                    if j == needle.count { return true }
                }
                i += 1
            }
            return false
        }
    }

    /// Long lines are trimmed around the first match so the match stays visible.
    private static func snippet(_ line: String, around query: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 90, let range = trimmed.range(of: query, options: .caseInsensitive) else { return trimmed }
        let start = trimmed.index(range.lowerBound, offsetBy: -30, limitedBy: trimmed.startIndex) ?? trimmed.startIndex
        let end = trimmed.index(start, offsetBy: 90, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
        return (start > trimmed.startIndex ? "…" : "") + trimmed[start..<end] + (end < trimmed.endIndex ? "…" : "")
    }
}

/// Opening a file from search and jumping to the match. The document may not exist yet or may be asleep,
/// so the request waits here until that document's editor reports ready.
@MainActor
enum Reveal {
    private struct Request { let query: String; let line: Int }
    private struct WeakController { weak var controller: EditorController? }
    private static var pending: [String: Request] = [:]
    private static var controllers: [String: WeakController] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    static func register(_ controller: EditorController, for url: URL) {
        controllers[key(url)] = WeakController(controller: controller)
    }

    static func open(_ url: URL, query: String?, line: Int) {
        if let query { pending[key(url)] = Request(query: query, line: line) }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            MainActor.assumeIsolated {
                if let error { NSApp.presentError(error); return }
                // Already open and loaded: no new ready message will come, so run now.
                if let controller = controllers[key(url)]?.controller, controller.ready { deliver(to: controller, url: url) }
            }
        }
    }

    /// Called when a document's editor reports ready.
    static func deliver(to controller: EditorController, url: URL) {
        guard let request = pending.removeValue(forKey: key(url)) else { return }
        controller.webView?.send("nib.findAt(query, line)", ["query": request.query, "line": request.line])
    }
}

/// The floating panel at the top of the window: a search field and a result list, operated by keyboard.
struct FinderPanel: View {
    let kind: FinderKind
    let current: URL?
    let close: () -> Void

    @State private var query = ""
    @State private var files: [WorkspaceFile] = []
    @State private var fileResults: [WorkspaceFile] = []
    @State private var textResults: [TextHit] = []
    @State private var selection = 0
    @State private var loading = true
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    private var count: Int { kind == .files ? fileResults.count : textResults.count }
    private var roots: [URL] { WorkspaceIndex.roots(current: current) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: kind == .files ? "doc.text.magnifyingglass" : "text.magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(kind == .files ? "Go to File" : "Search in Workspace", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { openSelected() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            if roots.isEmpty {
                Divider()
                Text("Add a folder to the workspace to search it.")
                    .foregroundStyle(.secondary).font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            } else if count > 0 {
                Divider()
                results
            } else if !loading, !searching, !query.isEmpty {
                Divider()
                Text("No results").foregroundStyle(.secondary).font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        }
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .onAppear {
            if NibApp.debug, let initial = ProcessInfo.processInfo.environment["NIB_QUERY"] { query = initial }
            focused = true
            load()
        }
        .onChange(of: query) { refresh() }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.escape) { close(); return .handled }
        .onExitCommand { close() }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if kind == .files {
                        ForEach(Array(fileResults.enumerated()), id: \.element) { index, file in
                            row(index) { fileRow(file) }
                        }
                    } else {
                        ForEach(Array(textResults.enumerated()), id: \.element.id) { index, hit in
                            row(index) { hitRow(hit) }
                        }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 380)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { proxy.scrollTo(selection) }
        }
    }

    private func row<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == selection ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .id(index)
            .onTapGesture {
                selection = index
                openSelected()
            }
    }

    private func fileRow(_ file: WorkspaceFile) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(file.url.deletingPathExtension().lastPathComponent).lineLimit(1)
            Text(file.folder).foregroundStyle(.secondary).font(.system(size: 11)).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
    }

    private func hitRow(_ hit: TextHit) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(hit.file.url.deletingPathExtension().lastPathComponent).font(.system(size: 11, weight: .semibold))
                Text(hit.file.folder).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                Text(verbatim: "\(hit.line)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(highlighted(hit.snippet)).font(.system(size: 13)).lineLimit(1)
        }
    }

    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard !query.isEmpty, let range = out.range(of: query, options: .caseInsensitive) else { return out }
        out[range].font = .system(size: 13, weight: .bold)
        out[range].foregroundColor = .accentColor
        return out
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        selection = (selection + delta + count) % count
        return .handled
    }

    private func load() {
        let roots = self.roots
        Task {
            let started = Date()
            let list = await Task.detached(priority: .userInitiated) { WorkspaceIndex.files(in: roots) }.value
            NibApp.log("workspace index \(list.count) files, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            files = list
            loading = false
            refresh()
        }
    }

    private func refresh() {
        selection = 0
        searchTask?.cancel()
        let query = self.query
        let files = self.files
        if kind == .files {
            fileResults = WorkspaceIndex.rank(files, query: query)
            return
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { textResults = []; searching = false; return }
        searching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let started = Date()
            let hits = await Task.detached(priority: .userInitiated) { WorkspaceIndex.search(query, in: files) }.value
            guard !Task.isCancelled else { return }
            NibApp.log("workspace search \(files.count) files, \(hits.count) hits, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            textResults = hits
            searching = false
        }
    }

    private func openSelected() {
        switch kind {
        case .files:
            guard fileResults.indices.contains(selection) else { return }
            Reveal.open(fileResults[selection].url, query: nil, line: 1)
        case .text:
            guard textResults.indices.contains(selection) else { return }
            let hit = textResults[selection]
            Reveal.open(hit.file.url, query: query, line: hit.line)
        }
        close()
    }
}
