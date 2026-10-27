import AVFoundation
import AppKit
import Combine
import ImageIO
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import os

/// Owns playback, the library and settings; the panel UI observes it.
@MainActor
final class AppModel: ObservableObject {
    let gate = PlaybackGate()
    let library = Library()
    let prefs = Prefs.shared
    let updater = Updater()
    /// Called after settings change (the menu bar icon follows the setting).
    var onPrefsChanged: (() -> Void)?
    private var prefsObserver: AnyCancellable?
    private var appliedDisplays: DisplayChoice?
    private var appliedRotation: Int?
    private var rotationTimer: Timer?
    var openWindow: (() -> Void)?
    /// True while files are being dragged over a drop area (highlights it).
    var isDropTargeted = false { didSet { objectWillChange.send() } }
    /// The open video editor, if any.
    private(set) var editor: EditorModel? { didSet { objectWillChange.send() } }
    /// The open "find videos on this Mac" scan, if any.
    private(set) var scanner: VideoScanner? { didSet { objectWillChange.send() } }

    /// Window sections (the sidebar).
    enum Tab: String, CaseIterable {
        case wallpapers = "Wallpapers", upscale = "Upscale", memory = "Memory", settings = "Settings"
        var symbol: String {
            switch self {
            case .wallpapers: "photo.on.rectangle"
            case .upscale: "sparkles"
            case .memory: "memorychip"
            case .settings: "gearshape"
            }
        }
    }
    var tab: Tab = .wallpapers {
        didSet {
            tabMovedForward = (Tab.allCases.firstIndex(of: tab) ?? 0) >= (Tab.allCases.firstIndex(of: oldValue) ?? 0)
            objectWillChange.send()
        }
    }
    /// Whether the last tab change moved right (pages slide in from that side).
    private(set) var tabMovedForward = true
    let memory = MemoryCleaner()
    let studio = UpscaleStudio()
    /// A model being downloaded from Settings / the model list.
    private(set) var modelDownload: (engine: Upscaler.Engine, progress: TransferProgress)? { didSet { objectWillChange.send() } }
    private var modelDownloadTask: Task<Void, Never>?

    /// Setting: resolution wallpapers are judged and upscaled against (defaults to native).
    var resolution: ResolutionChoice {
        get { ResolutionChoice.current }
        set { ResolutionChoice.current = newValue; objectWillChange.send() }
    }
    /// Size on disk of each downloaded model (Real-ESRGAN sizes and Apple's macOS-managed one).
    private(set) var modelSizes: [Upscaler.Engine: Int64] = AppModel.measureModels() { didSet { objectWillChange.send() } }
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
        memory.onCacheCleared = { [unowned self] in
            // Reload the wallpaper so it isn't left blank after macOS drops its cached frames.
            windows.forEach { $0.load(nil) }
            loadCurrent()
        }
        studio.onFinished = { [unowned self] method in modelUsed(method) }
        library.onChange = { [unowned self] in
            // New video info (size, duration) or a broken wallpaper changes what should be playing.
            loadCurrent()
            objectWillChange.send()
        }
        library.onConverted = { [unowned self] url in if current == nil { current = url } }
        library.onUpscaled = { [unowned self] original, upscaled, method in
            if current == original { current = upscaled }
            if lockScreen == original { setLockScreen(upscaled) }
            modelUsed(method)
        }

