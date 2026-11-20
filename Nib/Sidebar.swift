import SwiftUI
import UniformTypeIdentifiers

/// 文件树侧栏（需求 S2：每周浏览一个文件夹里的 md）。
/// 工作区为空时根目录跟着当前文档所在文件夹走；工作区里加了文件夹就按文件夹分节（见 FileSidebar）。
/// 点 md 在当前标签组里打开（已经开着就切过去）；别的文件灰显，双击交给系统默认程序。
/// 新建、改名、移到废纸篓、在访达中显示、拷贝路径在右键里。拖动移动没做。
@MainActor
final class FileTree: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        var id: URL { url }
        var name: String { url.lastPathComponent }
        var isMarkdown: Bool { ["md", "markdown", "mdown", "mkd", "txt"].contains(url.pathExtension.lowercased()) }
    }

    @Published private(set) var children: [URL: [Entry]] = [:]
    @Published var expanded = Set<URL>()
    private var observer: NSObjectProtocol?

    init() {
        // 回到 Nib 时重读一遍：在访达或终端里改了文件，侧栏跟上。
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func entries(of folder: URL) -> [Entry] {
        if let cached = children[folder] { return cached }
        let list = Self.list(folder)
        DispatchQueue.main.async { self.children[folder] = list }
        return list
    }

    /// 重读已经展开过的文件夹，展开状态不变。
    func reload() {
        var next: [URL: [Entry]] = [:]
        for folder in children.keys where FileManager.default.fileExists(atPath: folder.path) { next[folder] = Self.list(folder) }
        children = next
    }

    /// 工作区各节默认展开，收起的记在这里。
    @Published var collapsedRoots = Set<URL>()

    func isRootExpanded(_ url: URL) -> Binding<Bool> {
        Binding(get: { !self.collapsedRoots.contains(url) }, set: { open in
            if open { self.collapsedRoots.remove(url) } else { self.collapsedRoots.insert(url) }
        })
    }

    func isExpanded(_ url: URL) -> Binding<Bool> {
        Binding(get: { self.expanded.contains(url) }, set: { open in
            if open { self.expanded.insert(url) } else { self.expanded.remove(url) }
        })
    }

    private static func list(_ folder: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return Entry(url: url, isFolder: values?.isDirectory == true && values?.isPackage != true)
        }
        .sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: 文件操作

    func open(_ entry: Entry) {
        if entry.isFolder {
            if expanded.contains(entry.url) { expanded.remove(entry.url) } else { expanded.insert(entry.url) }
        } else if entry.isMarkdown {
            NSDocumentController.shared.openDocument(withContentsOf: entry.url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    /// 在文件夹里建一篇「未命名.md」（重名往后加数字）并打开，改名点标题栏上的文件名。
    func newFile(in folder: URL) {
        let base = String(localized: "Untitled")
        var url = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        do {
            try Data().write(to: url, options: .withoutOverwriting)
            expanded.insert(folder)
            reload()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } catch {
            NSApp.presentError(error)
        }
    }

    func newFolder(in folder: URL) {
        let base = String(localized: "untitled folder")
        var url = folder.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n)")
            n += 1
        }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            expanded.insert(folder)
            reload()
        } catch {
            NSApp.presentError(error)
        }
    }

    /// 改名：开着的文档走 NSDocument（标签、最近使用一起更新），没开的直接改文件。
    func rename(_ entry: Entry, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename “\(entry.name)”")
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(string: entry.name)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.applyRename(entry, to: field.stringValue)
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: finish) } else { finish(alert.runModal()) }
        // 和访达一样先选中不含扩展名的部分。
        DispatchQueue.main.async {
            let base = entry.isFolder ? entry.name : (entry.name as NSString).deletingPathExtension
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base as NSString).length)
        }
    }

    private func applyRename(_ entry: Entry, to input: String) {
        if let document = NSDocumentController.shared.document(for: entry.url), let window = document.windowControllers.first?.window {
            DocumentRename.rename(window, to: input)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.reload() }
            return
        }
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/") else { return }
        if !entry.isFolder, (name as NSString).pathExtension.isEmpty, !entry.url.pathExtension.isEmpty { name += "." + entry.url.pathExtension }
        let target = entry.url.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: entry.url, to: target)
            if expanded.remove(entry.url) != nil { expanded.insert(target) }
            reload()
        } catch {
            NSApp.presentError(error)
        }
    }

    /// 移到废纸篓（可在访达里放回，所以不再确认）。开着且有未保存改动的文档不动，先让用户自己处理。
    func trash(_ entry: Entry) {
        if let document = NSDocumentController.shared.document(for: entry.url) {
            if document.isDocumentEdited {
                let alert = NSAlert()
                alert.messageText = String(localized: "“\(entry.name)” has unsaved changes.")
                alert.informativeText = String(localized: "Save or close it before moving it to the Trash.")
                alert.runModal()
                return
            }
            document.close()
        }
        NSWorkspace.shared.recycle([entry.url]) { _, error in
            DispatchQueue.main.async {
                if let error { NSApp.presentError(error) }
                self.reload()
            }
        }
    }
}

/// 侧栏本体。照 VS Code 的多根工作区：工作区里加了文件夹，就按文件夹分节列出（每节可折叠）；
/// 工作区为空时只列当前文档所在的文件夹。加文件夹：顶上菜单「将文件夹添加到工作区…」，或从访达把文件夹拖进侧栏。
struct FileSidebar: View {
    let documentURL: URL?
    @ObservedObject var tree: FileTree
    @ObservedObject private var settings = AppSettings.shared
    @State private var window: NSWindow?
    @State private var dropTargeted = false

