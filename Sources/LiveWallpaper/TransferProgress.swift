import SwiftUI

/// Progress of a download or a long job: fraction, bytes (for downloads) and an estimated time left.
struct TransferProgress {
    var title: String
    var fraction: Double?
    var receivedBytes: Int64?
    var totalBytes: Int64?
    var startedAt = Date()

    /// Same job, new numbers (keeps the start time so the estimate stays steady).
    func updated(fraction: Double?, received: Int64? = nil, total: Int64? = nil) -> TransferProgress {
        var copy = self
        copy.fraction = fraction.map { min(max($0, 0), 1) }
        copy.receivedBytes = received ?? receivedBytes
        copy.totalBytes = total ?? totalBytes
        return copy
    }

    /// "1.2 MB of 4.9 MB · 3 seconds left" or "42% · about 1 minute left".
    var detail: String {
        var parts: [String] = []
        if let receivedBytes, let totalBytes, totalBytes > 0 {
            parts.append("\(Self.size(receivedBytes)) of \(Self.size(totalBytes))")
        } else if let fraction {
            parts.append("\(Int(fraction * 100))%")
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        if let fraction, fraction > 0.02, elapsed > 1 {
            let left = elapsed * (1 - fraction) / fraction
            parts.append(Self.duration(left) + " left")
        } else {
            parts.append("estimating time…")
        }
        if elapsed > 1 { parts.append("\(Self.duration(elapsed)) elapsed") }
        return parts.joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .short
        return formatter.string(from: max(seconds, 1)) ?? "\(Int(seconds)) s"
    }
}

/// Title, then size/time on one line, with the progress bar underneath.
struct ProgressCard: View {
    let progress: TransferProgress
    var symbol = "wand.and.stars"
    var cancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(progress.title).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let cancel {
                    Button(action: cancel) { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Cancel").accessibilityLabel("Cancel")
                }
            }
            .font(.caption.weight(.semibold))
            Text(progress.detail)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .accessibilityIdentifier("progress-detail")
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
