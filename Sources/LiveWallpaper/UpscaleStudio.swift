import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The standalone Upscale tab: upscale any video, GIF or image without making it a wallpaper.
@MainActor
final class UpscaleStudio: ObservableObject {
    @Published private(set) var source: URL?
    /// What's actually upscaled (a GIF/image is first turned into a video).
    @Published private(set) var video: URL?
    @Published private(set) var info: VideoInfo?
    @Published private(set) var thumbnail: NSImage?
    @Published var engine: Upscaler.Engine = .realESRGAN
    @Published var resolution: ResolutionChoice = .native
    @Published private(set) var progress: TransferProgress?
    @Published private(set) var result: URL?
    @Published private(set) var message: (text: String, isError: Bool)?
    private var task: Task<Void, Never>?
    /// Called after an upscale so the app can refresh model sizes.
    var onFinished: ((Upscaler.Method) -> Void)?

    static let outputDir: URL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appending(path: "LiveWallpaper Upscaled", directoryHint: .isDirectory)

    var isBusy: Bool { progress != nil }
    var target: CGSize? { info.map { Upscaler.targetSize(for: $0.size, display: resolution.size) } }

    func choose() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image] + Library.ffmpegExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.message = "Choose a video, GIF or image to upscale"
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func load(_ url: URL) {
        task?.cancel()
        source = url
        video = nil; info = nil; thumbnail = nil; result = nil; message = nil
        task = Task {
            do {
                var playable = url
                if AnimatedImage.isImage(url) {
                    progress = TransferProgress(title: "Preparing “\(url.lastPathComponent)”")
                    let temp = WebImport.tempDir.appending(path: UUID().uuidString + ".mp4")
                    try await AnimatedImage.convert(url, to: temp) { self.progress = self.progress?.updated(fraction: $0) }
                    playable = temp
                }
                let info = try await VideoInfo.load(playable)
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: playable))
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 320, height: 180)
                thumbnail = (try? await generator.image(at: .zero)).map { NSImage(cgImage: $0.image, size: .zero) }
                video = playable
                self.info = info
                engine = ModelAdvisor.recommendation(input: info.size).engine
            } catch {
                message = ("“\(url.lastPathComponent)” can't be upscaled: \(error.localizedDescription) (\(Library.supportedFormats))", true)
            }
            progress = nil
        }
    }

    /// Runs the upscale. `allowDownload` was decided by asking (models only download on request).
    func start(allowDownload: Bool) {
        guard let video, let source, let target else { return }
        try? FileManager.default.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)
        let base = "\(source.deletingPathExtension().lastPathComponent) (Upscaled \(Int(target.width))×\(Int(target.height)))"
        var out = Self.outputDir.appending(path: base + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: out.path) { out = Self.outputDir.appending(path: "\(base) \(n).mp4"); n += 1 }
        result = nil; message = nil
        progress = TransferProgress(title: "Upscaling “\(source.lastPathComponent)”")
        let engine = engine
        task = Task {
            do {
                let r = try await Upscaler.upscale(video, to: out, target: target, engine: engine, allowModelDownload: allowDownload) { title, fraction, received, total in
                    if self.progress?.title == title {
                        self.progress = self.progress?.updated(fraction: fraction, received: received, total: total)
                    } else {
                        self.progress = TransferProgress(title: title, fraction: fraction, receivedBytes: received, totalBytes: total)
                    }
                }
                result = out
                message = ("Upscaled to \(Int(target.width))×\(Int(target.height)) with \(r.method.name)." + (r.fallbackReason.map { " \(engine.title) wasn't used: \($0)" } ?? ""), false)
                onFinished?(r.method)
            } catch {
                try? FileManager.default.removeItem(at: out)
                message = (Task.isCancelled ? "Cancelled." : "Upscaling failed: \(error.localizedDescription)", !Task.isCancelled)
            }
            progress = nil
        }
    }

    func cancel() { task?.cancel() }

    func reveal() { result.map { NSWorkspace.shared.activateFileViewerSelecting([$0]) } }
}

/// The Upscale tab.
struct UpscaleView: View {
    @ObservedObject var studio: UpscaleStudio
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Upscale a video").font(.title3.weight(.semibold))
                Text("Make any video, GIF or image sharper — you don't have to use it as a wallpaper. Results go to Movies › LiveWallpaper Upscaled.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            if let source = studio.source {
                HStack(spacing: 12) {
                    Group {
                        if let thumbnail = studio.thumbnail { Image(nsImage: thumbnail).resizable().scaledToFill() }
                        else { Image(systemName: "film").foregroundStyle(.secondary) }
                    }
                    .frame(width: 128, height: 72).background(Color.secondary.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        if let info = studio.info {
                            Text("\(info.resolutionText) · \(Int(info.fps.rounded())) fps · \(TransferProgress.duration(info.duration))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Choose Another…") { studio.choose() }.disabled(studio.isBusy)
                }
            } else {
                Button { studio.choose() } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "sparkles.rectangle.stack").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Drop a video, GIF or image here")
                        Text("or click to choose").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.tertiary))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("Models on this Mac").font(.headline)
                ModelList(model: model, input: ModelAdvisor.typicalInput, inputLabel: "a 1080p video",
                          selection: Binding(get: { model.upscaler }, set: { model.upscaler = $0 }))
            }

            if let info = studio.info, let target = studio.target {
                HStack {
                    Text("Output resolution").foregroundStyle(.secondary)
                    Picker("Output resolution", selection: $studio.resolution) {
                        ForEach(ResolutionChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 360)
                }
                Text(verbatim: target.width > info.size.width
                     ? "Will upscale \(info.resolutionText) → \(Int(target.width))×\(Int(target.height)) (\(String(format: "%.1f", target.width / info.size.width))×), enough to fill \(Int(studio.resolution.size.width))×\(Int(studio.resolution.size.height))."
                     : "Already \(info.resolutionText) — sharp enough for \(Int(studio.resolution.size.width))×\(Int(studio.resolution.size.height)); nothing to upscale.")
                    .font(.caption).foregroundStyle(.secondary)

                ModelList(model: model, input: info.size, inputLabel: "this \(info.resolutionText) video", selection: $studio.engine)

                HStack {
                    Spacer()
                    Button {
                        var allow = false
                        if Upscaler.needsModelDownload(engine: studio.engine, video: info.size) {
                            guard let answer = ModelConsent.ask(for: studio.engine) else { return }
                            allow = answer
                        }
                        studio.start(allowDownload: allow)
                    } label: { Label("Upscale", systemImage: "sparkles") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(studio.isBusy || target.width <= info.size.width || !ModelAdvisor.availability(studio.engine, input: info.size).canRun)
                }
            }

            if let progress = studio.progress {
                ProgressCard(progress: progress) { studio.cancel() }
            }
            if let message = studio.message {
                Label(message.text, systemImage: message.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError ? .red : .green).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let result = studio.result {
                HStack {
                    Button("Reveal in Finder") { studio.reveal() }
                    Button("Use as Wallpaper") { model.library.add([result]); model.tab = .wallpapers }
                }
            }
        }
    }
}
