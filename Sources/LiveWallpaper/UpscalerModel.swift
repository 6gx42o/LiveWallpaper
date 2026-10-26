import Foundation

/// Apple's Super Resolution model, which macOS downloads on first use (never shipped with the app).
/// It's protected by System Integrity Protection, so no app can delete it; macOS removes it when it
/// needs space. Shown in Settings for information only.
enum UpscalerModel {
    private static let assetRoot = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_VideoEffect")

    /// Downloaded Super Resolution model folders (the ones containing Apple's "vsrnet" network).
    static func installedAssets() -> [URL] {
        let fm = FileManager.default
        let purposes = (try? fm.contentsOfDirectory(at: assetRoot, includingPropertiesForKeys: nil)) ?? []
        return purposes.flatMap { purpose in
            ((try? fm.contentsOfDirectory(at: purpose, includingPropertiesForKeys: nil)) ?? []).filter { asset in
                asset.pathExtension == "asset"
                    && ((try? fm.contentsOfDirectory(atPath: asset.appending(path: "AssetData").path)) ?? []).contains { $0.hasPrefix("vsrnet") }
            }
        }
    }

    /// Bytes on disk, or nil when the model isn't downloaded.
    static func sizeOnDisk() -> Int64? {
        let assets = installedAssets()
        guard !assets.isEmpty else { return nil }
        var total: Int64 = 0
        for asset in assets {
            let files = FileManager.default.enumerator(at: asset, includingPropertiesForKeys: [.totalFileAllocatedSizeKey])
            while let file = files?.nextObject() as? URL {
                total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
