import AppKit
import PhotosUI
import UniformTypeIdentifiers
import os

/// Imports videos and Live Photos from the Photos library through the system picker. The picker runs
/// outside the app and hands over only what you choose, so LiveWallpaper never needs access to the library.
@MainActor
final class PhotosImport: NSObject, PHPickerViewControllerDelegate {
    private let library: Library
    private let log = Logger(subsystem: "LiveWallpaper", category: "photos")

    init(library: Library) {
        self.library = library
    }

    /// Shows the Photos picker as a sheet on `viewController`'s window.
    func present(from viewController: NSViewController) {
        var configuration = PHPickerConfiguration()
        configuration.filter = .any(of: [.videos, .livePhotos])
        configuration.selectionLimit = 0 // as many as you like
        configuration.preferredAssetRepresentationMode = .current // no re-encoding by Photos
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = self
        viewController.presentAsSheet(picker)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        MainActor.assumeIsolated {
            picker.dismiss(nil)
            guard !results.isEmpty else { return }
            library.post(.init(kind: .info, title: "Adding \(results.count) item\(results.count == 1 ? "" : "s") from Photos",
                               reason: "Items stored in iCloud are downloaded first, then each is converted like any other video."))
            for result in results { load(result.itemProvider) }
        }
    }

    private func load(_ provider: NSItemProvider) {
        let name = provider.suggestedName ?? "Photos video"
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
            // The file is deleted when the callback returns, so copy it out first.
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] file, error in
                let copied = file.flatMap { Self.keep($0, name: name) }
                Task { @MainActor in self?.finish(copied, name: name, error: error) }
            }
        } else if let bundleType = provider.registeredTypeIdentifiers.first(where: { $0.contains("live-photo") }) {
            // On the Mac a Live Photo arrives as a package holding its still image and its movie.
            provider.loadFileRepresentation(forTypeIdentifier: bundleType) { [weak self] file, error in
                let movie = file.flatMap { Self.keepMovie(inLivePhoto: $0, name: name) }
                Task { @MainActor in self?.finish(movie, name: name, error: error) }
            }
        } else {
            finish(nil, name: name, error: nil)
        }
    }

    private func finish(_ file: URL?, name: String, error: Error?) {
        guard let file else {
            log.error("photos import failed for \(name, privacy: .public): \(error?.localizedDescription ?? "unsupported", privacy: .public)")
            library.post(.init(title: "Couldn't add “\(name)” from Photos",
                               reason: "Photos didn't hand over a video for it. If it's in iCloud, check your connection and try again.",
                               details: error?.localizedDescription))
            return
        }
        library.add([file]) // converted, checked and cleaned up like any import from the temp folder
    }

    nonisolated private static func freshFolder() -> URL {
        let folder = WebImport.tempDir.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies the movie out of a Live Photo package (the package is deleted when the callback returns).
    nonisolated static func keepMovie(inLivePhoto bundle: URL, name: String) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: nil)) ?? []
        guard let movie = files.first(where: { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true }) else { return nil }
        return keep(movie, name: name)
    }

    nonisolated private static func keep(_ file: URL, name: String) -> URL? {
        let destination = freshFolder().appending(path: name + "." + (file.pathExtension.isEmpty ? "mov" : file.pathExtension))
        return (try? FileManager.default.copyItem(at: file, to: destination)) != nil ? destination : nil
    }
}
