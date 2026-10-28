import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private lazy var model = AppModel()
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let button = statusItem.button
        updateStatusIcon()
        model.onPrefsChanged = { [unowned self] in updateStatusIcon() }
        button?.target = self
        button?.action = #selector(togglePanel(_:))

        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        model.openWindow = { [unowned self] in showMainWindow() }
        NSApp.mainMenu = makeMainMenu()

        // First run: nothing to show yet, so open the window instead of leaving only a menu bar icon.
        if model.library.videos.isEmpty || model.prefs.openWindowAtLaunch { showMainWindow() }
    }

    private func updateStatusIcon() {
        statusItem.button?.image = NSImage(systemSymbolName: model.prefs.menuBarIcon.rawValue, accessibilityDescription: "LiveWallpaper")
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
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.title = "LiveWallpaper"
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden // the tabs show where you are
            let host = NSHostingController(rootView: WindowView(model: model))
            host.sizingOptions = .minSize // let the user resize; SwiftUI only enforces the minimum
            host.sceneBridgingOptions = [.title, .toolbars] // SwiftUI's title and toolbar drive the window's
            window.contentViewController = host
            window.setContentSize(NSSize(width: 1040, height: 700))
            window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace] // open on the Space you're using
            window.isReleasedWhenClosed = false
            window.delegate = self
            // Drops are read at the window level with AppKit so browser-promised files (dragged images/GIFs) work.
            window.registerForDraggedTypes(AppModel.dropTypes)
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
        appMenu.addItem(withTitle: "Settings…", action: #selector(showTab(_:)), keyEquivalent: ",").tag = AppModel.Tab.allCases.firstIndex(of: .settings)!
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide LiveWallpaper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit LiveWallpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Add Video…", action: #selector(addVideos), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Add from YouTube…", action: #selector(addFromYouTube), keyEquivalent: "l")
        fileMenu.addItem(withTitle: "Find Videos on This Mac…", action: #selector(findVideos), keyEquivalent: "F") // ⇧⌘F
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let viewMenu = NSMenu(title: "View")
        for (index, tab) in AppModel.Tab.allCases.enumerated() where tab != .settings {
            viewMenu.addItem(withTitle: tab.rawValue, action: #selector(showTab(_:)), keyEquivalent: "\(index + 1)").tag = index
        }
        let wallpaperMenu = NSMenu(title: "Wallpaper")
        let pause = wallpaperMenu.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "p")
        pause.keyEquivalentModifierMask = [.option, .command]
        wallpaperMenu.addItem(withTitle: "Next Wallpaper", action: #selector(nextWallpaper), keyEquivalent: "]")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let fullScreen = windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        for menu in [appMenu, fileMenu, viewMenu, wallpaperMenu] {
            for item in menu.items where item.action.map({ responds(to: $0) }) == true { item.target = self }
        }
        for (title, menu) in [("LiveWallpaper", appMenu), ("File", fileMenu), ("View", viewMenu), ("Wallpaper", wallpaperMenu), ("Window", windowMenu)] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = windowMenu
        return main
    }

    @objc private func addVideos() {
        if model.tab == .upscale { model.studio.choose() } else { model.addVideos() }
    }
    @objc private func addFromYouTube() { model.tab = .wallpapers; model.addFromYouTube() }
    @objc private func findVideos() { model.tab = .wallpapers; model.startScan() }
    @objc private func togglePause() { model.gate.userPaused.toggle() }
    @objc private func nextWallpaper() { model.nextWallpaper() }
    @objc private func checkForUpdates() {
        model.tab = .settings
        showMainWindow()
        model.updater.check(userInitiated: true)
    }

    @objc private func showTab(_ sender: NSMenuItem) {
        model.tab = AppModel.Tab.allCases[sender.tag]
        showMainWindow()
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(togglePause):
            item.title = model.gate.userPaused ? "Resume" : "Pause"
            return model.current != nil && !model.isCurrentBroken
        case #selector(showTab(_:)):
            item.state = mainWindow?.isVisible == true && AppModel.Tab.allCases[item.tag] == model.tab ? .on : .off
            return true
        default:
            return true
        }
    }
}

/// The main window forwards drag & drop to its delegate (anywhere in the window).
extension AppDelegate: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Library tiles dragged onto a display preview are internal (draggingSource set) — never import them.
        guard sender.draggingSource == nil, model.tab == .wallpapers || model.tab == .upscale else { return [] }
        model.isDropTargeted = true
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) { model.isDropTargeted = false }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
        guard sender.draggingSource == nil else { return false }
        model.handleDrop(sender.draggingPasteboard)
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
