import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum EditorMode: String, CaseIterable {
    case read, edit, source
}

/// One per document window: the SwiftUI toolbar, the file watcher and the editor in the web view communicate through it.
@MainActor
final class EditorController: ObservableObject {
    @Published var mode: EditorMode = .read
    /// Statistics for the whole text and for the selection (nil when nothing is selected), computed by the web page and reported back.
    @Published var stats = TextStats()
    @Published var selectionStats: TextStats?
    /// Outline: the list of headings and which one is currently being read (-1 if none).
    @Published var outline: [OutlineItem] = []
    @Published var outlineCurrent = -1
    /// Whether the two title-bar panels are open (while open, the title-bar tools do not hide).
    @Published var showOutline = false
    @Published var showWordCount = false
    /// Quick Open / Search in Workspace panel shown over this window (nil when closed).
    @Published var finder: FinderKind?
    /// The editor has loaded the current text (reset while waking from hibernation).
    var ready = false
    weak var webView: EditorWebView?
    private var watcher: FileWatcher?
    private var watchedURL: URL?
    var fileURL: URL? { watchedURL }

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        mode = newMode
        run("nib.setMode('\(newMode.rawValue)')")
    }

    func run(_ script: String) {
        NibApp.log("command \(script)")
        webView?.evaluateJavaScript(script)
    }

    /// Watch the file on disk: after another program rewrites it, reload in place if there are no unsaved changes.
    func watch(_ url: URL?) {
        guard url != watchedURL else { return }
        watchedURL = url
        if let url {
            Reveal.register(self, for: url)
            if ready { Reveal.deliver(to: self, url: url) }
        }
        watcher = url.map { url in FileWatcher(url: url) { [weak self] in self?.reloadFromDisk(url) } }
    }

    private func reloadFromDisk(_ url: URL) {
        guard let document = NSDocumentController.shared.document(for: url), let type = document.fileType else { return }
        guard !document.isDocumentEdited else {
            NibApp.log("disk changed, skipped: unsaved edits")
            return
        }
        // In the gap while the writer deletes and recreates the file it does not exist; wait until it is created.
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        // Nib's own saves also trigger the watcher; if the modification date matches what the document recorded, do nothing.
        if let onDisk, let known = document.fileModificationDate, abs(onDisk.timeIntervalSince(known)) < 0.001 { return }
        do {
            try document.revert(toContentsOf: url, ofType: type)
            NibApp.log("reloaded from disk")
        } catch {
            NibApp.log("reload failed \(error.localizedDescription)")
        }
    }
}

