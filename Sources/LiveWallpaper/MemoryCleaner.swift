import AppKit
import Darwin
import SwiftUI
import os

/// Frees memory before upscaling: shows what's using RAM, quits apps you pick (each can still ask
/// to save), and can clear macOS's file cache. Nothing is closed without asking.
@MainActor
final class MemoryCleaner: ObservableObject {
    struct AppUsage: Identifiable {
        let app: NSRunningApplication
        let bytes: Int64
        var id: pid_t { app.processIdentifier }
        var name: String { app.localizedName ?? "App" }
    }

    @Published private(set) var available: Int64 = SystemInfo.availableMemory()
    @Published private(set) var pressure = SystemInfo.memoryPressure()
    @Published private(set) var swapped = SystemInfo.swapUsed()
    @Published private(set) var apps: [AppUsage] = []
    @Published var selected: Set<pid_t> = []
    @Published private(set) var lastResult: String?
    /// True while Clean Memory runs (it takes a few seconds).
    @Published private(set) var isCleaning = false
    /// Called after the cache is cleared (the wallpaper reloads its video, which purge can leave blank).
    var onCacheCleared: (() -> Void)?
    private var timer: Timer?

    var total: Int64 { SystemInfo.totalMemory }
    var used: Int64 { max(total - available, 0) }

