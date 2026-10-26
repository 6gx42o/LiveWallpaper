import AppKit
import AVFoundation

/// Borderless window at desktop level (behind Finder icons) that loops one video on one screen.
final class WallpaperWindow: NSWindow {
    let player = AVQueuePlayer()
    let displayID: CGDirectDisplayID
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    /// Called when the video can't be played (damaged file, unsupported codec…).
    var onFailure: ((URL) -> Void)?

    var hasVideo: Bool { looper != nil }

    init(screen: NSScreen) {
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false

        player.isMuted = true
        // Default is true, which would hold a display-sleep assertion while the wallpaper plays.
        player.preventsDisplaySleepDuringVideoPlayback = false

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        let view = NSView()
        view.layer = playerLayer // layer-hosting: assign the layer before enabling wantsLayer
        view.wantsLayer = true
        contentView = view
        setFrame(screen.frame, display: false)
    }

    func load(_ url: URL?) {
        player.pause()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        // With nothing to show, get out of the way so the real desktop picture is visible.
        guard let url else { return orderOut(nil) }
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        statusObservation = looper.observe(\.status) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            Task { @MainActor in self?.onFailure?(url) }
        }
        self.looper = looper
        orderFront(nil)
    }
}
