import AppKit
import AVFoundation

/// Borderless window at desktop level (behind Finder icons) that loops one video on one screen.
final class WallpaperWindow: NSWindow {
    let player = AVQueuePlayer()
    let displayID: CGDirectDisplayID
    /// Stable identity used to remember this display's own wallpaper.
    let displayUUID: String
    /// e.g. "Built-in Retina Display", "LG UltraFine".
    let displayName: String
    private let playerLayer: AVPlayerLayer
    /// Black layer over the video; its opacity is the "Dim wallpaper" setting.
    private let dimLayer = CALayer()
    var dimming = 0.0 {
        didSet {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            dimLayer.opacity = Float(dimming)
            CATransaction.commit()
        }
    }
    private var looper: AVPlayerLooper?
    private var statusObservation: NSKeyValueObservation?
    /// What's loaded, so identical reloads are skipped.
    private var loaded: (url: URL, edits: Edits, size: CGSize?, duration: Double)?
    /// Called when the video can't be played (damaged file, unsupported codec…).
    var onFailure: ((URL) -> Void)?

    var hasVideo: Bool { looper != nil }

    init(screen: NSScreen) {
        displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
        displayUUID = SystemInfo.displayUUID(displayID)
        displayName = screen.localizedName
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
        dimLayer.backgroundColor = NSColor.black.cgColor
        dimLayer.opacity = 0
        dimLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        container.addSublayer(dimLayer)
        let view = NSView()
        view.layer = container
        view.wantsLayer = true
        contentView = view
        setFrame(screen.frame, display: false)
    }

    /// Reloads the current video in place (after a memory clean dropped its cached frames), without
    /// ordering the window out and back in.
    func reload() {
        guard let loaded else { return }
        self.loaded = nil
        player.pause()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        load(loaded.url, edits: loaded.edits, size: loaded.size, duration: loaded.duration)
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
        loaded = (url, edits, size, duration)
        if !isVisible { orderFront(nil) }
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