/// Editing area: CodeMirror 6 running in a WKWebView (Nib/Editor, bundled from Web/).
/// The document's source of truth is still the single `text` string; the web page only displays and edits, and changes are passed back as they are.
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    /// Directory containing the document; relative image paths and links resolve against it. nil for an unsaved new document.
    let baseDirectory: String?
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, controller: controller) }

    func makeNSView(context: Context) -> EditorHost {
        NibApp.log("makeNSView len=\(text.utf16.count)")
        let coordinator = context.coordinator
        coordinator.lastBase = baseDirectory
        let host = EditorHost(coordinator: coordinator)
        coordinator.host = host
        host.wake()
        return host
    }

    func updateNSView(_ host: EditorHost, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        if baseDirectory != coordinator.lastBase {
            coordinator.lastBase = baseDirectory
            host.webView?.send("nib.setBaseDir(base)", ["base": baseDirectory ?? NSNull()])
        }
        // Only external changes (disk reload, Versions rollback) are pushed to the web page; the user's own typing is not pushed back, otherwise the cursor would be reset.
        guard text != coordinator.lastText else { return }
        // A sleeping tab has no web engine; on waking it loads the latest text directly.
        guard let webView = host.webView else { return }
        NibApp.log("push external len=\(text.utf16.count)")
        coordinator.lastText = text
        webView.send("nib.setText(text)", ["text": text])
    }

    @MainActor
    final class Coordinator {
        var text: Binding<String>
        let controller: EditorController
        var lastText = ""
        var lastBase: String?
        weak var host: EditorHost?

        init(text: Binding<String>, controller: EditorController) {
            self.text = text
            self.controller = controller
        }

        func handle(_ type: String, _ body: [String: Any]) {
            switch type {
            case "change":
                guard let newText = body["text"] as? String else { return }
                lastText = newText
                text.wrappedValue = newText
            case "mode":
                if let mode = (body["mode"] as? String).flatMap(EditorMode.init) { controller.mode = mode }
            case "ready":
                if let mode = (body["mode"] as? String).flatMap(EditorMode.init) { controller.mode = mode }
                NibApp.log("ready")
                host?.didBecomeReady()
                controller.ready = true
                if let url = controller.fileURL { Reveal.deliver(to: controller, url: url) }
                // For debugging: the script in NIB_EVAL runs once after the first document is ready, to test a real window without stealing the keyboard.
                // For debugging: NIB_FINDER=files|text opens the search panel (query from NIB_QUERY); NIB_REVEAL=path:line:query opens a search hit.
                if NibApp.debug, let env = NibApp.finderOnce {
                    NibApp.finderOnce = nil
                    let parts = env.split(separator: ":", maxSplits: 2).map(String.init)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in
                        if parts.count == 3 { Reveal.open(URL(fileURLWithPath: parts[0]), query: parts[2], line: Int(parts[1]) ?? 1) }
                        else { controller?.finder = env == "text" ? .text : .files }
                    }
                }
                if let script = NibApp.evalOnce {
                    NibApp.evalOnce = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in controller?.run(script) }
                }
                // Once this one is shown, prepare an engine for the next one.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { EditorPool.shared.prewarm() }
            case "open":
                if let link = body["url"] as? String { open(link) }
            case "theme":
                // Measure whether the theme is dark or light and switch the window appearance accordingly.
                if let dark = body["dark"] as? Bool { AppSettings.shared.typoraDark = dark }
                // The theme background colour is also reported back: the title bar is painted the same colour so the top and the body look continuous.
                if let rgb = body["bg"] as? [Double], rgb.count == 3 {
                    AppSettings.shared.typoraBackground = NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1)
                }
            case "outline":
                let items = body["items"] as? [[String: Any]] ?? []
                controller.outline = items.enumerated().map { index, item in
                    OutlineItem(index: index, level: item["level"] as? Int ?? 1, text: item["text"] as? String ?? "")
                }
            case "outlineCurrent":
                controller.outlineCurrent = body["index"] as? Int ?? -1
            case "stats":
                controller.stats = TextStats(body)
                controller.selectionStats = (body["selection"] as? [String: Any]).map(TextStats.init)
            case "log":
                NibApp.log("js \(body["text"] as? String ?? "")")
            default:
                break
            }
        }

        /// Hand URLs to the browser; relative links to other md files open in a new tab; for other files only viewable types are let through, the rest are revealed in Finder.
        private func open(_ link: String) {
            if let url = URL(string: link), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
                return
            }
            var path = link
            if path.lowercased().hasPrefix("file://") { path = URL(string: link)?.path ?? "" }
            if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
            path = path.removingPercentEncoding ?? path
            guard !path.isEmpty else { return }
            let file: URL
            if path.hasPrefix("/") {
                file = URL(fileURLWithPath: path)
            } else if path.hasPrefix("~") {
                file = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            } else if let lastBase {
                file = URL(fileURLWithPath: lastBase).appendingPathComponent(path)
            } else {
                return
            }
            let target = file.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
                NibApp.log("link target missing \(target.path)")
                NSSound.beep()
                return
            }
            NibApp.log("open link \(target.path)")
            let type = UTType(filenameExtension: target.pathExtension)
            if ["md", "markdown", "mdown", "txt"].contains(target.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: target, display: true) { _, _, _ in }
            } else if isDirectory.boolValue || type?.conforms(to: .image) == true || type?.conforms(to: .pdf) == true
                        || type?.conforms(to: .html) == true {
                NSWorkspace.shared.open(target)
            } else {
                // Never open scripts, programs and similar things that execute on a click on the user's behalf.
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }
}

/// Keeps an empty editor view with an already loaded engine ready. When a document opens it is taken and filled, saving the time of loading an engine each time.
@MainActor
final class EditorPool {
    static let shared = EditorPool()
    private var spare: EditorWebView?

    func prewarm() {
        if spare == nil { spare = EditorWebView.make() }
    }

    func take() -> EditorWebView {
        let webView = spare ?? EditorWebView.make()
        spare = nil
        return webView
    }
}

/// Receives messages from the web page. A separate object so that WKUserContentController does not strongly retain the web view itself.
private final class MessageRouter: NSObject, WKScriptMessageHandler {
    weak var view: EditorWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        view?.receive(type, body)
    }
}

