import SwiftUI
import UniformTypeIdentifiers

/// The menu bar panel: what's playing, quick picks from the library, and a way into the window.
struct PanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            library
            Divider()
            HStack {
                Button("Settings…") { model.tab = .settings; model.openWindow?() }
                Spacer()
                Button("Quit LiveWallpaper") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
        .background { ThemeBackground(theme: model.prefs.colorTheme) }
        .tint(model.prefs.tint)
    }

    private func name(_ url: URL?) -> String? { url?.deletingPathExtension().lastPathComponent }

    // MARK: Header

    private var header: some View {
        let status = model.status
        return HStack(spacing: 10) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("LiveWallpaper").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(status.color).frame(width: 7, height: 7)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("status")
                }
                HStack(spacing: 10) {
                    Label(name(model.current) ?? "None", systemImage: "house.fill")
                        .help("Home screen wallpaper (plays behind your desktop icons)")
                    HStack(spacing: 3) {
                        Label(name(model.lockScreen) ?? "None", systemImage: "lock.fill")
                        if model.lockScreen != nil {
                            Button { model.setLockScreen(nil) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain)
                                .help("Remove the lock screen wallpaper and restore your own picture")
                                .accessibilityLabel("Remove lock screen wallpaper")
                        }
                    }
                    .help("Lock screen wallpaper (a still frame — macOS doesn't allow video on the lock screen)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button {
                model.openWindow?()
            } label: {
                Image(systemName: "macwindow").frame(width: 16, height: 16)
            }
            .controlSize(.large)
            .help("Open the LiveWallpaper window")
            .accessibilityLabel("Open window")
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
            HStack(spacing: 4) {
                Text("Wallpapers").font(.subheadline.weight(.semibold))
                InfoButton("Click a wallpaper to play it behind your desktop icons; click its lock to use it on the lock screen. Open the window (the button above) to drag in videos, edit, upscale and change settings.")
                Spacer()
                Button {
                    model.addVideos()
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            // The panel closes as soon as you click another app, so drag & drop lives in the window.
            if lib.videos.isEmpty {
                DropZone(isLarge: true, acceptsDrops: false, add: model.addVideos)
            }
            if let converting = lib.converting {
                ProgressCard(progress: converting) { model.library.cancelCurrentJob() }
            }
            ForEach(lib.notices) { notice in
                NoticeCard(
                    notice: notice,
                    upscale: notice.upscale.map { url in { model.upscale(url); model.library.dismiss(notice) } },
                    dismiss: { model.library.dismiss(notice) }
                )
            }

            if !lib.videos.isEmpty {
                let grid = LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                    ForEach(lib.videos, id: \.self) { url in
                        WallpaperTile(model: model, url: url)
                    }
                }
                if lib.videos.count > 4 {
                    ScrollView { grid.padding(2) }.frame(height: 250)
                } else {
                    grid
                }
            }
        }
    }
}

// MARK: - Components

/// A bit of view state, e.g. hovered or shown (this toolchain has no @State).
final class Flag: ObservableObject {
    @Published var isOn = false
}

/// A small ⓘ button that explains what the thing next to it does.
struct InfoButton: View {
    let text: String
    @StateObject private var shown = Flag()

    init(_ text: String) { self.text = text }

