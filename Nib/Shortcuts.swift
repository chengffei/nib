import SwiftUI

/// Shortcuts for common commands can be changed in Settings and take effect immediately.
/// Covers only Nib's own menu commands: every time SwiftUI refreshes the menu it writes shortcuts back from its own model, so changes must go into the model (EditorCommands reads it here),
/// not edit menu items directly, nor rely on NSUserKeyEquivalents (changing it at runtime is unreliable, and restoring defaults only takes effect after a restart).
/// System commands such as Open, Save and Close are not here; to change them use "System Settings › Keyboard › App Shortcuts".
@MainActor
final class ShortcutStore: ObservableObject {
    static let shared = ShortcutStore()

    struct Action: Identifiable {
        /// English menu title, which is both the localization key and the key it is saved under.
        let title: String
        let defaultShortcut: Shortcut?
        var id: String { title }
    }

    struct Group: Identifiable {
        let title: LocalizedStringKey
        let id: String
        let actions: [Action]
    }

    static let groups: [Group] = [
        Group(title: "File", id: "file", actions: [
            Action(title: "New Tab", defaultShortcut: Shortcut("@t")),
            Action(title: "Reopen Closed Tab", defaultShortcut: Shortcut("$@t")),
            Action(title: "Quick Open…", defaultShortcut: Shortcut("$@o")),
            Action(title: "Search in Workspace…", defaultShortcut: Shortcut("$@f")),
        ]),
        Group(title: "Edit", id: "edit", actions: [
            Action(title: "Undo", defaultShortcut: Shortcut("@z")),
            Action(title: "Redo", defaultShortcut: Shortcut("$@z")),
            Action(title: "Find…", defaultShortcut: Shortcut("@f")),
        ]),
        Group(title: "View", id: "view", actions: [
            Action(title: "Read", defaultShortcut: nil),
            Action(title: "Editing", defaultShortcut: Shortcut("@e")),
            Action(title: "Source Mode", defaultShortcut: Shortcut("@/")),
            Action(title: "Show Outline", defaultShortcut: Shortcut("$@l")),
            Action(title: "Show Sidebar", defaultShortcut: Shortcut("^@s")),
            Action(title: "Focus Mode", defaultShortcut: Shortcut("\u{F70B}")),
            Action(title: "Typewriter Mode", defaultShortcut: Shortcut("\u{F70C}")),
            Action(title: "Zoom In", defaultShortcut: Shortcut("@=")),
            Action(title: "Zoom Out", defaultShortcut: Shortcut("@-")),
            Action(title: "Actual Size", defaultShortcut: Shortcut("@0")),
        ]),
        Group(title: "Window", id: "window", actions: [
            Action(title: "Show Previous Tab", defaultShortcut: Shortcut("$@[")),
            Action(title: "Show Next Tab", defaultShortcut: Shortcut("$@]")),
        ]),
    ]

    private static let storeKey = "shortcuts"
    private static let actions = Dictionary(uniqueKeysWithValues: groups.flatMap(\.actions).map { ($0.title, $0) })

    /// Commands that were changed: title → shortcut notation.
    @Published private var custom: [String: String]

    private init() {
        custom = UserDefaults.standard.dictionary(forKey: Self.storeKey) as? [String: String] ?? [:]
        Self.removeLegacyOverrides()
    }

    /// The shortcut used on the menu.
    func shortcut(_ title: String) -> KeyboardShortcut? {
        current(title)?.keyboardShortcut
    }

    func current(_ title: String) -> Shortcut? {
        if let value = custom[title] { return Shortcut(value) }
        return Self.actions[title]?.defaultShortcut
    }

    func isCustom(_ title: String) -> Bool { custom[title] != nil }

    /// nil means restore the default.
    func set(_ title: String, to shortcut: Shortcut?) {
        NibApp.log("shortcut \(title) = \(shortcut?.equivalent ?? "default")")
        custom[title] = shortcut == Self.actions[title]?.defaultShortcut ? nil : shortcut?.equivalent
        save()
    }

    func resetAll() {
        custom = [:]
        save()
    }

    /// Title of the command already using this shortcut (in the current UI language), or nil if none.
    func owner(of shortcut: Shortcut, except title: String) -> String? {
        if let other = Self.actions.keys.first(where: { $0 != title && current($0) == shortcut }) {
            return Self.localized(other)
        }
        // Then check commands on the menu bar that are not managed here (Open, Save, Close, ⌘1 to ⌘9, etc.).
        guard let menu = NSApp.mainMenu else { return nil }
        let managed = Set(Self.actions.keys.map(Self.localized))
        var found: String?
        Self.forEachItem(in: menu) { item in
            guard found == nil, !managed.contains(item.title), Shortcut(item: item) == shortcut else { return }
            found = item.title
        }
        return found
    }

    private func save() {
        if custom.isEmpty { UserDefaults.standard.removeObject(forKey: Self.storeKey) }
        else { UserDefaults.standard.set(custom, forKey: Self.storeKey) }
    }

