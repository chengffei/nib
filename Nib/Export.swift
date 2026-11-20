import AppKit
import UniformTypeIdentifiers
import WebKit

/// Print, Export as PDF and Export as HTML (requirement S5: send a document to someone).
/// The editor renders the whole document as a standalone HTML page (nib.exportHTML); this prints it from an offscreen
/// web view, or writes it out with local images inlined so the single file works anywhere.
@MainActor
enum Exporter {
    enum Kind { case print, pdf, html }

    /// target skips the save panel (used by the debug hook).
    static func run(_ kind: Kind, controller: EditorController, window: NSWindow?, target: URL? = nil) {
        guard let webView = controller.webView else { NSSound.beep(); return }
        let url = controller.fileURL
        let title = url?.deletingPathExtension().lastPathComponent ?? String(localized: "Untitled")
        webView.callAsyncJavaScript("return nib.exportHTML(title)", arguments: ["title": title], in: nil, in: .page) { result in
            MainActor.assumeIsolated {
                guard case .success(let value) = result, let html = value as? String else {
                    NibApp.log("export failed \(result)")
                    NSSound.beep()
                    return
                }
                switch kind {
                case .print: PagePrinter.print(html, to: nil, window: window)
                case .pdf where target != nil:
                    PagePrinter.print(html, to: target, window: window)
                case .html where target != nil:
                    try? inlineImages(html).write(to: target!, atomically: true, encoding: .utf8)
                case .pdf:
                    ask(window: window, name: title, type: .pdf, folder: url?.deletingLastPathComponent()) { target in
                        PagePrinter.print(html, to: target, window: window)
                    }
                case .html:
                    ask(window: window, name: title, type: .html, folder: url?.deletingLastPathComponent()) { target in
                        do { try inlineImages(html).write(to: target, atomically: true, encoding: .utf8) }
                        catch { presentError(error, window: window) }
                    }
                }
            }
        }
    }

    private static func ask(window: NSWindow?, name: String, type: UTType, folder: URL?, then: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.directoryURL = folder
        panel.canCreateDirectories = true
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let url = panel.url { then(url) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// Local images (and theme fonts) are nib-file URLs that only Nib can serve; embed them as data URLs.
    /// Files that cannot be read are left as they are.
    static func inlineImages(_ html: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: #"nib-file://local(/[^"')\s]+)"#) else { return html }
        var out = html
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).reversed()
        for match in matches {
            guard let whole = Range(match.range, in: out), let pathRange = Range(match.range(at: 1), in: out) else { continue }
            let path = String(out[pathRange]).removingPercentEncoding ?? String(out[pathRange])
            let file = URL(fileURLWithPath: path)
            guard let data = try? Data(contentsOf: file),
                  let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType else { continue }
            out.replaceSubrange(whole, with: "data:\(mime);base64,\(data.base64EncodedString())")
        }
        return out
    }

    static func presentError(_ error: Error, window: NSWindow?) {
        if let window { NSAlert(error: error).beginSheetModal(for: window) } else { NSApp.presentError(error) }
    }
}

/// Loads the HTML into an offscreen web view and runs a print operation: with the print panel for Print,
/// or saved straight to a PDF file. Keeps itself alive until printing finishes.
@MainActor
final class PagePrinter: NSObject, WKNavigationDelegate {
    private static var active: Set<PagePrinter> = []
    private let webView: WKWebView
    private let holder: NSWindow
    private let target: URL?
    private weak var window: NSWindow?

    static func print(_ html: String, to target: URL?, window: NSWindow?) {
        let printer = PagePrinter(target: target, window: window)
        active.insert(printer)
        printer.webView.loadHTMLString(html, baseURL: nil)
    }

    private init(target: URL?, window: NSWindow?) {
        self.target = target
        self.window = window
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: "nib-file")
        // A4 at 96 dpi; the print operation paginates the page to the paper size.
        let frame = NSRect(x: 0, y: 0, width: 794, height: 1123)
        webView = WKWebView(frame: frame, configuration: config)
        // WebKit only prints a web view that sits in a window.
        holder = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        holder.isReleasedWhenClosed = false
        holder.contentView = webView
        super.init()
        webView.navigationDelegate = self
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Give images a moment to decode before the page is laid out for printing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainActor.assumeIsolated { self.start() } }
    }

    private func start() {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 50
        info.bottomMargin = 50
        info.leftMargin = 45
        info.rightMargin = 45
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        if let target {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = target
        }
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = target == nil
        operation.showsProgressPanel = false
        operation.view?.frame = webView.bounds
        let host = target == nil ? (window ?? holder) : holder
        operation.runModal(for: host, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        NibApp.log("print finished success=\(success) target=\(target?.path ?? "-")")
        holder.close()
        Self.active.remove(self)
    }
}
