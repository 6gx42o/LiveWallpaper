import AppKit
import os

/// Checks GitHub for a newer release, downloads it, verifies it and replaces this app in place —
/// same name, same folder, same bundle ID — so settings, wallpapers, models and the login item all carry over.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let asset: URL
        /// "sha256:…" as published by GitHub, when it provides one.
        let digest: String?
        let page: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Double?)
        case installing
        case failed(String)
    }

    static let repository = "6gx42o/LiveWallpaper"
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    private(set) var state = State.idle { didSet { objectWillChange.send(); onChange?() } }
    var onChange: (() -> Void)?
    /// Whether installing now would interrupt anything (a conversion, an upscale, an open editor…).
    var canInstallNow: (() -> Bool)?
    private var timer: Timer?
    /// The (auto-check) setting the timer was set up for, so unrelated settings changes don't restart it.
    private var scheduledFor: Bool?
    private let log = Logger(subsystem: "LiveWallpaper", category: "update")

    var lastCheck: Date? { UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date }

    /// GitHub's latest-release API. `LW_UPDATE_FEED` points it elsewhere, for testing the whole flow locally.
    private static let testFeed = ProcessInfo.processInfo.environment["LW_UPDATE_FEED"].flatMap(URL.init(string:))
    private static var feed: URL { testFeed ?? URL(string: "https://api.github.com/repos/\(repository)/releases/latest")! }

    /// (Re)starts automatic checks per Settings: a cheap hourly tick that checks once the interval has passed.
    func applySchedule() {
        let enabled = Prefs.value("autoCheckUpdates", true)
        guard scheduledFor != enabled else { return }
        scheduledFor = enabled
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        if case .available(let release) = state { return installIfAllowed(release) }
        guard state != .checking, !isBusy else { return }
        let interval = Double(Prefs.value("updateIntervalHours", 24)) * 3600
        if lastCheck.map({ Date().timeIntervalSince($0) >= interval }) ?? true { check(userInitiated: false) }
    }

    private var isBusy: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }

    /// Asks GitHub for the latest release. Quiet unless the user asked or there's something new.
    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                let release = try await fetchLatest()
                UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
                guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                    state = .upToDate
                    return
                }
                log.notice("update available: \(release.version, privacy: .public)")
                state = .available(release)
                if !userInitiated { installIfAllowed(release) }
            } catch {
                log.error("update check failed: \(error.localizedDescription, privacy: .public)")
                state = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
            }
        }
    }

    private func installIfAllowed(_ release: Release) {
        guard Prefs.value("autoInstallUpdates", true), canInstallNow?() ?? true else { return }
        install(release)
    }

    private func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: Self.feed)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LiveWallpaper/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // no releases yet
        guard status == 200 else { throw Self.failure("GitHub answered with an error (\(status)).") }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard payload.draft != true, payload.prerelease != true else { return nil }
        // Only this repository's own release downloads are accepted (unless testing with a local feed).
        let allowedPrefix = "https://github.com/\(Self.repository)/releases/download/"
        guard let asset = payload.assets.first(where: {
            $0.name.hasSuffix(".zip") && (Self.testFeed != nil || $0.browser_download_url.absoluteString.hasPrefix(allowedPrefix))
        }) else { return nil }
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, notes: payload.body ?? "", asset: asset.browser_download_url,
                       digest: asset.digest, page: payload.html_url)
    }

    /// Downloads, verifies and swaps in the new version, then relaunches.
    func install(_ release: Release) {
        guard !isBusy else { return }
        state = .downloading(nil)
        Task {
            do {
                try await performInstall(release)
            } catch {
                log.error("update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("The update couldn't be installed: \(error.localizedDescription) Your current version is unchanged.")
            }
        }
    }

    private func performInstall(_ release: Release) async throws {
        let zip = try await WebImport.download(release.asset) { received, total in
            Task { @MainActor in self.state = .downloading(total.map { Double(received) / Double($0) }) }
        }
        defer { try? FileManager.default.removeItem(at: zip.deletingLastPathComponent()) }
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            guard try RealESRGAN.sha256(of: zip) == digest.dropFirst(7).lowercased() else {
                throw Self.failure("The download didn't match the published checksum.")
            }
        }
        state = .installing

        let current = Bundle.main.bundleURL
        guard current.pathExtension == "app" else { throw Self.failure("LiveWallpaper isn't running from an app bundle.") }
        // A staging folder on the same disk as the app, so the swap is a quick rename.
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: current, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard let newApp = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
            let info = Bundle(url: newApp)?.infoDictionary
        else { throw Self.failure("The download didn't contain the app.") }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw Self.failure("The download is a different app.")
        }
        guard (info["CFBundleShortVersionString"] as? String) == release.version else {
            throw Self.failure("The download's version doesn't match the release.")
        }
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])

        // Swap in place: the same path and bundle ID keep settings, the login item and Dock/Finder references.
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp)
        UserDefaults.standard.set(Self.currentVersion, forKey: "updatedFrom")
        log.notice("installed \(release.version, privacy: .public); relaunching")
        try relaunch(current)
    }

    /// Opens the app again once this process has quit.
    private func relaunch(_ app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The pid and path are passed as arguments ($0, $1), never spliced into the script.
        shell.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"", "\(pid)", app.path]
        try shell.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { return cont.resume() }
                let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(throwing: failure("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"))
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// Compares dotted versions numerically ("1.10" is newer than "1.9").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }, b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    nonisolated static func failure(_ text: String) -> Error {
        CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
