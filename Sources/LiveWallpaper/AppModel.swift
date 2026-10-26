import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

/// Owns playback, the library and settings; the panel UI observes it.
@MainActor
final class AppModel: ObservableObject {
    let gate = PlaybackGate()
    let library = Library()
    var openWindow: (() -> Void)?
    /// True while files are being dragged over a drop area (highlights it).
    var isDropTargeted = false { didSet { objectWillChange.send() } }
    /// The open video editor, if any.
    private(set) var editor: EditorModel? { didSet { objectWillChange.send() } }
    private var windows: [WallpaperWindow] = []
    private let log = Logger(subsystem: "LiveWallpaper", category: "app")

    /// Home screen wallpaper: the video playing behind the desktop icons.
    private(set) var current: URL? {
        didSet {
            UserDefaults.standard.set(current?.lastPathComponent, forKey: "wallpaper")
            loadCurrent()
        }
    }

    /// Lock screen wallpaper: a still from this video becomes the desktop picture macOS shows when locked.
    private(set) var lockScreen: URL? {
        didSet {
            UserDefaults.standard.set(lockScreen?.lastPathComponent, forKey: "lockWallpaper")
            objectWillChange.send()
        }
    }

    init() {
        gate.onChange = { [unowned self] in objectWillChange.send() }
        library.onChange = { [unowned self] in
            // New video info (size, duration) or a broken wallpaper changes what should be playing.
            loadCurrent()
            objectWillChange.send()
        }
        library.onConverted = { [unowned self] url in if current == nil { current = url } }
        library.onUpscaled = { [unowned self] original, upscaled in
            if current == original { current = upscaled }
            if lockScreen == original { setLockScreen(upscaled) }
        }

        let defaults = UserDefaults.standard
        current = library.videos.first { $0.lastPathComponent == defaults.string(forKey: "wallpaper") }
        lockScreen = library.videos.first { $0.lastPathComponent == defaults.string(forKey: "lockWallpaper") }
        buildWindows()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { buildWindows() }
        }
    }

    var isCurrentBroken: Bool { current.map { library.broken[$0] != nil } ?? false }

    var status: (text: String, color: Color) {
        if isCurrentBroken { return ("This wallpaper is broken", .red) }
        if current == nil { return ("No wallpaper selected", .secondary) }
        if gate.isPlaying { return ("Playing", .green) }
        return (gate.status, .orange)
    }

    func select(_ url: URL) {
        guard library.broken[url] == nil else { return }
        current = url
    }

    /// Sets (or with nil, removes and restores the user's own picture) the lock screen wallpaper.
    func setLockScreen(_ url: URL?) {
        guard let url else {
            lockScreen = nil
            LockScreen.restore()
            return
        }
        guard library.broken[url] == nil else { return }
        lockScreen = url
        applyLockScreen()
    }

    private func applyLockScreen() {
        guard let url = lockScreen else { return }
        let edits = library.edits(for: url)
        Task {
            do {
                try await LockScreen.apply(video: url, edits: edits)
            } catch {
                log.error("lock screen: \(error.localizedDescription, privacy: .public)")
                library.post(.init(title: "Couldn't set the lock screen wallpaper",
                                   reason: "macOS didn't accept the picture, so your lock screen is unchanged.",
                                   details: error.localizedDescription))
            }
        }
    }

    func remove(_ url: URL) {
        if url == current { current = nil }
        if url == lockScreen { setLockScreen(nil) }
        if editor?.url == url { closeEditor(save: false) }
        library.remove(url)
    }

    // MARK: Editing

    func edit(_ url: URL) {
        guard let info = library.infos[url] else { return }
        openWindow?()
        editor?.stop()
        editor = EditorModel(url: url, info: info, edits: library.edits(for: url))
    }

    func closeEditor(save: Bool) {
        guard let editor else { return }
        if save { saveEdits(editor.edits, for: editor.url) }
        editor.stop()
        self.editor = nil
    }

    /// Saves the editor's settings and uses that frame for the lock screen.
    func useEditorFrameForLockScreen() {
        guard let editor else { return }
        saveEdits(editor.edits, for: editor.url)
        setLockScreen(editor.url)
    }

    private func saveEdits(_ edits: Edits, for url: URL) {
        library.setEdits(edits, for: url) // reloads the home wallpaper via library.onChange
        if url == lockScreen { applyLockScreen() }
    }

    // MARK: Upscaling

    /// Which upscaler a video would get on this Mac.
    func upscaleMethod(for url: URL) -> Upscaler.Method {
        guard let size = library.infos[url]?.size else { return .lanczos }
        return Upscaler.superResolutionSupported(for: size) ? .superResolution : .lanczos
    }

    /// Upscales a copy to cover the display. Asks before macOS downloads Apple's model the first time.
    func upscale(_ url: URL) {
        guard let size = library.infos[url]?.size else { return }
        var allowDownload = false
        if Upscaler.needsModelDownload(for: size) {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Download Apple's upscaling model?"
            alert.informativeText = "The best upscaler uses Apple's on-device Super Resolution model. macOS downloads it once, from Apple. Without it, LiveWallpaper uses basic Lanczos scaling."
            alert.addButton(withTitle: "Download & Upscale")
            alert.addButton(withTitle: "Use Basic Upscaling")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: allowDownload = true
            case .alertSecondButtonReturn: allowDownload = false
            default: return
            }
        }
        library.upscale(url, allowModelDownload: allowDownload)
    }

    func addVideos() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie] + Library.ffmpegExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = "Choose videos to use as wallpapers. Any format is converted automatically."
        if panel.runModal() == .OK { library.add(panel.urls) }
    }

    /// Imports files dropped on a drop area; incompatible ones are reported by the library.
    func importDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in self.library.add([url]) }
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status != .notRegistered && SMAppService.mainApp.status != .notFound }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                log.error("launch at login: \(error.localizedDescription, privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    private func loadCurrent() {
        let url = isCurrentBroken ? nil : current
        let info = url.flatMap { library.infos[$0] }
        let edits = url.map(library.edits(for:)) ?? Edits()
        windows.forEach { $0.load(url, edits: edits, size: info?.size, duration: info?.duration ?? 0) }
        gate.apply()
    }

    private func buildWindows() {
        windows.forEach { $0.load(nil); $0.close() }
        windows = NSScreen.screens.map(WallpaperWindow.init)
        for w in windows {
            w.onFailure = { [unowned self] url in library.markBroken(url) }
        }
        gate.windows = windows
        loadCurrent()
    }
}
