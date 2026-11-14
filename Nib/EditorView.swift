import SwiftUI
import UniformTypeIdentifiers
import WebKit

enum EditorMode: String, CaseIterable {
    case read, edit, source
}

/// 一个文档窗口对应一个：SwiftUI 工具栏和网页里的编辑器靠它互通。
@MainActor
final class EditorController: ObservableObject {
    @Published var mode: EditorMode = .read
    weak var webView: WKWebView?

    func setMode(_ newMode: EditorMode) {
        guard newMode != mode else { return }
        mode = newMode
        run("nib.setMode('\(newMode.rawValue)')")
    }

    func run(_ script: String) {
        NibApp.log("command \(script)")
        webView?.evaluateJavaScript(script)
    }
}

/// 编辑区：WKWebView 里跑 CodeMirror 6（Nib/Editor，由 Web/ 打包）。
/// 文档真相仍是 `text` 这一个字符串；网页只负责显示和编辑，改动原样传回来。
struct EditorView: NSViewRepresentable {
    @Binding var text: String
    /// 文档所在目录；相对路径的图片按它解析。未保存的新文档为 nil。
    let baseDirectory: String?
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        NibApp.log("makeNSView len=\(text.utf16.count)")
        let coordinator = context.coordinator
        let config = WKWebViewConfiguration()
        config.userContentController.add(coordinator, name: "nib")
        // 正文在页面脚本运行前就注入，编辑器一创建就有内容，不必等一次往返。
        let literal = (try? JSONEncoder().encode(text)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let debug = NibApp.debug ? "window.__nibDebug = true;" : ""
        let base = "window.__nibBaseDir = \(Self.jsLiteral(baseDirectory));"
        config.userContentController.addUserScript(
            WKUserScript(source: "window.__nibInitialText = \(literal);\(base)\(debug)", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: "nib-file")

        let webView = EditorWebView(frame: .zero, configuration: config)
        // 透明底：背景色由 SwiftUI 那层给，深色模式下不会先闪一下白。
        webView.setValue(false, forKey: "drawsBackground")
        controller.webView = webView
        coordinator.lastText = text
        coordinator.lastBase = baseDirectory

        if let directory = Bundle.main.resourceURL?.appendingPathComponent("Editor") {
            webView.loadFileURL(directory.appendingPathComponent("index.html"), allowingReadAccessTo: directory)
        }
        return webView
    }

    static func jsLiteral(_ string: String?) -> String {
        guard let string, let data = try? JSONEncoder().encode(string) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if baseDirectory != context.coordinator.lastBase {
            context.coordinator.lastBase = baseDirectory
            controller.run("nib.setBaseDir(\(Self.jsLiteral(baseDirectory)))")
        }
        // 只有外部改动（Versions 回滚、磁盘重载）才推给网页；自己打的字不回推，否则光标会被重置。
        guard text != context.coordinator.lastText else { return }
        context.coordinator.push(text)
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        var text: Binding<String>
        let controller: EditorController
        var lastText = ""
        var lastBase: String?
        private var ready = false

        init(text: Binding<String>, controller: EditorController) {
            self.text = text
            self.controller = controller
        }

        func push(_ newText: String) {
            NibApp.log("push external len=\(newText.utf16.count)")
            lastText = newText
            guard ready else { return }
            controller.webView?.callAsyncJavaScript("nib.setText(text)", arguments: ["text": newText], in: nil, in: .page)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "change":
                guard let newText = body["text"] as? String else { return }
                lastText = newText
                text.wrappedValue = newText
            case "mode":
                if let mode = (body["mode"] as? String).flatMap(EditorMode.init) { controller.mode = mode }
            case "ready":
                ready = true
                if let mode = (body["mode"] as? String).flatMap(EditorMode.init) { controller.mode = mode }
                // 页面加载期间文档被外部改过：补推一次。
                if lastText != text.wrappedValue { push(text.wrappedValue) }
                NibApp.log("ready \(Int(Date().timeIntervalSince(NibApp.launchedAt) * 1000)) ms")
            case "open":
                guard let string = body["url"] as? String, let url = URL(string: string),
                      ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
                else { return }
                NSWorkspace.shared.open(url)
            case "log":
                NibApp.log("js \(body["text"] as? String ?? "")")
            default:
                break
            }
        }
    }
}

final class EditorWebView: WKWebView {
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
