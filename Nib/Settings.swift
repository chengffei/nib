import SwiftUI

/// 全部偏好设置。改任何一项都立即存盘并推给所有打开的编辑器。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum Theme: String, CaseIterable, Identifiable {
        case system, light, dark, paper
        var id: String { rawValue }
        var label: LocalizedStringKey {
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
    /// 打开文稿时进哪种模式："read"、"edit"、"source"。空文档总是进编辑。
    @Published var openMode: String { didSet { changed("openMode", openMode) } }
    /// 选中的 Typora 主题 .css 的路径；空串表示不用。
    @Published var typoraTheme: String {
        didSet {
            typoraCSS = typoraTheme.isEmpty ? nil : TyporaThemes.bundledCSS(path: typoraTheme)
            typoraDark = nil
            typoraBackground = nil
            changed("typoraTheme", typoraTheme)
        }
    }
    /// 展开好的主题 CSS，换主题时读一次盘，之后每个内核都用这份。
    private(set) var typoraCSS: String?
    /// 网页量出来的主题深浅；窗口外观跟着它走，不然深色主题配浅色标题栏。
    var typoraDark: Bool? {
        didSet { if oldValue != typoraDark { applyAppearance() } }
    }
    /// 网页量出来的主题底色。
    var typoraBackground: NSColor? {
        didSet { if oldValue != typoraBackground { Self.applyChrome() } }
    }

    /// 标题栏的颜色：和正文底色一致，不用系统默认的灰。
    var chromeColor: NSColor {
        if !typoraTheme.isEmpty, let typoraBackground { return typoraBackground }
        if theme == .paper { return NSColor(srgbRed: 0.973, green: 0.945, blue: 0.890, alpha: 1) }
        return .textBackgroundColor
    }

    /// 把标题栏颜色涂到文档窗口上（工具栏背景已设为透明，露出的就是窗口底色）。
    static func applyChrome(_ window: NSWindow? = nil) {
        let color = shared.chromeColor
        let targets = window.map { [$0] } ?? (NSApp?.windows ?? []).filter { $0.windowController?.document != nil }
        for target in targets {
            target.backgroundColor = color
            // 标题栏系统会画自己的底色（深色外观下是固定的灰），透明设置盖不住，所以在标题栏最底层垫一块同色的底。
            if let titlebar = target.standardWindowButton(.closeButton)?.superview {
                let backdrop = titlebar.subviews.first { $0.identifier == TabStripInstaller.backdropID } ?? {
                    let view = NSView(frame: titlebar.bounds)
                    view.identifier = TabStripInstaller.backdropID
                    view.autoresizingMask = [.width, .height]
                    view.wantsLayer = true
                    titlebar.addSubview(view, positioned: .below, relativeTo: nil)
                    return view
                }()
                backdrop.layer?.backgroundColor = color.cgColor
            }
        }
    }
    /// 记不记「打开最近使用」（也是 Dock 右键里的最近文稿）。关掉时连已有的一起清掉。
    @Published var rememberRecents: Bool {
        didSet {
            UserDefaults.standard.set(rememberRecents, forKey: "rememberRecents")
            Self.applyHistory()
        }
    }
    /// 重开 Nib 时要不要恢复上次的窗口（含没保存的「未命名」）。
    @Published var restoreWindows: Bool {
        didSet {
            UserDefaults.standard.set(restoreWindows, forKey: "restoreWindows")
            Self.applyHistory()
        }
    }
    /// "system"、"en" 或 "zh-Hans"。写进 AppleLanguages，系统在下次启动时按它选界面语言。
    @Published var language: String {
        didSet {
            let store = UserDefaults.standard
            store.set(language, forKey: "language")
            if language == Self.systemLanguage { store.removeObject(forKey: "AppleLanguages") }
            else { store.set([language], forKey: "AppleLanguages") }
        }
    }
    static let systemLanguage = "system"
    /// 这次启动实际用的界面语言。
    static let currentLanguage = Bundle.main.preferredLocalizations.first ?? "en"

    private init() {
        let store = UserDefaults.standard
        theme = Theme(rawValue: store.string(forKey: "theme") ?? "") ?? .system
        bodyFont = store.string(forKey: "bodyFont") ?? Self.systemFont
        monoFont = store.string(forKey: "monoFont") ?? Self.systemFont
        fontSize = store.object(forKey: "fontSize") as? Double ?? 16
        lineHeight = store.object(forKey: "lineHeight") as? Double ?? 1.6
        contentWidth = store.object(forKey: "contentWidth") as? Double ?? 44
        // 旧版本只存了「是否进编辑」，没有新值时从它换算。
        openMode = store.string(forKey: "openMode") ?? (store.bool(forKey: "openInEdit") ? "edit" : "read")
        var typora = store.string(forKey: "typoraTheme") ?? ""
        if !typora.isEmpty && !TyporaThemes.isInFolder(typora) { typora = "" }
        typoraTheme = typora
        typoraCSS = typora.isEmpty ? nil : TyporaThemes.bundledCSS(path: typora)
        rememberRecents = store.object(forKey: "rememberRecents") as? Bool ?? true
        restoreWindows = store.bool(forKey: "restoreWindows")
        language = store.string(forKey: "language") ?? Self.systemLanguage
    }

    func restoreDefaults() {
        theme = .system
        bodyFont = Self.systemFont
        monoFont = Self.systemFont
        fontSize = 16
        lineHeight = 1.6
        contentWidth = 44
        openMode = "read"
        typoraTheme = ""
        rememberRecents = true
        restoreWindows = false
    }

    /// 把两项历史记录设置落到系统层面。启动时、改设置时、每开一个文档窗口时都调一次。
    static func applyHistory(window: NSWindow? = nil, touchRecents: Bool = true) {
        let store = UserDefaults.standard
        let remember = store.object(forKey: "rememberRecents") as? Bool ?? true
        let restore = store.bool(forKey: "restoreWindows")
        // 窗口恢复：退出时留不留窗口状态，启动时读不读。两个都要设，只关前者系统在强退后仍会恢复。
        store.set(restore, forKey: "NSQuitAlwaysKeepsWindows")
        if restore { store.removeObject(forKey: "ApplePersistenceIgnoreState") }
        else { store.set(true, forKey: "ApplePersistenceIgnoreState") }
        for window in NSApp?.windows ?? [] where window.windowController?.document != nil { window.isRestorable = restore }
        window?.isRestorable = restore
        // 最近打开：文档控制器每开一篇都会记一笔，没有开关，只能事后清。
        // 系统在窗口摆出来之后才记这一笔，所以再晚一拍补清一次。
        if !remember && touchRecents {
            NSDocumentController.shared.clearRecentDocuments(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if !(UserDefaults.standard.object(forKey: "rememberRecents") as? Bool ?? true) {
                    NSDocumentController.shared.clearRecentDocuments(nil)
                }
            }
        }
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
        applyAppearance()
        Self.applyChrome()
        let payload = javascriptPayload
        for webView in EditorWebView.all.allObjects { webView.send("nib.applySettings(s)", ["s": payload]) }
    }

    /// 用 Typora 主题时窗口深浅跟主题；否则按 Nib 自己的主题设置。
    private func applyAppearance() {
        if !typoraTheme.isEmpty, let dark = typoraDark {
            NSApp?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            return
        }
        switch theme {
        case .system: NSApp?.appearance = nil
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        case .light, .paper: NSApp?.appearance = NSAppearance(named: .aqua)
        }
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
            "defaultMode": openMode,
            "lang": Self.currentLanguage,
            "typoraCSS": typoraCSS ?? NSNull(),
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

    /// 设置窗口每次打开时重新列一遍，刚放进文件夹的主题不用重开 Nib。
    @State private var themes = TyporaThemes.all()

    /// 主题只有一个选择：Nib 自带的四种和 Typora 主题放在同一个菜单里。选 Typora 主题时 Nib 主题不再起作用，分成两项反而让人困惑。
    private var themeChoice: Binding<String> {
        Binding(
            get: { settings.typoraTheme.isEmpty ? "nib:" + settings.theme.rawValue : settings.typoraTheme },
            set: { value in
                if value.hasPrefix("nib:") {
                    settings.typoraTheme = ""
                    settings.theme = AppSettings.Theme(rawValue: String(value.dropFirst(4))) ?? .system
                } else {
                    settings.typoraTheme = value
                }
            }
        )
    }

    // 只留会改的几项（11-16 Felix 觉得原来那页复杂无用）：行高、版心、代码字体用默认就好；
    // 界面语言交给系统设置里的「App 语言」；项目少到不需要「恢复默认」。
    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: themeChoice) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.label).tag("nib:" + $0.rawValue) }
                    if !themes.isEmpty {
                        Section("Typora") {
                            ForEach(themes) { Text(verbatim: $0.name).tag($0.id) }
                        }
                    }
                }
                Picker("Font", selection: $settings.bodyFont) {
                    Text("System Font").tag(AppSettings.systemFont)
                    Text("Serif").tag(AppSettings.serifFont)
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                slider("Size", $settings.fontSize, AppSettings.fontSizeRange, 1) { "\(Int($0)) pt" }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Typora themes supported.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Themes Folder…") { TyporaThemes.openFolder() }.buttonStyle(.link)
                }
                .font(.footnote)
            }
            Section {
                Picker("Open documents in", selection: $settings.openMode) {
                    Text("Reading mode").tag("read")
                    Text("Editing mode").tag("edit")
                    Text("Source mode").tag("source")
                }
                Toggle("Remember recent documents", isOn: $settings.rememberRecents)
                Toggle("Reopen windows when Nib starts", isOn: $settings.restoreWindows)
            }
        }
        .formStyle(.grouped)
        .onAppear { themes = TyporaThemes.all() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in themes = TyporaThemes.all() }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func slider(_ title: LocalizedStringKey, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ step: Double,
                        _ format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(width: 190)
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        }
    }
}