    var body: some View {
        Button { shown.isOn.toggle() } label: {
            Image(systemName: "info.circle").imageScale(.small)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(text)
        .accessibilityLabel("More info")
        .accessibilityHint(text)
        .popover(isPresented: $shown.isOn, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
    }
}

/// A library thumbnail: click for home screen; lock, edit and remove on hover or right-click.
struct WallpaperTile: View {
    @ObservedObject var model: AppModel
    let url: URL
    @StateObject private var hover = Flag()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var name: String { url.deletingPathExtension().lastPathComponent }
    private var brokenReason: String? { model.library.broken[url] }
    private var isHome: Bool { url == model.current }
    private var isLock: Bool { url == model.lockScreen }
    private var isFavorite: Bool { model.library.isFavorite(url) }
    private var canEdit: Bool { model.library.infos[url] != nil }
    private var qualityWarning: String? { model.library.issues(for: url).first { $0.severity == .warning }?.text }

    private func select() { model.select(url) }
    private func toggleLock() { model.setLockScreen(isLock ? nil : url) }
    private func edit() { model.edit(url) }
    private func remove() { model.remove(url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: select) { preview }
                .buttonStyle(.plain)
                .draggable(url) { preview.frame(width: 160) }
                .disabled(brokenReason != nil)
                .accessibilityLabel(brokenReason == nil ? "Use \(name) as home screen wallpaper" : "\(name) is broken")
                .help(brokenReason ?? "Click to use as your home screen wallpaper")
                .overlay(alignment: .topTrailing) {
                    HStack(spacing: 4) {
                        Button { model.library.toggleFavorite(url) } label: {
                            circleIcon(isFavorite ? "star.fill" : "star").foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                        .help(isFavorite ? "Remove from favorites" : "Add to favorites")
                        .accessibilityLabel(isFavorite ? "Remove \(name) from favorites" : "Add \(name) to favorites")
                        .opacity(hover.isOn || isFavorite ? 1 : 0)
                        .allowsHitTesting(hover.isOn || isFavorite)
                        Button(action: remove) { circleIcon("trash") }
                            .buttonStyle(.plain)
                            .help("Move to Trash")
                            .accessibilityLabel("Remove \(name)")
                            .opacity(hover.isOn ? 1 : 0)
                            .allowsHitTesting(hover.isOn)
                    }
                    .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if isHome { badge("Home", "house.fill") }
                        if isLock { badge("Lock", "lock.fill") }
                    }
                    .padding(6)
                }
                .overlay(alignment: .bottomLeading) {
                    if let qualityWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.black, .yellow)
                            .padding(6)
                            .help(qualityWarning)
                            .accessibilityLabel("Quality warning: \(qualityWarning)")
                    }
                }
                .scaleEffect(hover.isOn && !reduceMotion && brokenReason == nil ? 1.02 : 1)
                .shadow(color: .black.opacity(hover.isOn ? 0.18 : 0), radius: 8, y: 3)
            HStack(spacing: 4) {
                if brokenReason != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if brokenReason == nil {
                    Button(action: toggleLock) {
                        Image(systemName: isLock ? "lock.fill" : "lock")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isLock ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .help(isLock ? "Remove from lock screen" : "Use as lock screen wallpaper")
                    .accessibilityLabel(isLock ? "Remove \(name) from lock screen" : "Use \(name) as lock screen")
                    .opacity(hover.isOn || isLock ? 1 : 0.5)
                    Button(action: edit) { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .disabled(!canEdit)
                        .help("Edit: trim, speed, framing, lock screen frame, quality")
                        .accessibilityLabel("Edit \(name)")
                        .opacity(hover.isOn ? 1 : 0.5)
                }
            }
            .font(.caption)
        }
        .onHover { hover.isOn = $0 }
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 1), value: hover.isOn)
        .contextMenu {
            Button(model.displays.count > 1 ? "Use as Default Wallpaper" : "Use as Home Screen", action: select).disabled(brokenReason != nil)
            if model.displays.count > 1 {
                Menu("Use on Display") {
                    ForEach(model.displays, id: \.uuid) { display in
                        Button(display.name) { model.setWallpaper(url, onDisplay: display.uuid) }
                    }
                    Divider()
                    Button("All Displays") { model.useOnAllDisplays(url) }
                }
                .disabled(brokenReason != nil)
            }
            Button(isLock ? "Remove from Lock Screen" : "Use as Lock Screen", action: toggleLock).disabled(brokenReason != nil)
            Button("Edit…", action: edit).disabled(!canEdit)
            Button("Make Smooth (60 fps)") { model.makeSmooth(url) }
                .disabled(brokenReason != nil || model.smoothUnavailableReason(for: url) != nil)
            Button(isFavorite ? "Remove from Favorites" : "Add to Favorites") { model.library.toggleFavorite(url) }
            Divider()
            Button("Move to Trash", role: .destructive, action: remove)
        }
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .padding(5)
            .background(.regularMaterial, in: Circle())
    }

    private func badge(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
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
                } else if let thumbnail = model.library.thumbnails[url] {
                    Image(nsImage: thumbnail).resizable().scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(isHome ? Color.appAccent : Color.primary.opacity(0.1), lineWidth: isHome ? 2.5 : 1)
            )
            .contentShape(Rectangle())
    }
}

/// An error (red), quality warning (orange) or info (accent) message with details to copy.
struct NoticeCard: View {
    let notice: Library.Notice
    /// Shown as an "Upscale" button for low-resolution warnings.
    let upscale: (() -> Void)?
    let dismiss: () -> Void

    private var color: Color {
        switch notice.kind {
        case .error: .red
        case .warning: .orange
        case .info: .appAccent
        }
    }
    private var symbol: String {
        switch notice.kind {
        case .error, .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title).font(.caption.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                Text(notice.reason).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let details = notice.details {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 12) {
                    if let upscale {
                        Button(action: upscale) { Label("Upscale", systemImage: "sparkles") }
                            .controlSize(.small)
                    }
                    Button("Copy details", action: copy)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark").font(.caption) }
                .buttonStyle(.borderless)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copy() {
        let text = [notice.title, notice.reason, notice.details].compactMap { $0 }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Click to choose videos. In the window, files can be dropped anywhere (see `WindowView`).
struct DropZone: View {
    let isLarge: Bool
    let acceptsDrops: Bool
    let add: () -> Void

    private var title: String { acceptsDrops ? "Drop videos here" : "Add a video to get started" }
    private var subtitle: String {
        acceptsDrops
            ? "or click to choose — any video is converted automatically"
            : "Click to choose a file. Open the window to drag & drop."
    }

    var body: some View {
        Button(action: add) {
            Group {
                if isLarge {
                    VStack(spacing: 6) {
                        icon.font(acceptsDrops ? .largeTitle : .title2)
                        Text(title)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.vertical, acceptsDrops ? 80 : 22)
                    .padding(.horizontal, 12)
                } else {
                    HStack(spacing: 10) {
                        icon.font(.title3)
                        Text(title)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6]))
                    .foregroundStyle(.tertiary)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(acceptsDrops ? "Drop videos here, or click to choose" : "Add a video")
    }

    private var icon: some View {
        Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(.secondary)
    }
}
