import AppKit
import AVFoundation

/// Borderless window at desktop level (behind Finder icons) that loops one video on one screen.
final class WallpaperWindow: NSWindow {
    let player = AVQueuePlayer()
    let displayID: CGDirectDisplayID
    private let playerLayer: AVPlayerLayer
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    /// What's loaded, so identical reloads are skipped.
    private var loaded: (url: URL, edits: Edits, size: CGSize?)?
    /// Called when the video can't be played (damaged file, unsupported codec…).
    var onFailure: ((URL) -> Void)?

    var hasVideo: Bool { looper != nil }

    init(screen: NSScreen) {
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        playerLayer = AVPlayerLayer(player: player)
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

        // Layer-hosting: a black container with the player layer placed by the framing settings.
        let container = CALayer()
        container.backgroundColor = NSColor.black.cgColor
        container.masksToBounds = true
        container.addSublayer(playerLayer)
        let view = NSView()
        view.layer = container
        view.wantsLayer = true
        contentView = view
        setFrame(screen.frame, display: false)
    }

    /// Plays `url` with `edits` (trim, speed, framing). `size` is the video's pixel size, if known.
    func load(_ url: URL?, edits: Edits = Edits(), size: CGSize? = nil, duration: Double = 0) {
        if let loaded, loaded.url == url, loaded.edits == edits, loaded.size == size { return }
        player.pause()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        loaded = nil
        // With nothing to show, get out of the way so the desktop picture is visible.
        guard let url else { return orderOut(nil) }

        let item = AVPlayerItem(url: url)
        let looper = edits.timeRange(duration: duration).map { AVPlayerLooper(player: player, templateItem: item, timeRange: $0) }
            ?? AVPlayerLooper(player: player, templateItem: item)
        player.defaultRate = Float(edits.speed) // play() uses this rate
        layout(size: size, edits: edits)
        statusObservation = looper.observe(\.status) { [weak self] looper, _ in
            guard looper.status == .failed else { return }
            Task { @MainActor in self?.onFailure?(url) }
        }
        self.looper = looper
        loaded = (url, edits, size)
        orderFront(nil)
    }

    private func layout(size: CGSize?, edits: Edits) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: frame.size)
        if let size {
            playerLayer.videoGravity = .resize
            playerLayer.frame = Edits.playerFrame(video: size, in: bounds, edits: edits)
        } else {
            playerLayer.videoGravity = edits.fill ? .resizeAspectFill : .resizeAspect
            playerLayer.frame = bounds
        }
        CATransaction.commit()
    }
}
