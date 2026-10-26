import SwiftUI

/// Status, wallpaper library and settings — as the compact menu bar panel, or as the
/// resizable (full-screen capable) app window.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var isWindow = false

    var body: some View {
        if isWindow { windowLayout } else { panelLayout }
    }

    private var panelLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            library
            Divider()
            settings
            Divider()
            HStack {
                Spacer()
                quitButton
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var windowLayout: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                library
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                settings
                Spacer()
                quitButton
            }
            .padding(24)
            .frame(width: 300)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.secondary.opacity(0.06))
        }
        .frame(minWidth: 760, minHeight: 500)
    }

    private var quitButton: some View {
        Button("Quit LiveWallpaper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    // MARK: Header

    private var header: some View {
        let status = model.status
        return HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: isWindow ? 30 : 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("LiveWallpaper").font(isWindow ? .title2.weight(.semibold) : .headline)
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("status")
                }
            }
            Spacer()
            if !isWindow {
                Button {
                    model.openWindow?()
                } label: {
                    Image(systemName: "macwindow").frame(width: 16, height: 16)
                }
                .controlSize(.large)
                .help("Open the LiveWallpaper window")
                .accessibilityLabel("Open window")
            }
            Button {
                model.gate.userPaused.toggle()
            } label: {
                Image(systemName: model.gate.userPaused ? "play.fill" : "pause.fill")
                    .frame(width: 16, height: 16)
            }
            .controlSize(.large)
            .disabled(model.current == nil || model.isCurrentBroken)
            .help(model.gate.userPaused ? "Resume" : "Pause")
            .accessibilityLabel(model.gate.userPaused ? "Resume" : "Pause")
        }
    }

    // MARK: Library

    private var library: some View {
        let lib = model.library
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wallpapers").font(isWindow ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.addVideos()
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .controlSize(isWindow ? .large : .regular)

            if let converting = lib.converting {
                ConvertingCard(name: converting.name, fraction: converting.fraction)
            }
            ForEach(lib.failures) { failure in
                BrokenCard(title: "“\(failure.name)” is broken", reason: failure.reason) {
                    model.library.dismissFailure(failure)
                }
            }

            if lib.videos.isEmpty {
                if lib.converting == nil { EmptyLibrary(isLarge: isWindow, add: model.addVideos) }
            } else {
                let columns = isWindow
                    ? [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: 18)]
                    : [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                let grid = LazyVGrid(columns: columns, spacing: isWindow ? 20 : 12) {
                    ForEach(lib.videos, id: \.self) { url in
                        WallpaperTile(
                            name: url.deletingPathExtension().lastPathComponent,
                            thumbnail: lib.thumbnails[url],
                            brokenReason: lib.broken[url],
                            isSelected: url == model.current,
                            select: { model.select(url) },
                            remove: { model.remove(url) }
                        )
                    }
                }
                if isWindow {
                    ScrollView { grid.padding(2) }
                } else if lib.videos.count > 4 {
                    ScrollView { grid.padding(2) }.frame(height: 250)
                } else {
                    grid
                }
            }
        }
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings").font(isWindow ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
            SettingRow(
                title: "Play in Low Power Mode",
                detail: "Off saves battery: the wallpaper pauses in Low Power Mode.",
                isOn: Binding(get: { model.gate.playsInLowPowerMode }, set: { model.gate.playsInLowPowerMode = $0 })
            )
            SettingRow(
                title: "Pause when the desktop is covered",
                detail: "Full-screen apps or maximized windows hide the wallpaper.",
                isOn: Binding(get: { model.gate.pausesWhenCovered }, set: { model.gate.pausesWhenCovered = $0 })
            )
            SettingRow(
                title: "Open at login",
                detail: model.launchAtLoginNeedsApproval
                    ? "Allow it in System Settings › General › Login Items."
                    : "Start LiveWallpaper automatically.",
                isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
            )
        }
    }
}

// MARK: - Components

private struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct WallpaperTile: View {
    let name: String
    let thumbnail: NSImage?
    let brokenReason: String?
    let isSelected: Bool
    let select: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: select) { preview }
                .buttonStyle(.plain)
                .disabled(brokenReason != nil)
                .accessibilityLabel(brokenReason == nil ? "Use \(name)" : "\(name) is broken")
                .overlay(alignment: .topTrailing) {
                    Button(action: remove) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Move to Trash")
                    .accessibilityLabel("Remove \(name)")
                }
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                } else if brokenReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption)
        }
        .help(brokenReason ?? name)
        .contextMenu {
            Button("Move to Trash", role: .destructive, action: remove)
        }
    }

    private var preview: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if brokenReason != nil {
                    ZStack {
                        Color.red.opacity(0.12)
                        VStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text("Broken").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.red)
                    }
                } else if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2.5 : 1)
            )
            .contentShape(Rectangle())
    }
}

private struct ConvertingCard: View {
    let name: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "wand.and.stars")
                Text("Converting “\(name)”").lineLimit(1).truncationMode(.middle)
                Spacer()
                if let fraction { Text("\(Int(fraction * 100))%").monospacedDigit().foregroundStyle(.secondary) }
            }
            .font(.caption)
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BrokenCard: View {
    let title: String
    let reason: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct EmptyLibrary: View {
    var isLarge = false
    let add: () -> Void

    var body: some View {
        Button(action: add) {
            VStack(spacing: 6) {
                Image(systemName: "film.stack").font(isLarge ? .largeTitle : .title2).foregroundStyle(.secondary)
                Text("Add a video to get started")
                Text("Any format — it's converted automatically.").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, isLarge ? 80 : 22)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
                    .foregroundStyle(.tertiary)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
