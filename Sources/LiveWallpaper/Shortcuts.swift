import AppKit
import Carbon.HIToolbox

/// A `livewallpaper://` link: lets Shortcuts ("Open URLs"), Raycast, Alfred or Terminal (`open livewallpaper://next`)
/// control the app.
enum URLAction: Equatable {
    case next, pause, resume, togglePause
    /// Switch to the library wallpaper with this name (file name, with or without its extension).
    case set(String)
    case open(AppModel.Tab?)

    static let scheme = "livewallpaper"

    /// The links listed in Settings › Shortcuts.
    static let examples: [(link: String, does: String)] = [
        ("livewallpaper://next", "Next wallpaper"),
        ("livewallpaper://pause", "Pause"),
        ("livewallpaper://resume", "Resume"),
        ("livewallpaper://toggle", "Pause or resume"),
        ("livewallpaper://set?name=Aurora", "Switch to the wallpaper named Aurora"),
        ("livewallpaper://open?tab=settings", "Open the window (tab: wallpapers, upscale, memory or settings)"),
    ]

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = { (name: String) in parts.queryItems?.first { $0.name == name }?.value }
        switch (parts.host ?? "").lowercased() {
        case "next": self = .next
        case "pause": self = .pause
        case "resume", "play": self = .resume
        case "toggle": self = .togglePause
        case "set":
            guard let name = query("name"), !name.isEmpty, name.count <= 255 else { return nil }
            self = .set(name)
        case "open": self = .open(query("tab").flatMap { tab in AppModel.Tab.allCases.first { $0.rawValue.lowercased() == tab.lowercased() } })
        default: return nil
        }
    }

    /// The library video `name` refers to: an exact file name, else a name without extension (ignoring case).
    static func match(_ name: String, in videos: [URL]) -> URL? {
        videos.first { $0.lastPathComponent == name }
            ?? videos.first { $0.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }
}

/// System-wide keyboard shortcuts (Carbon hot keys: they work in any app and need no permission).
@MainActor
final class HotKeys: ObservableObject {
    enum Action: String, CaseIterable, Codable {
        case next, togglePause, openWindow
        var title: String {
            switch self {
            case .next: "Next wallpaper"
            case .togglePause: "Pause or resume"
            case .openWindow: "Open LiveWallpaper"
            }
        }
    }

    struct Combo: Codable, Equatable {
        var keyCode: UInt32
        /// Carbon modifier flags (cmdKey, optionKey…).
        var modifiers: UInt32
        /// How it's shown, e.g. "⌃⌥⌘N".
        var text: String
    }

    var onAction: ((Action) -> Void)?
    /// Shortcuts macOS refused (usually taken by another app), with the reason.
    @Published private(set) var failures: [Action: String] = [:]
    private var refs: [Action: EventHotKeyRef] = [:]

    private(set) var combos: [Action: Combo] {
        get { (UserDefaults.standard.data(forKey: "hotKeys").flatMap { try? JSONDecoder().decode([Action: Combo].self, from: $0) }) ?? [:] }
        set { objectWillChange.send(); UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "hotKeys") }
    }

    private static weak var shared: HotKeys?

    init() {
        Self.shared = self
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                if let shared = HotKeys.shared, Int(id.id) < Action.allCases.count { shared.onAction?(Action.allCases[Int(id.id)]) }
            }
            return noErr
        }, 1, &spec, nil, nil)
        registerAll()
    }

    func set(_ combo: Combo?, for action: Action) {
        combos[action] = combo
        registerAll()
    }

    func clearAll() {
        combos = [:]
        registerAll()
    }

    private func registerAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs = [:]
        var failed: [Action: String] = [:]
        for (index, action) in Action.allCases.enumerated() {
            guard let combo = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4C_57_50_52) /* "LWPR" */, id: UInt32(index))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs[action] = ref } else {
                failed[action] = status == eventHotKeyExistsErr ? "\(combo.text) is already used by another app." : "macOS didn't accept \(combo.text) (error \(status))."
            }
        }
        failures = failed
    }

    /// A shortcut from a key press, or nil when it has no ⌘, ⌃ or ⌥ (a plain key would fire while typing anywhere).
    static func combo(from event: NSEvent) -> Combo? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        var modifiers: UInt32 = 0, text = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); text += "⌘" }
        return Combo(keyCode: UInt32(event.keyCode), modifiers: modifiers, text: text + keyName(event))
    }

    private static func keyName(_ event: NSEvent) -> String {
        let named: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        return named[Int(event.keyCode)] ?? (event.characters(byApplyingModifiers: []) ?? "?").uppercased()
    }
}
