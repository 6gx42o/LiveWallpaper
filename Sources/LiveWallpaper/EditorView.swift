import AVFoundation
import SwiftUI

/// State for editing one wallpaper: the edits being changed and a looping preview player.
@MainActor
final class EditorModel: ObservableObject {
    let url: URL
    let info: VideoInfo
    @Published var edits: Edits
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    /// Bumped on every restart so a slow look preview can't replace a newer one.
    private var generation = 0
    /// Pausing on the lock screen frame.
    @Published private(set) var showingLockFrame = false

    init(url: URL, info: VideoInfo, edits: Edits) {
        self.url = url
        self.info = info
        self.edits = edits
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        restartPreview()
    }

    var name: String { url.deletingPathExtension().lastPathComponent }
    var trimEnd: Double { edits.trimEnd ?? info.duration }

    /// Re-applies trim, speed and the look to the preview and plays it.
    func restartPreview() {
        showingLockFrame = false
        generation += 1
        let mine = generation, look = edits.lookOrNeutral
        Task {
            let item = AVPlayerItem(url: url)
            if !look.isNeutral {
                // The same Core Image adjustments the bake uses, applied live while editing.
                item.videoComposition = try? await AVMutableVideoComposition.videoComposition(with: AVURLAsset(url: url)) { request in
                    request.finish(with: look.apply(to: request.sourceImage), context: nil)
                }
            }
            guard mine == generation else { return }
            looper?.disableLooping()
            player.removeAllItems()
            looper = edits.timeRange(duration: info.duration).map { AVPlayerLooper(player: player, templateItem: item, timeRange: $0) }
                ?? AVPlayerLooper(player: player, templateItem: item)
            player.defaultRate = Float(edits.speed)
            player.play()
        }
    }

    /// Freezes the preview on the chosen lock screen frame.
    func showLockFrame() {
        showingLockFrame = true
        player.pause()
        player.seek(to: CMTime(seconds: edits.lockFrame, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        looper?.disableLooping()
        player.removeAllItems()
    }

    func reset() {
        edits = Edits()
        restartPreview()
    }
}

/// Shows the player framed exactly like the wallpaper (Fill/Fit + position).
final class PreviewNSView: NSView {
    let playerLayer = AVPlayerLayer()
    var video = CGSize.zero
    var edits = Edits() { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        playerLayer.videoGravity = .resize
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = Edits.playerFrame(video: video, in: bounds, edits: edits)
        CATransaction.commit()
    }
}

struct PlayerPreview: NSViewRepresentable {
    let player: AVPlayer
    let video: CGSize
    let edits: Edits

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.video = video
        view.edits = edits
    }
}

struct EditorView: View {
    @ObservedObject var editor: EditorModel
    /// Name of the upscaler this Mac would use.
    let upscaleMethod: String
    let upscale: () -> Void
    /// Why a smooth 60 fps copy can't be made (nil when it can).
    let smoothUnavailable: String?
    let smooth: () -> Void
    let useForLockScreen: () -> Void
    /// true = save, false = cancel.
    let close: (Bool) -> Void