    private var workspace: [URL] { settings.workspaceFolders.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    private var documentFolder: URL? { documentURL?.deletingLastPathComponent() }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !workspace.isEmpty {
                List {
                    ForEach(workspace, id: \.self) { root in
                        Section(isExpanded: tree.isRootExpanded(root)) {
                            ForEach(tree.entries(of: root)) { entry in
                                FileRow(entry: entry, tree: tree, current: documentURL, window: window)
                            }
                        } header: {
                            Text(root.lastPathComponent)
                                .help(root.path)
                                .contextMenu { rootMenu(root) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            } else if let root = documentFolder {
                List {
                    ForEach(tree.entries(of: root)) { entry in
                        FileRow(entry: entry, tree: tree, current: documentURL, window: window)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .contextMenu { folderMenu(root) }
            } else {
                VStack(spacing: 10) {
                    Text("No folder").foregroundStyle(.secondary)
                    Button("Add Folder to Workspace…", action: addFolder)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(WindowReader(window: $window))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2).opacity(dropTargeted ? 1 : 0).padding(4))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: dropFolders)
        .onAppear(perform: revealCurrent)
        .onChange(of: documentURL) { revealCurrent() }
    }

    /// 顶上一行：工作区名或当前文件夹名，点开是工作区菜单。
    private var header: some View {
        Menu {
            Button("Add Folder to Workspace…", action: addFolder)
            if !workspace.isEmpty {
                Menu("Remove Folder from Workspace") {
                    ForEach(workspace, id: \.self) { root in
                        Button(root.lastPathComponent) { remove(root) }
                    }
                }
                Button("Close Workspace") { settings.workspaceFolders = [] }
            }
            if workspace.isEmpty, let root = documentFolder {
                Divider()
                Button("New File") { tree.newFile(in: root) }
                Button("New Folder") { tree.newFolder(in: root) }
                Divider()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: workspace.isEmpty ? "folder" : "square.stack.3d.up").foregroundStyle(.secondary)
                Text(workspace.isEmpty ? (documentFolder?.lastPathComponent ?? String(localized: "No folder")) : String(localized: "Workspace"))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func rootMenu(_ root: URL) -> some View {
        folderMenu(root)
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(root.path, forType: .string)
        }
        Divider()
        Button("Remove Folder from Workspace") { remove(root) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: URL) -> some View {
        Button("New File") { tree.newFile(in: folder) }
        Button("New Folder") { tree.newFolder(in: folder) }
    }

    private func add(_ urls: [URL]) {
        var list = settings.workspaceFolders
        for url in urls where !list.contains(url.path) { list.append(url.path) }
        settings.workspaceFolders = list
    }

    private func remove(_ root: URL) {
        settings.workspaceFolders.removeAll { $0 == root.path }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.directoryURL = documentFolder
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { add(panel.urls) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// 从访达拖进来的文件夹加进工作区；拖进来的是文件就打开它。
    private func dropFolders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    var isFolder: ObjCBool = false
                    FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
                    if isFolder.boolValue { add([url]) }
                    else { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in } }
                }
            }
        }
        return true
    }

    /// 当前文档在哪个根下面，就把它到根之间的文件夹展开，当前文档看得见。
    private func revealCurrent() {
        guard let documentURL else { return }
        let roots = workspace.isEmpty ? [documentFolder].compactMap { $0 } : workspace
        for root in roots { tree.expanded.formUnion(Self.ancestors(of: documentURL, below: root)) }
    }

    /// 当前文档到根目录之间的各级文件夹。
    static func ancestors(of url: URL, below root: URL?) -> [URL] {
        guard let root else { return [] }
        var out: [URL] = []
        var folder = url.deletingLastPathComponent().standardizedFileURL
        let top = root.standardizedFileURL.path
        while folder.path.hasPrefix(top + "/") {
            out.append(folder)
            folder = folder.deletingLastPathComponent()
        }
        return out
    }
}

private struct FileRow: View {
    let entry: FileTree.Entry
    @ObservedObject var tree: FileTree
    let current: URL?
    let window: NSWindow?

    var body: some View {
        if entry.isFolder {
            DisclosureGroup(isExpanded: tree.isExpanded(entry.url)) {
                if tree.expanded.contains(entry.url) {
                    ForEach(tree.entries(of: entry.url)) { child in
                        FileRow(entry: child, tree: tree, current: current, window: window)
                    }
                }
            } label: {
                label
            }
        } else {
            label
        }
    }

    private var isCurrent: Bool { current?.standardizedFileURL == entry.url.standardizedFileURL }

    private var label: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isFolder ? "folder" : (entry.isMarkdown ? "doc.text" : "doc"))
                .font(.system(size: 12))
                .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                .frame(width: 16)
            Text(entry.isMarkdown ? (entry.name as NSString).deletingPathExtension : entry.name)
                .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                .foregroundStyle(entry.isFolder || entry.isMarkdown ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(isCurrent ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { tree.open(entry) }
        .help(entry.name)
        .contextMenu {
            let folder = entry.isFolder ? entry.url : entry.url.deletingLastPathComponent()
            Button("New File") { tree.newFile(in: folder) }
            Button("New Folder") { tree.newFolder(in: folder) }
            Divider()
            Button("Rename…") { tree.rename(entry, in: window) }
            Button("Move to Trash") { tree.trash(entry) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.url.path, forType: .string)
            }
        }
    }
}

/// 侧栏右边的分隔线，拖动改宽度（180 到 420 点），宽度记住。
struct SidebarDivider: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var start: Double?

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let base = start ?? settings.sidebarWidth
                            start = base
                            settings.sidebarWidth = min(420, max(180, base + value.translation.width))
                        }
                        .onEnded { _ in start = nil })
            )
    }
}

/// 取所在窗口，给弹出的面板挂成表单。
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}
