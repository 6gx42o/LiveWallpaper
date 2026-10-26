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
    /// The open "find videos on this Mac" scan, if any.
    private(set) var scanner: VideoScanner? { didSet { objectWillChange.send() } }
    /// Size of the downloaded Real-ESRGAN model; nil when it isn't downloaded.
    private(set) var realESRGANSize: Int64? = RealESRGAN.sizeOnDisk { didSet { objectWillChange.send() } }
    /// Size of Apple's (macOS-managed) model; nil when macOS hasn't downloaded it.
    private(set) var appleModelSize: Int64? = UpscalerModel.sizeOnDisk() { didSet { objectWillChange.send() } }
    /// Setting: which upscaler to use.
    var upscaler: Upscaler.Engine {
        get { Upscaler.Engine.current }
        set { Upscaler.Engine.current = newValue; objectWillChange.send() }
    }
    /// Setting: after upscaling with Real-ESRGAN, ask whether to keep or delete its model.
    var asksToDeleteModel = UserDefaults.standard.object(forKey: "asksToDeleteModel") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(asksToDeleteModel, forKey: "asksToDeleteModel")
            objectWillChange.send()
        }
    }
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
        library.onUpscaled = { [unowned self] original, upscaled, method in
            if current == original { current = upscaled }
            if lockScreen == original { setLockScreen(upscaled) }
            refreshModelSizes()
            if method == .realESRGAN, asksToDeleteModel, realESRGANSize != nil { askToKeepModel() }
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

    /// Which upscaler a video would get on this Mac with the current setting.
    func upscaleMethod(for url: URL) -> Upscaler.Method {
        guard let size = library.infos[url]?.size else { return .lanczos }
        return Upscaler.method(for: upscaler, video: size)
    }

    /// Upscales a copy to cover the display. Models download only now, and only after asking.
    func upscale(_ url: URL) {
        guard let size = library.infos[url]?.size else { return }
        var allowDownload = false
        if Upscaler.needsModelDownload(engine: upscaler, video: size) {
            NSApp.activate()
            let alert = NSAlert()
            switch upscaler {
            case .realESRGAN:
                alert.messageText = "Download the Real-ESRGAN model?"
                alert.informativeText = "Upscaling uses the open-source Real-ESRGAN model (\(UpscalerModel.sizeText(RealESRGAN.downloadSize)), the official file from github.com/xinntao/Real-ESRGAN). It's saved in LiveWallpaper's own folder and you can delete it any time in Settings."
            default:
                alert.messageText = "Download Apple's upscaling model?"
                alert.informativeText = "Apple Super Resolution needs a model that macOS downloads once, from Apple. macOS manages it — apps can't delete it later. Choose Real-ESRGAN in Settings for a model you can delete."
            }
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

    // MARK: Upscaling model

    func refreshModelSizes() {
        realESRGANSize = RealESRGAN.sizeOnDisk
        appleModelSize = UpscalerModel.sizeOnDisk()
    }

    /// After a Real-ESRGAN upscale: keep the model for next time, or delete it to free space.
    private func askToKeepModel() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Keep the upscaling model?"
        alert.informativeText = "Upscaling used the Real-ESRGAN model (\(realESRGANSize.map(UpscalerModel.sizeText) ?? "on disk")). Keep it to upscale again without downloading, or delete it to free up space — it downloads again only if you upscale later."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Delete Model")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always keep, don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { asksToDeleteModel = false }
        if response == .alertSecondButtonReturn { deleteRealESRGANModel(confirmed: true) }
    }

    /// Deletes the downloaded Real-ESRGAN model (asks to confirm unless already confirmed).
    func deleteRealESRGANModel(confirmed: Bool = false) {
        guard let size = RealESRGAN.sizeOnDisk else { refreshModelSizes(); return }
        if !confirmed {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete the Real-ESRGAN model?"
            alert.informativeText = "This frees \(UpscalerModel.sizeText(size)). Your upscaled videos stay. The model downloads again (after asking) only if you upscale later."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Another delete may have finished while the dialog was open.
        guard RealESRGAN.isDownloaded else { refreshModelSizes(); return }
        do {
            try RealESRGAN.delete()
            log.notice("deleted Real-ESRGAN model (\(size) bytes)")
            library.post(.init(kind: .info, title: "Deleted the upscaling model",
                               reason: "Freed \(UpscalerModel.sizeText(size)). It downloads again only if you upscale."))
        } catch {
            library.post(.init(title: "Couldn't delete the upscaling model", reason: "The model is still on your Mac.",
                               details: error.localizedDescription))
        }
        refreshModelSizes()
    }

    // MARK: Scanning

    /// Searches common folders for videos that could be wallpapers.
    func startScan() {
        openWindow?()
        let scanner = VideoScanner(existingNames: Set(library.videos.map { $0.deletingPathExtension().lastPathComponent }))
        self.scanner = scanner
        scanner.start()
    }

    func finishScan(adding urls: [URL]) {
        scanner?.cancel()
        scanner = nil
        if !urls.isEmpty { library.add(urls) }
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
