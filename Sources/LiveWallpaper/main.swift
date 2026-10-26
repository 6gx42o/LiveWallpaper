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
    private var windows: [WallpaperWindow] = []
    private let log = Logger(subsystem: "LiveWallpaper", category: "app")

    private(set) var current: URL? {
        didSet {
            UserDefaults.standard.set(current?.lastPathComponent, forKey: "wallpaper")
            loadCurrent()
        }
    }

    init() {
        gate.onChange = { [unowned self] in objectWillChange.send() }
        library.onChange = { [unowned self] in
            // A wallpaper found to be broken after it was selected stops showing.
            if let current, library.broken[current] != nil, windows.contains(where: \.hasVideo) { loadCurrent() }
            objectWillChange.send()
        }
        library.onConverted = { [unowned self] url in if current == nil { current = url } }

        let saved = UserDefaults.standard.string(forKey: "wallpaper")
        current = library.videos.first { $0.lastPathComponent == saved }
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

    func remove(_ url: URL) {
        if url == current { current = nil }
        library.remove(url)
    }

    func addVideos() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.message = "Choose videos to use as wallpapers. Any format is converted automatically."
        if panel.runModal() == .OK { library.add(panel.urls) }
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
        windows.forEach { $0.load(isCurrentBroken ? nil : current) }
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private lazy var model = AppModel()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let button = statusItem.button
        button?.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: "LiveWallpaper")
        button?.target = self
        button?.action = #selector(togglePanel(_:))

        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        model.openWindow = { [unowned self] in showMainWindow() }
        NSApp.mainMenu = makeMainMenu()

        // First run: nothing to show yet, so open the window instead of leaving only a menu bar icon.
        if model.library.videos.isEmpty { showMainWindow() }
    }

    /// `open -a LiveWallpaper clip.mov` / Open With → import.
    func application(_ application: NSApplication, open urls: [URL]) { model.library.add(urls) }

    /// Opening the app again while it's running brings up the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            model.library.reload()
            NSApp.activate()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    @objc private func showMainWindow() {
        popover.performClose(nil)
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            window.title = "LiveWallpaper"
            let host = NSHostingController(rootView: PanelView(model: model, isWindow: true))
            host.sizingOptions = .minSize // let the user resize; SwiftUI only enforces the minimum
            window.contentViewController = host
            window.setContentSize(NSSize(width: 980, height: 640))
            window.collectionBehavior = .fullScreenPrimary
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("MainWindow")
            mainWindow = window
        }
        // While the window is open, behave like a regular app (Dock icon, menu bar, ⌘-Tab, full screen).
        NSApp.setActivationPolicy(.regular)
        // Activating in the same pass as the policy change can leave the window behind other Spaces.
        DispatchQueue.main.async { [weak self] in
            NSApp.activate()
            self?.mainWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide LiveWallpaper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LiveWallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Video…", action: #selector(addVideos), keyEquivalent: "o").target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        for (title, menu) in [("LiveWallpaper", appMenu), ("File", fileMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return main
    }

    @objc private func addVideos() { model.addVideos() }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
