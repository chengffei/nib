import SwiftUI

/// All preferences. Changing any one saves immediately and pushes to every open editor.
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
    /// "system", "serif", or an installed font family name.
    @Published var bodyFont: String { didSet { changed("bodyFont", bodyFont) } }
    @Published var monoFont: String { didSet { changed("monoFont", monoFont) } }
    @Published var fontSize: Double { didSet { changed("fontSize", fontSize) } }
    @Published var lineHeight: Double { didSet { changed("lineHeight", lineHeight) } }
    /// Text column width, as a multiple of the font size.
    @Published var contentWidth: Double { didSet { changed("contentWidth", contentWidth) } }
    /// Which mode to open a document in: "read", "edit", "source". An empty document always opens in edit.
    @Published var openMode: String { didSet { changed("openMode", openMode) } }
    /// Path of the selected Typora theme .css; empty string means none.
    @Published var typoraTheme: String {
        didSet {
            typoraCSS = typoraTheme.isEmpty ? nil : TyporaThemes.bundledCSS(path: typoraTheme)
            typoraDark = nil
            typoraBackground = nil
            changed("typoraTheme", typoraTheme)
        }
    }
    /// The expanded theme CSS: read from disk once when the theme changes, then shared by every engine.
    private(set) var typoraCSS: String?
    /// Light or dark as measured by the web page; the window appearance follows it, otherwise a dark theme would get a light title bar.
    var typoraDark: Bool? {
        didSet { if oldValue != typoraDark { applyAppearance() } }
    }
    /// Theme background colour as measured by the web page.
    var typoraBackground: NSColor? {
        didSet { if oldValue != typoraBackground { Self.applyChrome() } }
    }

    /// Title bar colour: same as the body background, not the default system grey.
    var chromeColor: NSColor {
        if !typoraTheme.isEmpty, let typoraBackground { return typoraBackground }
        if theme == .paper { return NSColor(srgbRed: 0.973, green: 0.945, blue: 0.890, alpha: 1) }
        return .textBackgroundColor
    }

    /// Paint the title bar colour onto the document window (the toolbar background is already transparent, so what shows through is the window background).
    static func applyChrome(_ window: NSWindow? = nil) {
        let color = shared.chromeColor
        let targets = window.map { [$0] } ?? (NSApp?.windows ?? []).filter { $0.windowController?.document != nil }
        for target in targets {
            target.backgroundColor = color
            // The system draws its own background for the title bar (a fixed grey under the dark appearance) that transparency cannot cover, so lay a same-colour backing at the very bottom of the title bar.
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
    /// Whether to record Open Recent (also the recent documents in the Dock context menu). Turning it off also clears existing entries.
    @Published var rememberRecents: Bool {
        didSet {
            UserDefaults.standard.set(rememberRecents, forKey: "rememberRecents")
            Self.applyHistory()
        }
    }
    /// Which item the title-bar word-count button shows: "words", "chars", "lines", "minutes".
    @Published var wordCountUnit: String { didSet { UserDefaults.standard.set(wordCountUnit, forKey: "wordCountUnit") } }
    /// Focus mode (F8): dim everything outside the block holding the cursor. Typewriter mode (F9): keep the cursor line in the middle of the screen. Both are pushed to the web page.
    /// Paragraph spacing: height of the blank space between blocks, as a multiple of line height (default 0.75, tighter like Bear).
    @Published var paragraphSpacing: Double { didSet { changed("paragraphSpacing", paragraphSpacing) } }
    @Published var focusMode: Bool { didSet { changed("focusMode", focusMode) } }
    @Published var typewriterMode: Bool { didSet { changed("typewriterMode", typewriterMode) } }
    /// File tree sidebar: whether it is open, and its width.
    @Published var showSidebar: Bool { didSet { UserDefaults.standard.set(showSidebar, forKey: "showSidebar") } }
    @Published var sidebarWidth: Double { didSet { UserDefaults.standard.set(sidebarWidth, forKey: "sidebarWidth") } }
    /// Workspace: folders pinned in the sidebar (like VS Code multi-root workspaces), shared by all windows. Empty shows an empty state in the sidebar.
    @Published var workspaceFolders: [String] { didSet { UserDefaults.standard.set(workspaceFolders, forKey: "workspaceFolders") } }
    /// Tools on the right of the title bar (word count, mode switch) always visible; when off, they appear only when the mouse moves onto the title bar.
    @Published var alwaysShowTools: Bool { didSet { UserDefaults.standard.set(alwaysShowTools, forKey: "alwaysShowTools") } }
    /// Reading speed in words per minute (one Chinese character counts as one word), used to compute reading time.
    /// Keep running (out of the Dock) after the last window closes, so the next document opens in about 0.15 s instead of 0.8 s.
    @Published var keepRunning: Bool { didSet { UserDefaults.standard.set(keepRunning, forKey: "keepRunning") } }
    @Published var readingSpeed: Int { didSet { UserDefaults.standard.set(readingSpeed, forKey: "readingSpeed") } }
    static let readingSpeedRange = 100...1000
    /// Whether to restore the windows of the last session (including unsaved "Untitled") when Nib reopens.
    @Published var restoreWindows: Bool {
        didSet {
            UserDefaults.standard.set(restoreWindows, forKey: "restoreWindows")
            Self.applyHistory()
        }
    }
    /// "system" or a language code from languages. Written to AppleLanguages (the same setting as "App Language" in System Settings); the system picks the UI language from it at the next launch.
    @Published var language: String {
        didSet {
            let store = UserDefaults.standard
            store.set(language, forKey: "language")
            if language == Self.systemLanguage { store.removeObject(forKey: "AppleLanguages") }
            else { store.set([language], forKey: "AppleLanguages") }
        }
    }
    static let systemLanguage = "system"
    /// UI languages supported, one-to-one with Nib/*.lproj.
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"), ("ja", "日本語"),
        ("ko", "한국어"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"),
    ]
    /// The UI language actually used for this launch.
    static let currentLanguage = Bundle.main.preferredLocalizations.first ?? "en"

    private init() {
        let store = UserDefaults.standard
        theme = Theme(rawValue: store.string(forKey: "theme") ?? "") ?? .system
        bodyFont = store.string(forKey: "bodyFont") ?? Self.systemFont
        monoFont = store.string(forKey: "monoFont") ?? Self.systemFont
        fontSize = store.object(forKey: "fontSize") as? Double ?? 16
        lineHeight = store.object(forKey: "lineHeight") as? Double ?? 1.75
        contentWidth = store.object(forKey: "contentWidth") as? Double ?? 44
        // Older versions stored only "whether to enter edit"; with no new value, derive it from that.
        openMode = store.string(forKey: "openMode") ?? (store.bool(forKey: "openInEdit") ? "edit" : "read")
        var typora = store.string(forKey: "typoraTheme") ?? ""
        if !typora.isEmpty && !TyporaThemes.isInFolder(typora) { typora = "" }
        typoraTheme = typora
        typoraCSS = typora.isEmpty ? nil : TyporaThemes.bundledCSS(path: typora)
        rememberRecents = store.object(forKey: "rememberRecents") as? Bool ?? true
        restoreWindows = store.bool(forKey: "restoreWindows")
        language = store.string(forKey: "language") ?? Self.systemLanguage
        alwaysShowTools = store.bool(forKey: "alwaysShowTools")
        paragraphSpacing = store.object(forKey: "paragraphSpacing") as? Double ?? 0.75
        focusMode = store.bool(forKey: "focusMode")
        typewriterMode = store.bool(forKey: "typewriterMode")
        showSidebar = store.bool(forKey: "showSidebar")
        sidebarWidth = store.object(forKey: "sidebarWidth") as? Double ?? 240
        // Previously only a single root folder (sidebarRoot) was possible; if present, merge it into the workspace.
        let legacyRoot = store.string(forKey: "sidebarRoot") ?? ""
        workspaceFolders = store.stringArray(forKey: "workspaceFolders") ?? (legacyRoot.isEmpty ? [] : [legacyRoot])
        wordCountUnit = store.string(forKey: "wordCountUnit") ?? "words"
        readingSpeed = store.object(forKey: "readingSpeed") as? Int ?? 300
        keepRunning = store.object(forKey: "keepRunning") == nil ? true : store.bool(forKey: "keepRunning")
        // Re-read the theme when returning to Nib: changing the theme or user.css does not require selecting it again
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppSettings.shared.reloadThemeCSS() }
        }
    }

    func reloadThemeCSS() {
        guard !typoraTheme.isEmpty else { return }
        let css = TyporaThemes.bundledCSS(path: typoraTheme)
        guard css != typoraCSS else { return }
        typoraCSS = css
        apply()
    }

    func restoreDefaults() {
        theme = .system
        bodyFont = Self.systemFont
        monoFont = Self.systemFont
        fontSize = 16
        lineHeight = 1.75
        contentWidth = 44
        openMode = "read"
        typoraTheme = ""
        rememberRecents = true
        restoreWindows = false
    }

    /// Apply the two history settings at the system level. Called at launch, when settings change, and each time a document window opens.
    static func applyHistory(window: NSWindow? = nil, touchRecents: Bool = true) {
        let store = UserDefaults.standard
        let remember = store.object(forKey: "rememberRecents") as? Bool ?? true
        let restore = store.bool(forKey: "restoreWindows")
        // Window restoration: whether window state is kept at quit and whether it is read at launch. Both must be set; turning off only the former still lets the system restore after a force quit.
        store.set(restore, forKey: "NSQuitAlwaysKeepsWindows")
        if restore { store.removeObject(forKey: "ApplePersistenceIgnoreState") }
        else { store.set(true, forKey: "ApplePersistenceIgnoreState") }
        for window in NSApp?.windows ?? [] where window.windowController?.document != nil { window.isRestorable = restore }
        window?.isRestorable = restore
        // Recent documents: the document controller records an entry for every document opened, with no switch, so it can only be cleared afterwards.
        // The system records it only after the window is shown, so clear once more one tick later.
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

    /// The window appearance follows the theme, and so does light/dark in the web page; then push the style parameters to every engine (including the pre-warmed spare).
    func apply() {
        applyAppearance()
        Self.applyChrome()
        let payload = javascriptPayload
        for webView in EditorWebView.all.allObjects { webView.send("nib.applySettings(s)", ["s": payload]) }
    }

    /// With a Typora theme, window light/dark follows the theme; otherwise it follows Nib's own theme setting.
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

    /// Background colour behind the editing area. The warm paper theme must supply its own; the others use the system text background.
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
            "paragraphSpacing": paragraphSpacing,
            "focusMode": focusMode,
            "typewriterMode": typewriterMode,
        ]
    }

    /// Append the default font stack after a custom font: if the chosen Latin font has no Chinese glyphs, Chinese characters still have a fallback.
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

    /// List again each time the Settings window opens, so a theme just dropped into the folder needs no Nib restart.
    @State private var themes = TyporaThemes.all()

    /// There is a single theme choice: Nib's four built-in themes and Typora themes share one menu. When a Typora theme is selected Nib's theme no longer applies; splitting them into two items would only confuse.
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

    // Keep only the items that get changed (the full page was too busy): line height, text width and code font are fine at defaults;
    // UI language is left to "App Language" in System Settings; with so few items there is no need for "Restore Defaults".
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            ShortcutsSettingsView().tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
    }

    private var general: some View {
        Form {
            Section {
                Picker("Theme", selection: themeChoice) {
                    ForEach(AppSettings.Theme.allCases) { Text($0.label).tag("nib:" + $0.rawValue) }
                    if !themes.isEmpty {
                        Section("Custom") {
                            ForEach(themes) { Text(verbatim: $0.name).tag($0.id) }
                        }
                    }
                }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Add CSS themes to the themes folder. Typora themes work too.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Writing Themes") { TyporaThemes.openGuide() }.buttonStyle(.link)
                    Button("Themes Folder…") { TyporaThemes.openFolder() }.buttonStyle(.link)
                }
                .font(.footnote)
            }
            Section {
                Picker("Font", selection: $settings.bodyFont) {
                    Text("System Font").tag(AppSettings.systemFont)
                    Text("Serif").tag(AppSettings.serifFont)
                    Divider()
                    ForEach(Self.families, id: \.self) { Text($0).tag($0) }
                }
                slider("Size", $settings.fontSize, AppSettings.fontSizeRange, 1) { "\(Int($0)) pt" }
                slider("Paragraph spacing", $settings.paragraphSpacing, 0.25...1.5, 0.25) { String(format: "%.2g×", $0) }
            }
            Section {
                Picker("Open documents in", selection: $settings.openMode) {
                    Text("Reading mode").tag("read")
                    Text("Editing mode").tag("edit")
                    Text("Source mode").tag("source")
                }
                Toggle("Remember recent documents", isOn: $settings.rememberRecents)
                Toggle("Reopen windows when Nib starts", isOn: $settings.restoreWindows)
                Toggle("Always show word count and modes in title bar", isOn: $settings.alwaysShowTools)
            }
            Section {
                Toggle("Keep running after all windows close", isOn: $settings.keepRunning)
            } footer: {
                Text("Documents then open in about 0.15 seconds instead of 0.8. Nib stays out of the Dock while no window is open and uses about 100 MB of memory.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Stepper(value: $settings.readingSpeed, in: AppSettings.readingSpeedRange, step: 50) {
                    LabeledContent("Reading speed") { Text("\(settings.readingSpeed) words/min").monospacedDigit() }
                }
            } footer: {
                Text("Used for the reading time in word count. One Chinese character counts as one word.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Language", selection: $settings.language) {
                    Text("Follow System").tag(AppSettings.systemLanguage)
                    Divider()
                    // Each language uses its own name, so it can still be recognised if switched by mistake
                    ForEach(AppSettings.languages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
            } footer: {
                Text("Takes effect after you reopen Nib.").font(.footnote).foregroundStyle(.secondary)
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
