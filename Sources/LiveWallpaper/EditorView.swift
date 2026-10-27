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

    /// Re-applies trim and speed to the preview and plays it.
    func restartPreview() {
        showingLockFrame = false
        looper?.disableLooping()
        player.removeAllItems()
        let item = AVPlayerItem(url: url)
        looper = edits.timeRange(duration: info.duration).map { AVPlayerLooper(player: player, templateItem: item, timeRange: $0) }
            ?? AVPlayerLooper(player: player, templateItem: item)
        player.defaultRate = Float(edits.speed)
        player.play()
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
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

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
