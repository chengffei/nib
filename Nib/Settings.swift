import SwiftUI

/// 全部偏好设置。改任何一项都立即存盘并推给所有打开的编辑器。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark, paper
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            case .paper: "Paper"
            }
        }
    }

    static let systemFont = "system"
    static let serifFont = "serif"
    static let fontSizeRange = 11.0...28.0

    @Published var theme: Theme { didSet { changed("theme", theme.rawValue) } }
    /// "system"、"serif"，或者一个已安装的字体家族名。
    @Published var bodyFont: String { didSet { changed("bodyFont", bodyFont) } }
    @Published var monoFont: String { didSet { changed("monoFont", monoFont) } }
    @Published var fontSize: Double { didSet { changed("fontSize", fontSize) } }
    @Published var lineHeight: Double { didSet { changed("lineHeight", lineHeight) } }
    /// 版心宽度，单位是字号的倍数。
    @Published var contentWidth: Double { didSet { changed("contentWidth", contentWidth) } }
    @Published var openInEdit: Bool { didSet { changed("openInEdit", openInEdit) } }

    private init() {
        let store = UserDefaults.standard
        theme = Theme(rawValue: store.string(forKey: "theme") ?? "") ?? .system
        bodyFont = store.string(forKey: "bodyFont") ?? Self.systemFont
        monoFont = store.string(forKey: "monoFont") ?? Self.systemFont
        fontSize = store.object(forKey: "fontSize") as? Double ?? 16
        lineHeight = store.object(forKey: "lineHeight") as? Double ?? 1.6
        contentWidth = store.object(forKey: "contentWidth") as? Double ?? 44
        openInEdit = store.bool(forKey: "openInEdit")
    }

    func restoreDefaults() {
        theme = .system
        bodyFont = Self.systemFont
        monoFont = Self.systemFont
        fontSize = 16
        lineHeight = 1.6
        contentWidth = 44
        openInEdit = false
    }

    func zoom(_ delta: Double) {
        let next = delta == 0 ? 16 : fontSize + delta
        fontSize = min(max(next, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
    }

    private func changed(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
        apply()
    }

    /// 窗口外观跟主题走，网页里的深浅色也随它；再把样式参数推给每个内核（含预热备用的那个）。
    func apply() {
        switch theme {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light, .paper: NSApp?.appearance = NSAppearance(named: .aqua)
        }
        let payload = javascriptPayload
        for webView in EditorWebView.all.allObjects { webView.send("nib.applySettings(s)", ["s": payload]) }
    }

    /// 编辑区后面那层底色。暖纸主题要自己给，其余用系统的文本底色。
    var backgroundColor: Color {
        theme == .paper ? Color(red: 0.973, green: 0.945, blue: 0.890) : Color(nsColor: .textBackgroundColor)
    }

    var javascriptPayload: [String: Any] {
        [
            "theme": theme.rawValue,
            "bodyFont": Self.cssFamily(bodyFont, fallback: "-apple-system, BlinkMacSystemFont, \"PingFang SC\", sans-serif",
                                       serif: "ui-serif, \"New York\", \"Songti SC\", serif") ?? NSNull(),
            "monoFont": Self.cssFamily(monoFont, fallback: "ui-monospace, \"SF Mono\", Menlo, monospace", serif: nil) ?? NSNull(),
            "fontSize": fontSize,
            "lineHeight": lineHeight,
            "width": contentWidth,
            "defaultMode": openInEdit ? "edit" : "read",
        ]
    }

    /// 自选字体后面接上默认字体栈：选的西文字体没有汉字时，汉字仍然有着落。
    private static func cssFamily(_ choice: String, fallback: String, serif: String?) -> String? {
        if choice == systemFont { return nil }
        if choice == serifFont, let serif { return serif }
        let name = choice.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
        return "\"\(name)\", \(fallback)"
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    private static let families = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    private static let monoFamilies = families.filter { family in
        guard let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first,
              let name = member.first as? String, let font = NSFont(name: name, size: 12) else { return false }
        return font.isFixedPitch
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Text") {
                Picker("Font", selection: $settings.bodyFont) {
                    Text("System").tag(AppSettings.systemFont)
                    Text("Serif").tag(AppSettings.serifFont)
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                slider("Size", $settings.fontSize, AppSettings.fontSizeRange, 1) { "\(Int($0)) pt" }
                slider("Line height", $settings.lineHeight, 1.3...2.0, 0.05) { String(format: "%.2f", $0) }
                slider("Line width", $settings.contentWidth, 32...72, 2) { "\(Int($0)) em" }
            }
            Section("Code") {
                Picker("Font", selection: $settings.monoFont) {
                    Text("System Monospaced").tag(AppSettings.systemFont)
                    Divider()
                    ForEach(Self.monoFamilies, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Documents") {
                Picker("Open documents in", selection: $settings.openInEdit) {
                    Text("Reading mode").tag(false)
                    Text("Editing mode").tag(true)
                }
            }
            Section {
                HStack {
                    Spacer()
                    Button("Restore Defaults") { settings.restoreDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                        _ format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(width: 190)
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        }
    }
}
