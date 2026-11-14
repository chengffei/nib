import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum EditorMode: String, CaseIterable {
    case read, edit, source
}

/// 一个文档窗口对应一个：SwiftUI 工具栏、文件监听和网页里的编辑器靠它互通。
@MainActor
final class EditorController: ObservableObject {
    @Published var mode: EditorMode = .read
    weak var webView: EditorWebView?
    private var watcher: FileWatcher?
    private var watchedURL: URL?

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        mode = newMode
        run("nib.setMode('\(newMode.rawValue)')")
    }

    func run(_ script: String) {
        NibApp.log("command \(script)")
        webView?.evaluateJavaScript(script)
    }

    /// 盯住磁盘上的文件：别的程序改写它之后，没有未保存改动就原地重载。
    func watch(_ url: URL?) {
        guard url != watchedURL else { return }
        watchedURL = url
        watcher = url.map { url in FileWatcher(url: url) { [weak self] in self?.reloadFromDisk(url) } }
    }

    private func reloadFromDisk(_ url: URL) {
        guard let document = NSDocumentController.shared.document(for: url), let type = document.fileType else { return }
        guard !document.isDocumentEdited else {
            NibApp.log("disk changed, skipped: unsaved edits")
            return
        }
        // 写入方先删后建的空档里文件不存在，等它建好再说。
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        // Nib 自己保存也会触发监听；修改时间和文档记的一样就不用动。
        if let onDisk, let known = document.fileModificationDate, abs(onDisk.timeIntervalSince(known)) < 0.001 { return }
        do {
            try document.revert(toContentsOf: url, ofType: type)
            NibApp.log("reloaded from disk")
        } catch {
            NibApp.log("reload failed \(error.localizedDescription)")
        }
    }
}

/// 编辑区：WKWebView 里跑 CodeMirror 6（Nib/Editor，由 Web/ 打包）。
/// 文档真相仍是 `text` 这一个字符串；网页只负责显示和编辑，改动原样传回来。
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    /// 文档所在目录；相对路径的图片和链接按它解析。未保存的新文档为 nil。
    let baseDirectory: String?
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, controller: controller) }

    func makeNSView(context: Context) -> EditorWebView {
        NibApp.log("makeNSView len=\(text.utf16.count)")
        let coordinator = context.coordinator
        let webView = EditorPool.shared.take()
        webView.target = coordinator
        controller.webView = webView
        coordinator.lastText = text
        coordinator.lastBase = baseDirectory
        webView.send("nib.load(text, base)", ["text": text, "base": baseDirectory ?? NSNull()])
        return webView
    }

    func updateNSView(_ webView: EditorWebView, context: Context) {
        let coordinator = context.coordinator
        if baseDirectory != coordinator.lastBase {
            coordinator.lastBase = baseDirectory
            webView.send("nib.setBaseDir(base)", ["base": baseDirectory ?? NSNull()])
        }
        // 只有外部改动（磁盘重载、Versions 回滚）才推给网页；自己打的字不回推，否则光标会被重置。
        guard text != coordinator.lastText else { return }
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
                // 调试用：NIB_EVAL 里的脚本在第一篇文档就绪后执行一次，用来不抢键盘地测真实窗口。
                if let script = NibApp.evalOnce {
                    NibApp.evalOnce = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak controller] in controller?.run(script) }
                }
                // 这篇显示出来之后，再给下一篇备好一个内核。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { EditorPool.shared.prewarm() }
            case "open":
                if let link = body["url"] as? String { open(link) }
            case "log":
                NibApp.log("js \(body["text"] as? String ?? "")")
            default:
                break
            }
        }

        /// 网址交给浏览器；指向别的 md 的相对链接在新标签里打开；其他文件只放行看的类型，其余在访达里显示。
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
                // 脚本、程序之类点一下就执行的东西不替用户打开。
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
        }
    }
}

/// 备着一个已经加载好内核的空编辑视图。开文档时拿来就填内容，省掉每次重新加载内核的时间。
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

/// 收网页发来的消息。单独一个对象是为了不让 WKUserContentController 强引用住网页视图本身。
private final class MessageRouter: NSObject, WKScriptMessageHandler {
    weak var view: EditorWebView?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        view?.receive(type, body)
    }
}

final class EditorWebView: WKWebView {
    var target: EditorView.Coordinator?
    private var booted = false
    private var queue: [(String, [String: Any])] = []

    static func make() -> EditorWebView {
        NibApp.log("webview create")
        let router = MessageRouter()
        let config = WKWebViewConfiguration()
        config.userContentController.add(router, name: "nib")
        if NibApp.debug {
            config.userContentController.addUserScript(
                WKUserScript(source: "window.__nibDebug = true;", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: "nib-file")
        let webView = EditorWebView(frame: NSRect(x: 0, y: 0, width: 860, height: 900), configuration: config)
        router.view = webView
        // 透明底：背景色由 SwiftUI 那层给，深色模式下不会先闪一下白。
        webView.setValue(false, forKey: "drawsBackground")
        if let directory = Bundle.main.resourceURL?.appendingPathComponent("Editor") {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
        return webView
    }

    /// 调网页里的函数。内核还没加载完就先排队，加载完按顺序补发。
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 新打开的文档并进现有窗口的标签页，不另开窗口。
        window?.tabbingMode = .preferred
        window?.makeFirstResponder(self)
    }
}

/// 给网页里的 <img> 读本地图片。只放行图片类型，别的文件一律拒绝。
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let file = URL(fileURLWithPath: url.path)
        guard let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe)
        else {
            // 回一个空的 404 而不是报错：这样网页里 <img> 的 error 事件才会触发，显示「图片无法显示」。
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

/// 监听一个文件被改写。原子写入会换掉文件本身，所以收到改名或删除后要重新盯住同一路径。
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
            // 写入方先删后建的空档里文件不存在，稍等再试。
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
        // 重新盯上之前，新文件可能已经写完了，补查一次。
        if retries > 0 { schedule() }
    }

    /// 写入方常常分几次写完，攒 80 毫秒再通知一次。
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }
}