    /// Refreshes (every 2 s by default; see Settings) while the Memory section is visible.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(Prefs.value("memoryRefreshSeconds", 2)), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        available = SystemInfo.availableMemory()
        pressure = SystemInfo.memoryPressure()
        swapped = SystemInfo.swapUsed()
        let me = ProcessInfo.processInfo.processIdentifier
        let processes = Self.allProcesses()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != me && !$0.isTerminated }
        // With several copies of one app open, helpers can't be told apart, so each copy counts only itself.
        let copies = Dictionary(grouping: running) { $0.bundleURL?.path ?? "\($0.processIdentifier)" }.mapValues(\.count)
        apps = running
            .map { app in
                let shared = copies[app.bundleURL?.path ?? ""] ?? 1 > 1
                return AppUsage(app: app, bytes: shared ? Self.footprint(app.processIdentifier) : Self.totalFootprint(of: app, processes: processes))
            }
            .sorted { $0.bytes > $1.bytes }
        selected = selected.filter { pid in apps.contains { $0.id == pid } }
    }

    func toggle(_ pid: pid_t) {
        if selected.contains(pid) { selected.remove(pid) } else { selected.insert(pid) }
    }

    /// Asks, then quits the chosen apps normally (they can still ask to save documents).
    func quit(_ targets: [AppUsage]) {
        guard !targets.isEmpty else { return }
        let before = SystemInfo.availableMemory()
        let freed = targets.reduce(0) { $0 + $1.bytes }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = targets.count == 1 ? "Quit \(targets[0].name)?" : "Quit \(targets.count) apps?"
        alert.informativeText = "\(targets.map(\.name).formatted(.list(type: .and))) will close, freeing up to about \(SystemInfo.bytes(freed)). Apps with unsaved work will ask you to save first."
        alert.addButton(withTitle: targets.count == 1 ? "Quit App" : "Quit Apps")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        targets.forEach { $0.app.terminate() }
        selected.removeAll()
        Task {
            try? await Task.sleep(for: .seconds(2))
            refresh()
            let freed = available - before
            lastResult = "Quit \(targets.map(\.name).formatted(.list(type: .and)))" + (freed > 50_000_000 ? ", freeing \(SystemInfo.bytes(freed))" : "") + " — \(SystemInfo.bytes(available)) now available."
        }
    }

    /// Every other open app except Finder (which macOS keeps running).
    var otherApps: [AppUsage] { apps.filter { $0.app.bundleIdentifier != "com.apple.finder" } }

    /// Frees memory macOS is holding but doesn't need, without closing anything (macOS asks for your password):
    /// first it briefly signals "memory is getting tight" (simulated — no real pressure) so apps and system
    /// services drop their caches, then `purge` empties the file cache.
    /// Runs in the background; afterwards the window you were in comes back to the front, because the
    /// password prompt is another app and Stage Manager would otherwise leave this window off stage.
    func cleanCache() {
        guard !isCleaning else { return }
        isCleaning = true
        lastResult = nil
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        let freeBefore = SystemInfo.freeMemory(), usedBefore = used
        let script = Self.testCleanCommand ?? """
            do shell script "/usr/bin/memory_pressure -S -l warn -s 4 >/dev/null 2>&1; /usr/sbin/purge" \
            with administrator privileges with prompt "LiveWallpaper needs your password to free up memory macOS is holding but not using. Nothing will be closed."
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] // fixed script, no user input
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = p.terminationStatus
            Task { @MainActor in self?.finishCleaning(status: status, message: message, window: window, freeBefore: freeBefore, usedBefore: usedBefore) }
        }
        do { try process.run() } catch {
            isCleaning = false
            lastResult = "Couldn't start cleaning: \(error.localizedDescription)"
        }
    }

    /// For testing the flow without a password prompt (`LW_TEST_CLEAN_SCRIPT` holds an AppleScript).
    private static let testCleanCommand = ProcessInfo.processInfo.environment["LW_TEST_CLEAN_SCRIPT"]

    private func finishCleaning(status: Int32, message: String, window: NSWindow?, freeBefore: Int64, usedBefore: Int64) {
        isCleaning = false
        // Bring back the window you were in (the password prompt took focus).
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        guard status == 0 else {
            // -128 = you clicked Cancel in the password prompt.
            lastResult = message.contains("-128") ? nil : "Couldn't clean memory: \(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            return
        }
        let freeAfter = SystemInfo.freeMemory()
        refresh()
        onCacheCleared?()
        let released = max(usedBefore - used, 0)
        Logger(subsystem: "LiveWallpaper", category: "memory").notice("clean done: free \(freeBefore) -> \(freeAfter), used \(usedBefore) -> \(self.used)")
        if freeAfter > freeBefore + 50_000_000 || released > 50_000_000 {
            lastResult = "Cleaned up: free memory went from \(SystemInfo.bytes(freeBefore)) to \(SystemInfo.bytes(freeAfter))"
                + (released > 50_000_000 ? ", and apps released \(SystemInfo.bytes(released)) of caches." : ".")
                + " Nothing was closed."
        } else {
            lastResult = "Cleaned up — macOS wasn't holding much it didn't need, so there was little to free. Nothing was closed."
        }
    }

    /// Every process's executable path and memory footprint.
    private static func allProcesses() -> [(path: String, bytes: Int64)] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        var result: [(String, Int64)] = []
        var buffer = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(Int(max(filled, 0))) where pid > 0 {
            guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { continue }
            result.append((String(cString: buffer), footprint(pid)))
        }
        return result
    }

    /// An app's own memory plus its helper processes (browsers and Electron apps run many),
    /// i.e. every process whose executable lives inside the app's bundle.
    private static func totalFootprint(of app: NSRunningApplication, processes: [(path: String, bytes: Int64)]) -> Int64 {
        guard let bundle = app.bundleURL?.path else { return footprint(app.processIdentifier) }
        let total = processes.filter { $0.path.hasPrefix(bundle + "/") }.reduce(Int64(0)) { $0 + $1.bytes }
        return max(total, footprint(app.processIdentifier))
    }

    /// Physical memory footprint of a process (what Activity Monitor calls "Memory").
    private static func footprint(_ pid: pid_t) -> Int64 {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(info.ri_phys_footprint) : 0
    }
}

/// The Memory tab: a usage gauge, the biggest apps, and ways to free RAM.
struct MemoryView: View {
    @ObservedObject var cleaner: MemoryCleaner
    /// Memory the selected upscaler needs, to show whether there's enough.
    let needed: (name: String, bytes: Int64)?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Text("\(SystemInfo.chip) · \(SystemInfo.bytes(cleaner.total)) RAM").font(.headline)
                    InfoButton("Your Mac's memory right now. Upscaling with ML models needs a lot of free memory; if there isn't enough, macOS starts swapping to disk and everything slows down. Use this section to see what's using memory and free some up before upscaling.")
                }
                ProgressView(value: Double(cleaner.used), total: Double(cleaner.total))
                    .tint(pressureColor)
                HStack {
                    Text("\(SystemInfo.bytes(cleaner.used)) used").monospacedDigit()
                    Spacer()
                    Text("\(SystemInfo.bytes(cleaner.available)) available").monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
                Label(cleaner.pressure >= 4 ? "Memory pressure: critical" : cleaner.pressure >= 2 ? "Memory pressure: high — macOS is compressing and swapping" : "Memory pressure: normal",
                      systemImage: "gauge.with.dots.needle.33percent")
                    .font(.caption).foregroundStyle(cleaner.pressure >= 2 ? .orange : .secondary)
                    .help("Memory pressure is macOS's own measure of how hard it's working to find memory. Normal is fine; high means it's compressing and swapping.")
                if cleaner.swapped > 0 {
                    Text("\(SystemInfo.bytes(cleaner.swapped)) swapped to disk").font(.caption).foregroundStyle(.secondary)
                }
                if let needed {
                    let enough = cleaner.available >= needed.bytes && cleaner.pressure < 2
                    Label(enough ? "Enough free memory for \(needed.name) (needs about \(SystemInfo.bytes(needed.bytes)))."
                                 : cleaner.available < needed.bytes
                                    ? "\(needed.name) needs about \(SystemInfo.bytes(needed.bytes)) — free up \(SystemInfo.bytes(needed.bytes - cleaner.available)) more by quitting apps below."
                                    : "\(needed.name) needs about \(SystemInfo.bytes(needed.bytes)), but memory pressure is high — quit apps below to bring it back to normal.",
                          systemImage: enough ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(enough ? .green : .orange).font(.callout)
                }
            }

            HStack {
                Text("Apps using memory").font(.headline)
                InfoButton("Open apps, biggest first, including their helper processes. Tick apps and Quit Selected to close them (each can still ask to save). Clean Memory frees memory macOS is holding but not using — it has apps and system services drop their caches and empties the file cache — without closing anything or this window. It asks for your password.")
                Spacer()
                Button {
                    cleaner.cleanCache()
                } label: {
                    if cleaner.isCleaning {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Cleaning…") }
                    } else {
                        Text("Clean Memory…")
                    }
                }
                .disabled(cleaner.isCleaning)
                    .help("Clears macOS's file cache from RAM (asks for your password). Doesn't close anything.")
                Button("Quit All Other Apps…") { cleaner.quit(cleaner.otherApps) }
                    .help("Asks first; apps with unsaved work will ask you to save")
                    .disabled(cleaner.otherApps.isEmpty)
                Button("Quit Selected…") { cleaner.quit(cleaner.apps.filter { cleaner.selected.contains($0.id) }) }
                    .disabled(cleaner.selected.isEmpty)
            }
            if let result = cleaner.lastResult {
                Text(result).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(cleaner.apps) { usage in
                        HStack(spacing: 10) {
                            Toggle("Select \(usage.name)", isOn: Binding(get: { cleaner.selected.contains(usage.id) }, set: { _ in cleaner.toggle(usage.id) }))
                                .labelsHidden()
                            if let icon = usage.app.icon { Image(nsImage: icon).resizable().frame(width: 22, height: 22) }
                            Text(usage.name)
                            Spacer()
                            Text(usage.bytes > 0 ? SystemInfo.bytes(usage.bytes) : "—").monospacedDigit().foregroundStyle(.secondary)
                                .help(usage.bytes > 0 ? "" : "macOS doesn't let apps measure this one's memory")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(cleaner.selected.contains(usage.id) ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { cleaner.toggle(usage.id) }
                    }
                }
            }
        }
        .onAppear { cleaner.start() }
        .onDisappear { cleaner.stop() }
    }

    private var pressureColor: Color {
        let usedFraction = Double(cleaner.used) / Double(max(cleaner.total, 1))
        return usedFraction > 0.85 ? .red : usedFraction > 0.7 ? .orange : .green
    }
}
