// Without launching the app, load the bundled editor into an offscreen WKWebView: run assertions and take a screenshot.
// Usage: swift scripts/webcheck.swift <md file> <output.png> [dark] [JS to run]
import AppKit
import WebKit

let args = CommandLine.arguments
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let editor = root.appendingPathComponent("Nib/Editor")
let text = try! String(contentsOfFile: args[1], encoding: .utf8)
let output = URL(fileURLWithPath: args[2])
let dark = args.count > 3 && args[3] == "dark"
let script = args.count > 4 ? args[4] : "null"

final class Handler: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { messages.append(body) }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

let handler = Handler()
let config = WKWebViewConfiguration()
config.userContentController.add(handler, name: "nib")
let json = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
config.userContentController.addUserScript(
    WKUserScript(source: "window.__nibInitialText = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true))

let frame = NSRect(x: 0, y: 0, width: 900, height: 1250)
let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
window.backgroundColor = .textBackgroundColor
let webView = WKWebView(frame: frame, configuration: config)
webView.setValue(false, forKey: "drawsBackground")
window.contentView = webView
window.orderBack(nil)
let start = Date()
webView.loadFileURL(editor.appendingPathComponent("index.html"), allowingReadAccessTo: editor)

func after(_ seconds: Double, _ block: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(block) }
}

after(1.2) {
    webView.evaluateJavaScript("(function(){ \(script) })()") { result, error in
        if let error { print("JS error:", error) }
        if let result, !(result is NSNull) { print("JS result:", result) }
        after(0.5) {
            webView.evaluateJavaScript("nib.getText()") { value, _ in
                print("round-trip identical:", (value as? String) == text)
                print("messages received:", handler.messages.map { $0["type"] as? String ?? "?" })
                webView.takeSnapshot(with: nil) { image, _ in
                    if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try! png.write(to: output)
                        print("screenshot:", output.path)
                    }
                    exit(0)
                }
            }
        }
    }
}
_ = start
app.run()
