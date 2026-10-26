import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finds videos on the Mac that could make a good wallpaper; the user picks which to add.
@MainActor
final class VideoScanner: ObservableObject {
    struct Candidate: Identifiable {
        let url: URL
        let bytes: Int64
        var info: VideoInfo?
        var thumbnail: NSImage?
        var selected = false
        /// Already in the library (same name).
        var alreadyAdded = false
        var id: URL { url }

        var folder: String { url.deletingLastPathComponent().lastPathComponent }
        var issues: [QualityIssue] { info?.issues(on: Display.pixelSize) ?? [] }
        var hasWarning: Bool { issues.contains { $0.severity == .warning } }
        /// Best fits first: no warnings, then the most pixels.
        var score: Double {
            guard let info else { return -1 }
            return (hasWarning ? 0 : 1_000_000_000) + info.size.width * info.size.height
        }
    }

    nonisolated static let defaultRoots: [URL] = [.moviesDirectory, .downloadsDirectory, .desktopDirectory, .documentsDirectory, .picturesDirectory]

    @Published private(set) var candidates: [Candidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var status = ""
    private let roots: [URL]
    private let existingNames: Set<String>
    private var task: Task<Void, Never>?

    /// Shortest clip worth looping, and how many files to analyse at most.
    private static let minimumDuration = 2.0
    nonisolated private static let maxCandidates = 200

    init(roots: [URL] = defaultRoots, existingNames: Set<String>) {
        self.roots = roots
        self.existingNames = existingNames
    }

    var selectedURLs: [URL] { candidates.filter(\.selected).map(\.url) }
    var rootNames: String { roots.map(\.lastPathComponent).formatted(.list(type: .and)) }

    func toggle(_ id: URL) {
        guard let i = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[i].selected.toggle()
    }

    func start() {
        task?.cancel()
        candidates = []
        isScanning = true
        status = "Looking for videos in \(rootNames)…"
        let roots = roots
        task = Task {
            let files = await Task.detached(priority: .userInitiated) { Self.findVideoFiles(in: roots) }.value
            status = "Checking \(files.count) video\(files.count == 1 ? "" : "s")…"
            await analyse(files)
            isScanning = false
            let usable = candidates.count
            status = usable == 0 ? "No suitable videos found in \(rootNames)." : "Found \(usable) video\(usable == 1 ? "" : "s") that could be a wallpaper."
        }
    }

    func cancel() {
        task?.cancel()
        isScanning = false
    }

    /// Video files (by type), skipping hidden files, app bundles/photo libraries and LiveWallpaper's own folder.
    nonisolated private static func findVideoFiles(in roots: [URL]) -> [(URL, Int64)] {
        let ownFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "LiveWallpaper").path
        var found: [(URL, Int64)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentTypeKey]
        for root in roots {
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = files?.nextObject() as? URL {
                if Task.isCancelled { return found }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      !url.path.hasPrefix(ownFolder) else { continue }
                let isMovie = values.contentType?.conforms(to: .movie) ?? false
                guard isMovie || Library.ffmpegExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let bytes = Int64(values.fileSize ?? 0)
                guard bytes > 200_000 else { continue } // tiny files are icons/previews
                found.append((url, bytes))
            }
        }
        // Newest-looking big files tend to be the interesting ones; analyse the largest first.
        return Array(found.sorted { $0.1 > $1.1 }.prefix(maxCandidates))
    }

    /// Reads each file's size/duration and a thumbnail, keeping only usable videos.
    private func analyse(_ files: [(URL, Int64)]) async {
        for (index, (url, bytes)) in files.enumerated() {
            if Task.isCancelled { return }
            status = "Checking videos… \(index + 1) of \(files.count)"
            // Formats macOS can't read (WebM, MKV…) are still offered; they're converted with ffmpeg on import.
            let info = try? await VideoInfo.load(url)
            if let info, info.duration < Self.minimumDuration || min(info.size.width, info.size.height) < 240 { continue }
            var candidate = Candidate(url: url, bytes: bytes, info: info)
            candidate.alreadyAdded = existingNames.contains(url.deletingPathExtension().lastPathComponent)
            candidate.selected = false
            candidate.thumbnail = await thumbnail(url)
            candidates.append(candidate)
            candidates.sort { $0.score > $1.score }
        }
    }

    private func thumbnail(_ url: URL) async -> NSImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 135)
        guard let (image, _) = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}

/// Lists the scan results with a checkbox each; "Add" imports the chosen ones.
struct ScanView: View {
    @ObservedObject var scanner: VideoScanner
    /// Called with the videos to add (empty = cancelled).
    let finish: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find wallpapers on your Mac").font(.title3.weight(.semibold))
                HStack(spacing: 6) {
                    if scanner.isScanning { ProgressView().controlSize(.small) }
                    Text(scanner.status).font(.callout).foregroundStyle(.secondary)
                }
            }

            if scanner.candidates.isEmpty && !scanner.isScanning {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Nothing to add here. You can still drag videos onto the window from anywhere.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(scanner.candidates) { candidate in
                            ScanRow(candidate: candidate) { scanner.toggle(candidate.id) }
                        }
                    }
                }
                .frame(minHeight: 280, maxHeight: 420)
            }

            HStack {
                Text("Videos are copied and converted; your originals aren't moved.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { scanner.cancel(); finish([]) }
                    .keyboardShortcut(.cancelAction)
                let count = scanner.selectedURLs.count
                Button(count == 0 ? "Add" : "Add \(count) Video\(count == 1 ? "" : "s")") { scanner.cancel(); finish(scanner.selectedURLs) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

private struct ScanRow: View {
    let candidate: VideoScanner.Candidate
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("Add \(candidate.url.lastPathComponent)", isOn: Binding(get: { candidate.selected }, set: { _ in toggle() }))
                .labelsHidden()
            Group {
                if let thumbnail = candidate.thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .frame(width: 96, height: 54)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            badge
        }
        .padding(8)
        .background(candidate.selected ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help(candidate.issues.map(\.text).joined(separator: "\n"))
    }

    private var details: String {
        var parts: [String] = []
        if let info = candidate.info {
            parts.append(info.resolutionText)
            parts.append(String(format: "%d:%02d", Int(info.duration) / 60, Int(info.duration) % 60))
        } else {
            parts.append("needs ffmpeg to read")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: candidate.bytes, countStyle: .file))
        parts.append("in \(candidate.folder)")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        if candidate.alreadyAdded {
            tag("Already added", .secondary)
        } else if candidate.info == nil {
            tag("Unknown quality", .secondary)
        } else if candidate.hasWarning {
            tag("Low resolution", .orange)
        } else if candidate.issues.isEmpty {
            tag("Great fit", .green)
        } else {
            tag("Good fit", .accentColor)
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
