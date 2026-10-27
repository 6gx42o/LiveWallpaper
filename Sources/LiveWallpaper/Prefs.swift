import AppKit
import Combine
import SwiftUI

/// A value that can live in UserDefaults: plist types, and String-backed enums.
protocol PrefValue {
    init?(pref: Any)
    var pref: Any { get }
}

extension Bool: PrefValue { init?(pref: Any) { guard let v = pref as? Bool else { return nil }; self = v }; var pref: Any { self } }
extension Int: PrefValue { init?(pref: Any) { guard let v = pref as? Int else { return nil }; self = v }; var pref: Any { self } }
extension Double: PrefValue { init?(pref: Any) { guard let v = pref as? Double else { return nil }; self = v }; var pref: Any { self } }
extension String: PrefValue { init?(pref: Any) { guard let v = pref as? String else { return nil }; self = v }; var pref: Any { self } }
extension PrefValue where Self: RawRepresentable, RawValue == String {
    init?(pref: Any) { guard let raw = pref as? String else { return nil }; self.init(rawValue: raw) }
    var pref: Any { rawValue }
}

/// Every customisation in Settings. Views observe it; `AppModel` applies changes to playback.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private func get<V: PrefValue>(_ key: String, _ fallback: V) -> V { Self.value(key, fallback) }

    private func set<V: PrefValue>(_ key: String, _ value: V) {
        objectWillChange.send()
        UserDefaults.standard.set(value.pref, forKey: key)
    }

    /// Reads a setting from any thread (UserDefaults is thread-safe).
    nonisolated static func value<V: PrefValue>(_ key: String, _ fallback: V) -> V {
        UserDefaults.standard.object(forKey: key).flatMap(V.init(pref:)) ?? fallback
    }

    // Playback
    var pauseOnBattery: Bool { get { get("pauseOnBattery", false) } set { set("pauseOnBattery", newValue) } }
    /// Pause below this battery percentage (0 = never).
    var pauseBelowBattery: Int { get { get("pauseBelowBattery", 0) } set { set("pauseBelowBattery", newValue) } }
    var displays: DisplayChoice { get { get("displays", DisplayChoice.all) } set { set("displays", newValue) } }
    /// Darkens the wallpaper (0…0.7) so icons and text stay readable.
    var dimming: Double { get { get("dimming", 0.0) } set { set("dimming", newValue) } }
    /// Switch to another wallpaper every this many minutes (0 = never).
    var rotationMinutes: Int { get { get("rotationMinutes", 0) } set { set("rotationMinutes", newValue) } }
    var rotationOrder: RotationOrder { get { get("rotationOrder", RotationOrder.inOrder) } set { set("rotationOrder", newValue) } }

    // Appearance
    var theme: Theme { get { get("theme", Theme.system) } set { set("theme", newValue) } }
    var accent: Accent { get { get("accent", Accent.system) } set { set("accent", newValue) } }
    var menuBarIcon: MenuBarIcon { get { get("menuBarIcon", MenuBarIcon.playRectangle) } set { set("menuBarIcon", newValue) } }
    var tileSize: TileSize { get { get("tileSize", TileSize.medium) } set { set("tileSize", newValue) } }
    var showPreviews: Bool { get { get("showPreviews", true) } set { set("showPreviews", newValue) } }
    var showShortcutHints: Bool { get { get("showShortcutHints", true) } set { set("showShortcutHints", newValue) } }
    var openWindowAtLaunch: Bool { get { get("openWindowAtLaunch", false) } set { set("openWindowAtLaunch", newValue) } }
    var confirmRemove: Bool { get { get("confirmRemove", true) } set { set("confirmRemove", newValue) } }

    // Importing
    var importLimit: ImportLimit { get { get("importLimit", ImportLimit.display) } set { set("importLimit", newValue) } }
    var youTubeQuality: YouTubeQuality { get { get("youTubeQuality", YouTubeQuality.auto) } set { set("youTubeQuality", newValue) } }
    var autoUpscale: Bool { get { get("autoUpscale", false) } set { set("autoUpscale", newValue) } }
    var showImportTips: Bool { get { get("showImportTips", true) } set { set("showImportTips", newValue) } }

    // Upscaling
    var upscaleTile: TileChoice { get { get("upscaleTile", TileChoice.auto) } set { set("upscaleTile", newValue) } }
    var upscaleFullPrecision: Bool { get { get("upscaleFullPrecision", false) } set { set("upscaleFullPrecision", newValue) } }
    /// HEVC quality of upscaled videos (0.6…1).
    var upscaleQuality: Double { get { get("upscaleQuality", 0.85) } set { set("upscaleQuality", newValue) } }
    /// Where the Upscale section saves results ("" = Movies › LiveWallpaper Upscaled).
    var upscaleFolder: String { get { get("upscaleFolder", "") } set { set("upscaleFolder", newValue) } }

    // Memory
    var memoryRefreshSeconds: Int { get { get("memoryRefreshSeconds", 2) } set { set("memoryRefreshSeconds", newValue) } }

    // Updates
    var autoCheckUpdates: Bool { get { get("autoCheckUpdates", true) } set { set("autoCheckUpdates", newValue) } }
    var autoInstallUpdates: Bool { get { get("autoInstallUpdates", true) } set { set("autoInstallUpdates", newValue) } }
    var updateIntervalHours: Int { get { get("updateIntervalHours", 24) } set { set("updateIntervalHours", newValue) } }

    /// Puts every setting back to its default (wallpapers, edits and models are kept).
    func resetAll() {
        let keys = ["pauseOnBattery", "pauseBelowBattery", "displays", "dimming", "rotationMinutes", "rotationOrder",
                    "theme", "accent", "menuBarIcon", "tileSize", "showPreviews", "showShortcutHints", "openWindowAtLaunch",
                    "confirmRemove", "importLimit", "youTubeQuality", "autoUpscale", "showImportTips", "upscaleTile",
                    "upscaleFullPrecision", "upscaleQuality", "upscaleFolder", "memoryRefreshSeconds", "autoCheckUpdates",
                    "autoInstallUpdates", "updateIntervalHours"]
        objectWillChange.send()
        keys.forEach(UserDefaults.standard.removeObject(forKey:))
    }
}

