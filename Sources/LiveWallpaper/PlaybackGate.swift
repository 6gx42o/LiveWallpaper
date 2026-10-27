import AppKit
import IOKit.ps
import notify
import os

/// Collects every "nobody can see the wallpaper" signal and pauses players accordingly.
/// Purely event-driven: no timers or polling.
@MainActor
final class PlaybackGate {
    enum Reason: String, CaseIterable {
        case user = "Paused"
        case lowPower = "Low Power Mode"
        case onBattery = "On battery"
        case lowBattery = "Battery low"
        case displaySleep = "Display asleep"
        case systemSleep = "System asleep"
        case locked = "Screen locked"
        case sessionInactive = "Another user is active"
    }

    var windows: [WallpaperWindow] = [] { didSet { checkCovered() } }
    var onChange: (() -> Void)?
    private(set) var reasons: Set<Reason> = []
    private var coveredDisplays: Set<CGDirectDisplayID> = []
    private var tokens: [NSObjectProtocol] = []
    private var powerTokens: [Int32] = []
    private let log = Logger(subsystem: "LiveWallpaper", category: "gate")

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        toggle(.displaySleep, ws, on: NSWorkspace.screensDidSleepNotification, off: NSWorkspace.screensDidWakeNotification)
        toggle(.systemSleep, ws, on: NSWorkspace.willSleepNotification, off: NSWorkspace.didWakeNotification)
        toggle(.sessionInactive, ws, on: NSWorkspace.sessionDidResignActiveNotification, off: NSWorkspace.sessionDidBecomeActiveNotification)
        toggle(.locked, DistributedNotificationCenter.default(),
               on: .init("com.apple.screenIsLocked"), off: .init("com.apple.screenIsUnlocked"))

        updateLowPower()
        observe(.default, .NSProcessInfoPowerStateDidChange) { [unowned self] _ in updateLowPower() }
        // Power source and battery level changes are pushed by macOS (no polling).
        for name in [kIOPSNotifyAnyPowerSource] {
            var token: Int32 = 0
            notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateBattery() }
            }
            powerTokens.append(token)
        }
        updateBattery()

        // Covered/full-screen detection. (NSWindow occlusion was tried: for desktop-level windows it gets
        // stuck on "hidden" after leaving a full-screen Space, so it can't be trusted to resume.)
        observe(ws, NSWorkspace.didActivateApplicationNotification) { [unowned self] _ in checkCovered() }
        observe(ws, NSWorkspace.activeSpaceDidChangeNotification) { [unowned self] _ in
            checkCovered()
            // The window list is still mid-animation when this fires; check once more after it settles.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.checkCovered() }
        }
    }

    /// User setting: keep playing while macOS is in Low Power Mode.
    var playsInLowPowerMode = UserDefaults.standard.bool(forKey: "playsInLowPowerMode") {
        didSet {
            UserDefaults.standard.set(playsInLowPowerMode, forKey: "playsInLowPowerMode")
            updateLowPower()
        }
    }

    /// User setting: pause while a full-screen app or maximized window hides the desktop (default on).
    var pausesWhenCovered = UserDefaults.standard.object(forKey: "pausesWhenCovered") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(pausesWhenCovered, forKey: "pausesWhenCovered")
            apply()
        }
    }

    var isPlaying: Bool { windows.contains { $0.player.rate != 0 } }

    var userPaused: Bool {
        get { reasons.contains(.user) }
        set { set(.user, newValue) }
    }

    var status: String {
        if let reason = Reason.allCases.first(where: reasons.contains) {
            return reason == .user ? "Paused" : "Paused — \(reason.rawValue)"
        }
        if !windows.contains(where: \.hasVideo) { return "No wallpaper selected" }
        if isPlaying { return "Playing" }
        return "Paused — wallpaper covered"
    }

    func apply() {
        for w in windows {
            let visible = !pausesWhenCovered || !coveredDisplays.contains(w.displayID)
            let shouldPlay = reasons.isEmpty && visible && w.hasVideo
            guard shouldPlay != (w.player.rate != 0) else { continue }
            shouldPlay ? w.player.play() : w.player.pause()
            log.notice("display \(w.displayID): \(shouldPlay ? "play" : "pause", privacy: .public) reasons=\(self.reasons.map(\.rawValue).joined(separator: ","), privacy: .public) visible=\(visible)")
        }
        onChange?()
    }

    private func updateLowPower() {
        set(.lowPower, ProcessInfo.processInfo.isLowPowerModeEnabled && !playsInLowPowerMode)
    }

    /// Applies the battery settings: pause on battery power, or below a battery percentage.
    func updateBattery() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let onBattery = (IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?) == kIOPMBatteryPowerKey
        var percent = 100
        for source in IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef] {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            percent = current * 100 / max
        }
        let threshold = Prefs.value("pauseBelowBattery", 0)
        let pauseOnBattery = Prefs.value("pauseOnBattery", false)
        let wasPaused = reasons.contains(.onBattery) || reasons.contains(.lowBattery)
        if onBattery && pauseOnBattery { reasons.insert(.onBattery) } else { reasons.remove(.onBattery) }
        if onBattery && threshold > 0 && percent < threshold { reasons.insert(.lowBattery) } else { reasons.remove(.lowBattery) }
        if wasPaused != (reasons.contains(.onBattery) || reasons.contains(.lowBattery)) { apply() }
    }

    private func set(_ reason: Reason, _ active: Bool) {
        if active { reasons.insert(reason) } else { reasons.remove(reason) }
        apply()
    }

    /// Marks displays where a normal-level window covers everything below the menu bar
    /// (a full-screen app or a maximized window), so the wallpaper can't be seen.
    /// Window bounds and layers are readable without Screen Recording permission.
    private func checkCovered() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        // Our own app window counts (it can be full screen); only the wallpaper windows are skipped.
        let wallpaperWindows = Set(windows.map(\.windowNumber))
        let covering = list.compactMap { info -> CGRect? in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  let number = info[kCGWindowNumber as String] as? Int, !wallpaperWindows.contains(number),
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
        // Window bounds use top-left-origin global coordinates; convert each screen's usable area to match.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        coveredDisplays = Set(windows.filter { w in
            guard let area = w.screen?.visibleFrame else { return false }
            let usable = CGRect(x: area.minX, y: primaryHeight - area.maxY, width: area.width, height: area.height)
            return covering.contains { $0.contains(usable) }
        }.map(\.displayID))
        apply()
    }

    private func toggle(_ reason: Reason, _ center: NotificationCenter, on: Notification.Name, off: Notification.Name) {
        observe(center, on) { [unowned self] _ in set(reason, true) }
        observe(center, off) { [unowned self] _ in set(reason, false) }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping @MainActor (Notification) -> Void) {
        tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { body(note) }
        })
    }
}