final class EditorWebView: WKWebView {
    /// All live engines; they must be notified one by one when settings change.
    static let all = NSHashTable<EditorWebView>.weakObjects()
    var target: EditorView.Coordinator?
    private var booted = false
    private var queue: [(String, [String: Any])] = []

    static func make() -> EditorWebView {
        NibApp.log("webview create")
        let router = MessageRouter()
        let config = WKWebViewConfiguration()
        config.userContentController.add(router, name: "nib")
        // Settings are injected before page scripts run, so the engine starts with the right font and theme and does not flash the default style first.
        if let data = try? JSONSerialization.data(withJSONObject: AppSettings.shared.javascriptPayload),
           let json = String(data: data, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: "window.__nibSettings = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if NibApp.debug {
            config.userContentController.addUserScript(
                WKUserScript(source: "window.__nibDebug = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: "nib-file")
        let webView = EditorWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 900), configuration: config)
        router.view = webView
        all.add(webView)
        // Transparent background: the SwiftUI layer provides the background colour, so dark mode does not flash white first.
        webView.setValue(false, forKey: "drawsBackground")
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("Editor") {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
        return webView
    }

    /// Call a function in the web page. If the engine has not finished loading, queue the call and replay in order once loaded.
    func send(_ script: String, _ arguments: [String: Any]) {
        guard booted else {
            queue.append((script, arguments))
            return
        }
        callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page)
    }

    fileprivate func receive(_ type: String, _ body: [String: Any]) {
        if type == "boot" {
            NibApp.log("webview booted, page took \(body["ms"] as? Int ?? -1) ms")
            booted = true
            let waiting = queue
            queue = []
            for (script, arguments) in waiting { send(script, arguments) }
            return
        }
        target?.handle(type, body)
    }
}

/// SwiftUI holds this container; the web engine inside can be unloaded when the tab goes to the background and reinstalled when it returns.
final class EditorHost: NSView {
    let coordinator: EditorView.Coordinator
    private(set) var webView: EditorWebView?
    private var placeholder: NSImageView?
    private var savedScroll = 0.0
    private var hibernating = false
    var lastSelected = Date()

    init(coordinator: EditorView.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: NSRect(x: 0, y: 0, width: 860, height: 900))
        EditorHibernator.shared.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether this tab is the one currently shown in its window.
    var isSelectedTab: Bool {
        guard let window else { return false }
        return WindowTabs.shared.isSelected(window)
    }

    var canHibernate: Bool { webView != nil && !hibernating && coordinator.controller.mode == .read }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A newly opened document joins the tabs of the existing window instead of opening a new one.
        if let window {
            WindowTabs.shared.adopt(window)
            TabStripInstaller.install(in: window, controller: coordinator.controller)
        }
        if let webView { window?.makeFirstResponder(webView) }
        EditorHibernator.shared.scheduleEvaluate()
    }

    /// Install the engine and load the current text. Newly opened documents and wake-ups from sleep both go through here.
    func wake() {
        guard webView == nil else { return }
        if placeholder != nil { NibApp.log("wake from hibernation") }
        let webView = EditorPool.shared.take()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView, positioned: .below, relativeTo: placeholder)
        webView.target = coordinator
        self.webView = webView
        coordinator.controller.webView = webView
        coordinator.controller.ready = false
        let text = coordinator.text.wrappedValue
        coordinator.lastText = text
        webView.send("nib.load(text, base, top)",
                     ["text": text, "base": coordinator.lastBase ?? NSNull(), "top": savedScroll])
        window?.makeFirstResponder(webView)
    }

    func didBecomeReady() {
        guard let placeholder else { return }
        self.placeholder = nil
        // Remove the snapshot after the engine has drawn its first frame, so there is no flicker in between.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { placeholder.removeFromSuperview() }
    }

    /// Compress the snapshot to PNG before keeping it: the raw bitmap is over ten MB, compressed a few hundred KB, and it is decoded only when displayed.
    private func showPlaceholder(_ image: NSImage?) {
        guard let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil), let size = image?.size else { return }
        let view = NSImageView(frame: bounds)
        view.imageScaling = .scaleNone
        view.imageAlignment = .alignTopLeft
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        placeholder = view
        DispatchQueue.global(qos: .utility).async {
            let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            DispatchQueue.main.async { [weak view] in
                guard let view, let data, let compressed = NSImage(data: data) else { return }
                compressed.size = size
                view.image = compressed
            }
        }
    }

    /// Unload the engine and leave a snapshot as a placeholder. Only done for background tabs in reading mode: unloading a tab being edited would lose its undo history.
    func hibernate() {
        guard canHibernate, let webView else { return }
        hibernating = true
        webView.evaluateJavaScript("nib.scrollTop()") { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let top = (result as? NSNumber)?.doubleValue ?? 0
                webView.takeSnapshot(with: nil) { [weak self] image, _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.hibernating = false
                        // If the user switched back or started editing during the short wait for the snapshot, do not unload.
                        guard self.webView === webView, !self.isSelectedTab, self.coordinator.controller.mode == .read else { return }
                        self.savedScroll = top
                        self.showPlaceholder(image)
                        webView.target = nil
                        webView.removeFromSuperview()
                        self.webView = nil
                        NibApp.log("hibernated, snapshot \(image != nil ? "ok" : "none"), scroll \(Int(top))")
                    }
                }
            }
        }
    }
}

