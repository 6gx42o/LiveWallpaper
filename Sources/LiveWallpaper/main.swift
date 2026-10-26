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

/// The main window forwards drag & drop to its delegate (anywhere in the window).
extension AppDelegate: NSDraggingDestination {
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard model.tab != .memory else { return [] }
        model.isDropTargeted = true
        return .copy
    }

    func draggingExited(_ sender: NSDraggingInfo?) { model.isDropTargeted = false }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        model.isDropTargeted = false
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