    private var display: CGSize { Display.pixelSize }
    private var issues: [QualityIssue] { editor.info.issues(on: display, edits: editor.edits) }
    private var cropsHorizontally: Bool { editor.info.size.width / editor.info.size.height > display.width / display.height }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Edit “\(editor.name)”").font(.title3.weight(.semibold))
                Spacer()
                Text("\(editor.info.resolutionText) · \(Int(editor.info.fps.rounded())) fps · \(time(editor.info.duration))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            PlayerPreview(player: editor.player, video: editor.info.size, edits: editor.edits)
                .aspectRatio(display.width / display.height, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if editor.showingLockFrame {
                        Label("Lock screen frame", systemImage: "lock.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .padding(8)
                    }
                }
                .frame(maxWidth: .infinity)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Trim", info: "Plays only the part between Start and End, looping it seamlessly. Handy for cutting intros, logos or a jumpy loop point. The original file isn't changed.")
                    HStack {
                        timeSlider("Start", value: binding(\.trimStart), range: 0...max(editor.trimEnd - 0.5, 0.01)) { editor.restartPreview() }
                        timeSlider("End", value: Binding(get: { editor.trimEnd }, set: { editor.edits.trimEnd = $0 >= editor.info.duration - 0.01 ? nil : $0 }),
                                   range: min(editor.edits.trimStart + 0.5, editor.info.duration)...max(editor.info.duration, 0.01)) { editor.restartPreview() }
                    }
                }
                GridRow {
                    label("Speed", info: "Plays the wallpaper slower or faster. Slower motion is calmer and, at lower speeds, a little easier on the battery.")
                    Picker("Speed", selection: Binding(get: { editor.edits.speed }, set: { editor.edits.speed = $0; editor.restartPreview() })) {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).frame(maxWidth: 360)
                }
                GridRow {
                    label("Framing", info: "Fill covers the whole screen and crops what doesn't fit — use Position to choose which part shows. Fit shows the whole video with black bars.")
                    HStack(spacing: 14) {
                        Picker("Framing", selection: binding(\.fill)) {
                            Text("Fill screen").tag(true)
                            Text("Fit (black bars)").tag(false)
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                        if editor.edits.fill {
                            Text("Position").foregroundStyle(.secondary)
                            Slider(value: cropsHorizontally ? binding(\.offsetX) : binding(\.offsetY), in: -1...1)
                                .frame(maxWidth: 200)
                                .help(cropsHorizontally ? "Slide to show more of the left or right" : "Slide to show more of the top or bottom")
                            Button("Center") { editor.edits.offsetX = 0; editor.edits.offsetY = 0 }
                                .controlSize(.small)
                        }
                    }
                }
                GridRow {
                    label("Lock screen", info: "Pick the frame used as your lock screen picture (macOS only allows a still there). Preview shows it above; Use for Lock Screen saves and applies it.")
                    HStack {
                        Slider(value: binding(\.lockFrame), in: 0...max(editor.info.duration - 0.05, 0.01)) { editing in
                            if !editing { editor.showLockFrame() }
                        }
                        Text(time(editor.edits.lockFrame)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                        Button("Preview") { editor.showLockFrame() }.controlSize(.small)
                        Button("Use for Lock Screen", action: useForLockScreen)
                            .controlSize(.small)
                            .help("Saves your edits and sets this frame as the lock screen wallpaper")
                    }
                }
            }

            look

            quality

            HStack {
                Button("Reset") { editor.reset() }
                Spacer()
                Button("Cancel") { close(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { close(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760)
    }

    /// Colour, softness, vignette and the seamless loop — previewed live, baked once when you save.
    private var look: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text("Look").font(.subheadline.weight(.semibold))
                InfoButton("Adjust brightness, contrast, colour, warmth, softness and a vignette. The preview updates when you let go of a slider. When you save, the look is rendered into the wallpaper once, so playing it costs no extra battery; the original is kept, so you can change it any time.")
                Spacer()
                if !editor.edits.lookOrNeutral.isNeutral {
                    Button("Reset Look") { editor.edits.look = nil; editor.restartPreview() }.controlSize(.small)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    lookSlider("Brightness", \.brightness, -0.5...0.5)
                    lookSlider("Contrast", \.contrast, 0.5...1.5)
                }
                GridRow {
                    lookSlider("Saturation", \.saturation, 0...2)
                    lookSlider("Warmth", \.warmth, -1...1)
                }
                GridRow {
                    lookSlider("Soft focus", \.blur, 0...1)
                    lookSlider("Vignette", \.vignette, 0...1)
                }
            }
            HStack(spacing: 8) {
                Text("Seamless loop").foregroundStyle(.secondary)
                InfoButton("If the video jumps when it starts over, this cross-fades its end into its beginning so the loop is invisible. The video becomes this much shorter. It's rendered when you save.")
                Picker("Seamless loop", selection: Binding(get: { editor.edits.loopFade ?? 0 }, set: { editor.edits.loopFade = $0 > 0 ? $0 : nil })) {
                    Text("Off").tag(0.0)
                    Text("0.5 s").tag(0.5)
                    Text("1 s").tag(1.0)
                    Text("2 s").tag(2.0)
                }
                .labelsHidden().pickerStyle(.segmented).frame(width: 240)
                if editor.edits.needsBake {
                    Text("Rendered when you save").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func lookSlider(_ title: String, _ keyPath: WritableKeyPath<Look, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
            Slider(value: Binding(get: { editor.edits.lookOrNeutral[keyPath: keyPath] },
                                  set: { var look = editor.edits.lookOrNeutral; look[keyPath: keyPath] = $0; editor.edits.look = look.isNeutral ? nil : look }),
                   in: range) { editing in if !editing { editor.restartPreview() } }
        }
    }

    private var quality: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(verbatim: "Quality on your \(Int(display.width))×\(Int(display.height)) display").font(.subheadline.weight(.semibold))
                InfoButton("Checks this video, with your edits, against your display: whether it's sharp enough, whether its shape matches the screen, and its frame rate. Low-resolution videos can be upscaled into a sharper copy.")
            }
            if issues.isEmpty {
                Label("Looks great — resolution and aspect ratio match your display.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
            }
            ForEach(issues, id: \.self) { issue in
                Label(issue.text, systemImage: issue.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
                    .font(.callout)
                    .foregroundStyle(issue.severity == .warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if issues.contains(where: \.isLowResolution) {
                let target = Upscaler.targetSize(for: editor.info.size, display: display)
                Button(action: upscale) {
                    Label("Upscale to " + "\(Int(target.width))×\(Int(target.height))" + " with \(upscaleMethod)", systemImage: "sparkles")
                }
                .help("Makes a sharper copy in your library; the original is kept")
            }
            HStack(spacing: 4) {
                Button(action: smooth) { Label("Make Smooth (60 fps)", systemImage: "wind") }
                    .disabled(smoothUnavailable != nil)
                InfoButton(Self.smoothInfo + (smoothUnavailable.map { "\n\nUnavailable: " + $0 } ?? ""))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    static let smoothInfo = "Makes a copy at 60 frames per second by creating in-between frames with macOS's built-in frame interpolation, so slow 24–30 fps footage moves more smoothly. The original is kept. A 60 fps wallpaper uses roughly twice the battery of a 30 fps one while it plays."

    private func label(_ text: String, info: String) -> some View {
        HStack(spacing: 4) {
            InfoButton(info)
            Text(text).foregroundStyle(.secondary)
        }
        .gridColumnAlignment(.trailing)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<Edits, T>) -> Binding<T> {
        Binding(get: { editor.edits[keyPath: keyPath] }, set: { editor.edits[keyPath: keyPath] = $0 })
    }

    private func timeSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, done: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Slider(value: value, in: range) { editing in if !editing { done() } }
            Text(time(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
        }
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%d:%04.1f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }
}