    private static func localized(_ title: String) -> String {
        Bundle.main.localizedString(forKey: title, value: nil, table: nil)
    }

    private static func forEachItem(in menu: NSMenu, _ body: (NSMenuItem) -> Void) {
        for item in menu.items {
            if let submenu = item.submenu { forEachItem(in: submenu, body) } else { body(item) }
        }
    }

    /// An earlier version wrote changes into NSUserKeyEquivalents; clear those commands' entries so they do not override the settings here.
    private static func removeLegacyOverrides() {
        let key = "NSUserKeyEquivalents"
        guard var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return }
        let zh = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
        for title in actions.keys {
            all[title] = nil
            if let zhTitle = zh?.localizedString(forKey: title, value: nil, table: nil) { all[zhTitle] = nil }
        }
        if all.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(all, forKey: key) }
    }
}

/// A shortcut: key character plus modifiers. Saved in the same notation as NSUserKeyEquivalents: ^ ⌃, ~ ⌥, $ ⇧, @ ⌘, followed by the key.
struct Shortcut: Equatable {
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init?(_ equivalent: String) {
        var mods: NSEvent.ModifierFlags = []
        var rest = Substring(equivalent)
        while rest.count > 1, let first = rest.first, "^~$@".contains(first) {
            switch first {
            case "^": mods.insert(.control)
            case "~": mods.insert(.option)
            case "$": mods.insert(.shift)
            default: mods.insert(.command)
            }
            rest = rest.dropFirst()
        }
        guard !rest.isEmpty else { return nil }
        key = String(rest)
        modifiers = mods
    }

    init?(item: NSMenuItem) {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var mods = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        // In menus an uppercase letter means Shift is included.
        var key = item.keyEquivalent
        if key.lowercased() != key { mods.insert(.shift); key = key.lowercased() }
        self.key = key
        self.modifiers = mods
    }

    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let key = event.characters(byApplyingModifiers: [])?.lowercased(), !key.isEmpty else { return nil }
        let isFunctionKey = key.unicodeScalars.first.map { (0xF704...0xF70F).contains($0.value) } ?? false
        // Keys without ⌘ or ⌃ would steal ordinary typing in the body, so only function keys may do this.
        guard mods.contains(.command) || mods.contains(.control) || isFunctionKey else { return nil }
        self.key = key
        self.modifiers = mods
    }

    var equivalent: String {
        var text = ""
        if modifiers.contains(.control) { text += "^" }
        if modifiers.contains(.option) { text += "~" }
        if modifiers.contains(.shift) { text += "$" }
        if modifiers.contains(.command) { text += "@" }
        return text + key
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let character = key.first else { return nil }
        var mods: EventModifiers = []
        if modifiers.contains(.control) { mods.insert(.control) }
        if modifiers.contains(.option) { mods.insert(.option) }
        if modifiers.contains(.shift) { mods.insert(.shift) }
        if modifiers.contains(.command) { mods.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(character), modifiers: mods)
    }

    var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + Self.keyName(key)
    }

    private static func keyName(_ key: String) -> String {
        guard let scalar = key.unicodeScalars.first else { return key }
        switch scalar.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704...0xF70F: return "F\(scalar.value - 0xF703)"
        case 0x0D, 0x03: return "↩"
        case 0x09: return "⇥"
        case 0x20: return "Space"
        case 0x7F, 0x08: return "⌫"
        default: return key.uppercased()
        }
    }
}

/// The "Shortcuts" page in Settings.
struct ShortcutsSettingsView: View {
    @ObservedObject private var store = ShortcutStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(ShortcutStore.groups) { group in
                    Section(group.title) {
                        ForEach(group.actions) { action in
                            LabeledContent(LocalizedStringKey(action.title)) {
                                ShortcutRecorder(title: action.title, store: store)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ restores the default.")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { store.resetAll() }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 480, height: 560)
    }
}

private struct ShortcutRecorder: View {
    let title: String
    @ObservedObject var store: ShortcutStore
    @State private var recording = false
    @State private var conflict: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if let conflict {
                Text("Used by “\(conflict)”").font(.footnote).foregroundStyle(.red)
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? String(localized: "Type shortcut") : (store.current(title)?.display ?? "—"))
                    .monospacedDigit()
                    .frame(minWidth: 90)
                    .foregroundStyle(recording ? Color.accentColor : (store.isCustom(title) ? .primary : .secondary))
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        conflict = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        if event.keyCode == 53 && plain { stop(); return }          // Esc: abandon
        if (event.keyCode == 51 || event.keyCode == 117) && plain { // ⌫: restore default
            store.set(title, to: nil)
            stop()
            return
        }
        guard let shortcut = Shortcut(event: event) else { NSSound.beep(); return }
        if let owner = store.owner(of: shortcut, except: title) {
            NibApp.log("shortcut conflict \(owner)")
            conflict = owner
            stop()
            return
        }
        store.set(title, to: shortcut)
        stop()
    }
}