/// Decides which background tabs keep their engine. Each engine is a 50 to 100 MB web process, so with many tabs they must be unloaded.
@MainActor
final class EditorHibernator {
    static let shared = EditorHibernator()
    /// Besides the visible tab, keep a few most recently used ones loaded so switching back and forth does not wait.
    static let keepAlive = 2
    private var hosts: [WeakHost] = []
    private var scheduled = false

    private struct WeakHost { weak var host: EditorHost? }

    private init() {
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didChangeOcclusionStateNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Waking does not wait: switching to a sleeping tab must install the engine at once. Unloading is not urgent; compute after the UI settles.
                    EditorHibernator.shared.wakeSelected()
                    EditorHibernator.shared.scheduleEvaluate()
                }
            }
        }
    }

    func register(_ host: EditorHost) {
        hosts.append(WeakHost(host: host))
    }

    func scheduleEvaluate() {
        guard !scheduled else { return }
        scheduled = true
        // Switching tabs sends several notifications in a row; wait until the UI settles and compute once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.scheduled = false
            self?.evaluate()
        }
    }

    func wakeSelected() {
        let now = Date()
        for host in hosts.compactMap(\.host) where host.isSelectedTab {
            host.lastSelected = now
            host.wake()
        }
    }

    private func evaluate() {
        hosts.removeAll { $0.host == nil }
        wakeSelected()
        let live = hosts.compactMap(\.host).filter { $0.window != nil }
        let background = live.filter { !$0.isSelectedTab && $0.webView != nil }
            .sorted { $0.lastSelected > $1.lastSelected }
        NibApp.log("evaluate hosts=\(hosts.count) live=\(live.count) selected=\(live.filter(\.isSelectedTab).count) background=\(background.count)")
        for host in background.dropFirst(Self.keepAlive) { host.hibernate() }
    }
}

/// Serves local images to <img> in the web page. Only image types are allowed; any other file is refused.
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = URL(fileURLWithPath: url.path)
        // Fonts are allowed besides images: Typora themes bring their own font files.
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) || type.conforms(to: .font),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else {
            // Reply with an empty 404 rather than an error, so the <img> error event fires in the web page and shows "image cannot be displayed".
            NibApp.log("image refused \(file.path)")
            if let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil) {
                task.didReceive(response)
            }
            task.didFinish()
            return
        }
        let response = URLResponse(url: url, mimeType: type.preferredMIMEType ?? "application/octet-stream",
                                   expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Watch a file for being rewritten. Atomic writes replace the file itself, so after a rename or delete event the same path must be watched again.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: () -> Void
    nonisolated(unsafe) private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        arm(retries: 0)
    }

    deinit { source?.cancel() }

    private func arm(retries: Int) {
        source?.cancel()
        source = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // In the gap while the writer deletes and recreates the file it does not exist; wait a moment and retry.
            guard retries > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm(retries: retries - 1) }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let current = self.source else { return }
                let replaced = !current.data.isDisjoint(with: [.rename, .delete])
                if replaced { self.arm(retries: 30) }
                self.schedule()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
        // Before re-watching, the new file may already be fully written, so check once more.
        if retries > 0 { schedule() }
    }

    /// Writers often finish in several steps; collect for 80 ms before notifying once.
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
