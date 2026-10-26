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
    /// Called after the cache is cleared (the wallpaper reloads its video, which purge can leave blank).
    var onCacheCleared: (() -> Void)?
    private var timer: Timer?

    var total: Int64 { SystemInfo.totalMemory }
    var used: Int64 { max(total - available, 0) }

    /// Refreshes every 2 s while the Memory tab is visible.
    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
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

    /// Clears the disk cache macOS keeps in RAM, using the system's `purge` tool (macOS asks for a password).
    func cleanCache() {
        let before = SystemInfo.freeMemory()
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"/usr/sbin/purge\" with administrator privileges with prompt \"LiveWallpaper needs your password to clear macOS's memory cache.\"")?
            .executeAndReturnError(&error)
        if let error {
            lastResult = (error[NSAppleScript.errorNumber] as? Int) == -128 ? nil : "Couldn't clear the cache: \(error[NSAppleScript.errorMessage] as? String ?? "unknown error")"
            return
        }
        let after = SystemInfo.freeMemory()
        refresh()
        onCacheCleared?()
        Logger(subsystem: "LiveWallpaper", category: "memory").notice("purge done: free \(before) -> \(after) bytes")
        // purge turns cached files into truly free memory, so report the change in free memory.
        lastResult = "Cleared macOS's file cache — free memory went from \(SystemInfo.bytes(before)) to \(SystemInfo.bytes(after))."
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
                Text("Memory").font(.title3.weight(.semibold))
                Text("\(SystemInfo.chip) · \(SystemInfo.bytes(cleaner.total)) RAM").font(.callout).foregroundStyle(.secondary)
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
                Spacer()
                Button("Clean Memory…") { cleaner.cleanCache() }
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