        let defaults = UserDefaults.standard
        current = library.videos.first { $0.lastPathComponent == defaults.string(forKey: "wallpaper") }
        lockScreen = library.videos.first { $0.lastPathComponent == defaults.string(forKey: "lockWallpaper") }
        if let from = defaults.string(forKey: "updatedFrom") {
            defaults.removeObject(forKey: "updatedFrom")
            library.post(.init(kind: .info, title: "Updated to LiveWallpaper \(Updater.currentVersion)",
                               reason: "Updated from version \(from). Your settings, wallpapers and models were kept."))
        }
        appliedDisplays = prefs.displays
        buildWindows()
        prefsObserver = prefs.objectWillChange.receive(on: RunLoop.main).sink { [unowned self] _ in applyPrefs() }
        updater.onChange = { [unowned self] in objectWillChange.send() }
        updater.canInstallNow = { [unowned self] in
            library.converting == nil && !studio.isBusy && editor == nil && scanner == nil && modelDownload == nil
        }
        applyPrefs()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [unowned self] _ in
            MainActor.assumeIsolated { buildWindows() }
        }
    }

    /// The main display's wallpaper player, shown live in the window (no second decoder).
    var previewPlayer: AVPlayer? {
        windows.first { $0.screen == NSScreen.main }?.player ?? windows.first?.player
    }

    /// What macOS shows on the lock screen: the main display's desktop picture, scaled down.
    var lockPreview: NSImage? = AppModel.loadLockPreview() { didSet { objectWillChange.send() } }

    private static func loadLockPreview() -> NSImage? {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 900,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
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
            lockPreview = Self.loadLockPreview()
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
                lockPreview = Self.loadLockPreview()
            } catch {
                log.error("lock screen: \(error.localizedDescription, privacy: .public)")
                library.post(.init(title: "Couldn't set the lock screen wallpaper",
                                   reason: "macOS didn't accept the picture, so your lock screen is unchanged.",
                                   details: error.localizedDescription))
            }
        }
    }

    func remove(_ url: URL) {
        if prefs.confirmRemove {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "Move “\(url.deletingPathExtension().lastPathComponent)” to the Trash?"
            alert.informativeText = "It's removed from your library. You can put it back from the Trash."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't ask again"
            let response = alert.runModal()
            guard response == .alertFirstButtonReturn else { return }
            if alert.suppressionButton?.state == .on { prefs.confirmRemove = false }
        }
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
        return Upscaler.method(for: ModelAdvisor.engine(for: size), video: size)
    }

    /// Upscales a copy to cover the display. Models download only now, and only after asking.
    func upscale(_ url: URL) {
        guard let size = library.infos[url]?.size else { return }
        let engine = ModelAdvisor.engine(for: size)
        var allowDownload = false
        if Upscaler.needsModelDownload(engine: engine, video: size) {
            guard let answer = ModelConsent.ask(for: engine) else { return }
            allowDownload = answer
        }
        library.upscale(url, allowModelDownload: allowDownload)
    }

    // MARK: Upscaling model

    /// Downloads a model now (the Download button), showing size, time left and a progress bar.
    func downloadModel(_ engine: Upscaler.Engine) {
        guard modelDownload == nil, engine != .basic else { return }
        modelDownload = (engine, TransferProgress(title: "Downloading \(engine.title)", totalBytes: ModelAdvisor.downloadSize(engine)))
        modelDownloadTask = Task {
            do {
                if let model = engine.esrgan {
                    try await RealESRGAN.download(model) { received, total in
                        Task { @MainActor in self.updateModelDownload(Double(received) / Double(total), received, total) }
                    }
                } else {
                    guard #available(macOS 26.0, *) else { throw RealESRGAN.failure("Apple Super Resolution needs macOS 26 or later.") }
                    try await Upscaler.downloadAppleModel { fraction, received, total in self.updateModelDownload(fraction, received, total) }
                }
                library.post(.init(kind: .info, title: "Downloaded \(engine.title)", reason: "It's ready — upscaling with it won't need to download anything."))
            } catch {
                library.post(.init(title: "Couldn't download \(engine.title)",
                                   reason: Task.isCancelled ? "Cancelled." : "Check your internet connection and try again.",
                                   details: error.localizedDescription))
            }
            modelDownload = nil
            refreshModelSizes()
        }
    }

    private func updateModelDownload(_ fraction: Double, _ received: Int64, _ total: Int64) {
        guard let current = modelDownload else { return }
        modelDownload = (current.engine, current.progress.updated(fraction: fraction, received: received, total: total))
    }

    func cancelModelDownload() { modelDownloadTask?.cancel() }

    private static func measureModels() -> [Upscaler.Engine: Int64] {
        var sizes: [Upscaler.Engine: Int64] = [:]
        for engine in Upscaler.Engine.allCases {
            sizes[engine] = engine.esrgan.map(\.sizeOnDisk) ?? (engine == .appleSuperResolution ? UpscalerModel.sizeOnDisk() : nil)
        }
        return sizes
    }

    func refreshModelSizes() { modelSizes = Self.measureModels() }

    /// After an upscale: refresh sizes, and offer to delete a Real-ESRGAN model to free space.
    private func modelUsed(_ method: Upscaler.Method) {
        refreshModelSizes()
        if case .realESRGAN(let engine) = method, asksToDeleteModel, modelSizes[engine] != nil { askToKeepModel(engine) }
    }

    private func askToKeepModel(_ engine: Upscaler.Engine) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Keep the \(engine.title) model?"
        alert.informativeText = "Upscaling used it (\(modelSizes[engine].map(UpscalerModel.sizeText) ?? "on disk")). Keep it to upscale again without downloading, or delete it to free up space — it downloads again only if you upscale with it later."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Delete Model")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Always keep, don't ask again"
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on { asksToDeleteModel = false }
        if response == .alertSecondButtonReturn { deleteModel(engine, confirmed: true) }
    }

    /// Deletes a downloaded Real-ESRGAN model (asks to confirm unless already confirmed).
    func deleteModel(_ engine: Upscaler.Engine, confirmed: Bool = false) {
        guard let model = engine.esrgan, let size = model.sizeOnDisk else { refreshModelSizes(); return }
        if !confirmed {
            NSApp.activate()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Delete the \(engine.title) model?"
            alert.informativeText = "This frees \(UpscalerModel.sizeText(size)). Your upscaled videos stay. The model downloads again (after asking) only if you upscale with it later."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        // Another delete may have finished while the dialog was open.
        guard model.isDownloaded else { refreshModelSizes(); return }
        do {
            try RealESRGAN.delete(model)
            log.notice("deleted \(model.file, privacy: .public) (\(size) bytes)")
            library.post(.init(kind: .info, title: "Deleted \(engine.title)",
                               reason: "Freed \(UpscalerModel.sizeText(size)). It downloads again only if you upscale with it."))
        } catch {
            library.post(.init(title: "Couldn't delete \(engine.title)", reason: "The model is still on your Mac.",
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

    /// Turns whatever was dropped into local files: Finder files, files a browser promises to write
    /// (how Safari/Chrome hand over a dragged image or GIF), web links, or raw image data.
    /// `files` gets local files; `links` gets web links (only used for wallpapers).
    func readDrop(_ pasteboard: NSPasteboard, files: @escaping @MainActor ([URL]) -> Void, links: (([URL]) -> Void)?) {
        let types = pasteboard.types?.map(\.rawValue) ?? []
        log.notice("drop types: \(types.joined(separator: ", "), privacy: .public)")
        let folder = WebImport.tempDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        if let local = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !local.isEmpty {
            return files(local)
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver], !promises.isEmpty {
            for promise in promises {
                promise.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: .main) { url, error in
                    MainActor.assumeIsolated {
                        if let error {
                            self.library.post(.init(title: "Couldn't get the dropped file", reason: "The app it came from didn't finish writing it.", details: error.localizedDescription))
                        } else { files([url]) }
                    }
                }
            }
            return
        }
        if let links, let web = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           case let webLinks = web.filter({ ["http", "https"].contains($0.scheme?.lowercased()) }), !webLinks.isEmpty {
            return links(webLinks)
        }
        for (type, ext) in [("com.compuserve.gif", "gif"), ("org.webmproject.webp", "webp"), ("public.png", "png"), ("public.jpeg", "jpg"), ("public.tiff", "tiff")] {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type)) {
                let file = folder.appending(path: "Dropped image.\(ext)")
                if (try? data.write(to: file)) != nil { return files([file]) }
            }
        }
        library.post(.init(title: "Couldn't use what was dropped", reason: "It wasn't a file, a web link or an image. Try saving it first, then drop the file.",
                           details: types.joined(separator: ", ")))
    }

    /// The window's drop target: Wallpapers imports, Upscale loads the file.
    func handleDrop(_ pasteboard: NSPasteboard) {
        switch tab {
        case .upscale: readDrop(pasteboard, files: { if let first = $0.first { self.studio.load(first) } }, links: nil)
        default: readDrop(pasteboard, files: { self.library.add($0) }, links: { $0.forEach(self.library.addFromWeb) })
        }
    }

    /// Types the window accepts for dropping.
    static var dropTypes: [NSPasteboard.PasteboardType] {
        let images = ["com.compuserve.gif", "public.jpeg", "org.webmproject.webp"].map { NSPasteboard.PasteboardType($0) }
        let promises = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        return [.fileURL, .URL, .png, .tiff] + images + promises
    }

    /// Asks for a YouTube link and turns it into a wallpaper.
    func addFromYouTube() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Add a wallpaper from YouTube"
        alert.informativeText = "Paste a YouTube link. The video (no sound) is downloaded at up to your display's resolution and converted automatically. Only use videos you have the right to download."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "https://www.youtube.com/watch?v=…"
        if let clip = NSPasteboard.general.string(forType: .string), let url = URL(string: clip.trimmingCharacters(in: .whitespacesAndNewlines)), WebImport.isYouTube(url) {
            field.stringValue = url.absoluteString
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased()) else {
            library.post(.init(title: "That isn't a web link", reason: "Paste a full YouTube link, like https://www.youtube.com/watch?v=…", details: text))
            return
        }
        library.addFromWeb(url)
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

    // MARK: Settings

    /// Applies settings that affect playback and appearance. Runs after every settings change.
    private func applyPrefs() {
        NSApp.appearance = prefs.theme.appearance
        windows.forEach { $0.dimming = prefs.dimming }
        if appliedDisplays != prefs.displays {
            appliedDisplays = prefs.displays
            buildWindows()
        }
        gate.updateBattery()
        if appliedRotation != prefs.rotationMinutes {
            appliedRotation = prefs.rotationMinutes
            rotationTimer?.invalidate()
            rotationTimer = nil
            if prefs.rotationMinutes > 0 {
                rotationTimer = Timer.scheduledTimer(withTimeInterval: Double(prefs.rotationMinutes) * 60, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.nextWallpaper() }
                }
            }
        }
        updater.applySchedule()
        onPrefsChanged?()
        objectWillChange.send()
    }

    /// Switches the home screen to the next (or a random) wallpaper in the library.
    func nextWallpaper() {
        let candidates = library.videos.filter { library.broken[$0] == nil }
        guard candidates.count > 1 else { return }
        switch prefs.rotationOrder {
        case .inOrder:
            let index = current.flatMap(candidates.firstIndex(of:)) ?? -1
            current = candidates[(index + 1) % candidates.count]
        case .shuffle:
            current = candidates.filter { $0 != current }.randomElement()
        }
    }

    private func loadCurrent() {
        let url = isCurrentBroken ? nil : current
        let info = url.flatMap { library.infos[$0] }
        let edits = url.map(library.edits(for:)) ?? Edits()
        windows.forEach { $0.load(url, edits: edits, size: info?.size, duration: info?.duration ?? 0) }
        gate.apply()
    }

    private func buildWindows() {
        windows.forEach { $0.load(nil); $0.close() }
        // The first screen is the one with the menu bar.
        let screens = prefs.displays == .main ? Array(NSScreen.screens.prefix(1)) : NSScreen.screens
        windows = screens.map(WallpaperWindow.init)
        for w in windows {
            w.onFailure = { [unowned self] url in library.markBroken(url) }
            w.dimming = prefs.dimming
        }
        gate.windows = windows
        loadCurrent()
        objectWillChange.send() // the preview follows the new player
    }
}