enum DisplayChoice: String, CaseIterable, PrefValue {
    case all, main
    var title: String { self == .all ? "All displays" : "Main display only" }
}

enum RotationOrder: String, CaseIterable, PrefValue {
    case inOrder, shuffle
    var title: String { self == .inOrder ? "In order" : "Shuffle" }
}

enum Theme: String, CaseIterable, PrefValue {
    case system, light, dark
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum Accent: String, CaseIterable, PrefValue {
    case system, blue, purple, pink, red, orange, yellow, green, graphite
    var title: String { self == .system ? "System" : rawValue.capitalized }
    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .graphite: .gray
        }
    }
}

enum MenuBarIcon: String, CaseIterable, PrefValue {
    case playRectangle = "play.rectangle", sparklesTV = "sparkles.tv", photo = "photo.on.rectangle",
         film = "film", display = "display", wand = "wand.and.stars"
    var title: String {
        switch self {
        case .playRectangle: "Play"
        case .sparklesTV: "Sparkly TV"
        case .photo: "Pictures"
        case .film: "Film"
        case .display: "Display"
        case .wand: "Magic wand"
        }
    }
}

enum TileSize: String, CaseIterable, PrefValue {
    case small, medium, large
    var title: String { rawValue.capitalized }
    var minWidth: CGFloat {
        switch self {
        case .small: 150
        case .medium: 200
        case .large: 280
        }
    }
}

enum ImportLimit: String, CaseIterable, PrefValue {
    case display, uhd, hd
    var title: String {
        switch self {
        case .display: "Your display (up to 4K or more)"
        case .uhd: "4K"
        case .hd: "1080p (smallest files, least battery)"
        }
    }
}

enum YouTubeQuality: String, CaseIterable, PrefValue {
    case auto, p1080, p1440, p2160
    var title: String {
        switch self {
        case .auto: "Match my display"
        case .p1080: "1080p"
        case .p1440: "1440p"
        case .p2160: "4K"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .auto: nil
        case .p1080: 1080
        case .p1440: 1440
        case .p2160: 2160
        }
    }
}

enum TileChoice: String, CaseIterable, PrefValue {
    case auto, small, large
    var title: String {
        switch self {
        case .auto: "Automatic"
        case .small: "Small (least memory)"
        case .large: "Large (fastest, most memory)"
        }
    }
}

/// Upscaling options, read off the main thread when an upscale starts.
struct UpscaleSettings {
    let tile: TileChoice
    let fullPrecision: Bool
    let quality: Double

    static func snapshot() -> UpscaleSettings {
        UpscaleSettings(tile: Prefs.value("upscaleTile", TileChoice.auto),
                        fullPrecision: Prefs.value("upscaleFullPrecision", false),
                        quality: Prefs.value("upscaleQuality", 0.85))
    }

    /// Automatic tiles grow with memory: 2× on 64 GB Macs, 4× on 128 GB and up (fewer seams, faster).
    private static var autoTileScale: Int { SystemInfo.totalMemory >= 128 << 30 ? 4 : SystemInfo.totalMemory >= 64 << 30 ? 2 : 1 }

    /// Tile side in source pixels. The big networks need smaller tiles for the same memory.
    func tile(for model: RealESRGAN.Model) -> Int {
        let base = model.architecture == .compact ? 512 : 256
        switch tile {
        case .auto: return base * Self.autoTileScale
        case .small: return base / 2
        case .large: return base * 2
        }
    }

    /// How the work size scales a model's working memory, relative to the measured default.
    var memoryFactor: Double {
        switch tile {
        case .auto: [1, 2.2, 2.2, 4.8][Self.autoTileScale - 1]
        case .small: 0.6
        case .large: 2.2
        }
    }

    /// How the settings scale time per frame: full precision is slower, as are small tiles (more overlap).
    var speedFactor: Double { (fullPrecision ? 1.6 : 1) * (tile == .small ? 1.15 : 1) }
}
