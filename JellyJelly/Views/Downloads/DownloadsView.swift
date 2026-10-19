import SwiftUI

/// Everything downloaded for offline viewing, grouped by series or channel.
struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    private var downloads: DownloadManager { app.downloads }

    var body: some View {
        let pending = downloads.records.values.filter { !$0.isComplete }.sorted { $0.addedAt < $1.addedAt }
        let groups = DownloadGroup.groups(from: downloads.records.values.filter(\.isComplete))
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                PageTitle(title: String(localized: "Downloads"), subtitle: subtitle)

                if !pending.isEmpty {
                    section(title: String(localized: "Downloading"), subtitle: String(localized: "\(pending.count) items")) {
                        ForEach(pending) { record in
                            DownloadRow(record: record) {}
                        }
                    }
                }

                ForEach(groups) { group in
                    section(title: group.title, subtitle: groupSubtitle(group)) {
                        ForEach(group.records) { record in
                            DownloadRow(record: record) {
                                play(record, in: group)
                            }
                        }
                    }
                }

                if downloads.records.isEmpty {
                    EmptyStateView(systemImage: "arrow.down.circle", title: String(localized: "No downloads yet"),
                                   message: String(localized: "Right-click a movie, episode, or video and choose “Download” to watch it offline. Seasons, series, and channels can be downloaded in one go."))
                        .frame(height: 400)
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: app.refreshGeneration) {
            await downloads.refreshUserData()
        }
    }

    private var subtitle: String? {
        let count = downloads.records.values.filter(\.isComplete).count
        guard count > 0 else {
            return nil
        }
        var parts = [String(localized: "\(count) downloaded"), Format.bytes(Double(downloads.usedBytes))]
        if let free = downloads.availableBytes {
            parts.append(String(localized: "\(Format.bytes(Double(free))) free"))
        }
        return parts.joined(separator: " · ")
    }

    private func groupSubtitle(_ group: DownloadGroup) -> String {
        let bytes = group.records.reduce(Int64(0)) { $0 + ($1.fileBytes ?? 0) }
        return "\(group.records.count) · \(Format.bytes(Double(bytes)))"
    }

    private func section(title: String, subtitle: String?, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, Metrics.pagePadding)
            LazyVStack(alignment: .leading, spacing: 6) {
                rows()
            }
            .padding(.horizontal, Metrics.pagePadding - 10)
        }
    }

    /// Up next continues with the following downloads of the same group, so autoplay keeps working offline.
    private func play(_ record: DownloadRecord, in group: DownloadGroup) {
        let index = group.records.firstIndex { $0.id == record.id } ?? 0
        app.play(record.item, queue: group.records[(index + 1)...].map(\.item))
    }
}

private struct DownloadGroup: Identifiable {
    var id: String
    var title: String
    var records: [DownloadRecord]

    static func groups(from records: [DownloadRecord]) -> [DownloadGroup] {
        let grouped = Dictionary(grouping: records) { record in
            record.item.seriesId ?? (record.item.isMovie ? "movies" : "videos")
        }
        return grouped.map { key, records in
            let title: String = switch key {
            case "movies": String(localized: "Movies")
            case "videos": String(localized: "Videos")
            default: records.first?.item.seriesName ?? String(localized: "Series")
            }
            return DownloadGroup(id: key, title: title, records: records.sorted(by: playbackOrder))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func playbackOrder(_ lhs: DownloadRecord, _ rhs: DownloadRecord) -> Bool {
        let a = lhs.item
        let b = rhs.item
        if (a.parentIndexNumber ?? 0, a.indexNumber ?? 0) != (b.parentIndexNumber ?? 0, b.indexNumber ?? 0) {
            return (a.parentIndexNumber ?? 0, a.indexNumber ?? 0) < (b.parentIndexNumber ?? 0, b.indexNumber ?? 0)
        }
        if a.uploadDate != b.uploadDate {
            return (a.uploadDate ?? .distantPast) < (b.uploadDate ?? .distantPast)
        }
        return a.displayName.localizedStandardCompare(b.displayName) == .orderedAscending
    }
}

private struct DownloadRow: View {
    var record: DownloadRecord
    var onPlay: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var item: BaseItem { record.item }

    var body: some View {
        let status = app.downloads.status(of: record.id)
        HStack(spacing: 18) {
            Button(action: onPlay) {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    RemoteImage(url: app.downloads.imageURL(for: record.id, "thumb") ?? app.client?.thumbURL(item, width: 520))
                    if let progress = item.progress {
                        ProgressStrip(progress: progress)
                    }
                    if hovering, status == .completed {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.fill")
                            .font(.system(size: 24))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if item.isPlayed {
                        WatchedBadge()
                            .padding(6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
                .frame(width: 192, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(status != .completed)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                statusLine(status)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            actions(status)
        }
        .padding(10)
        .background(.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .itemContextMenu(item)
    }

    private var detail: String? {
        var parts: [String] = []
        if item.isEpisode {
            if let series = item.seriesName {
                parts.append(series)
            }
            if app.isYouTube(item) {
                if let date = Format.relativeDay(item.uploadDate) {
                    parts.append(date)
                }
            } else if let label = item.episodeLabel {
                parts.append(label)
            }
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusLine(_ status: DownloadStatus?) -> some View {
        switch status {
        case .completed:
            Text(completedSummary)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.tertiaryText)
        case .downloading:
            TransferLine(itemId: record.id)
        case .queued:
            Text("Waiting to download…")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.tertiaryText)
        case let .failed(message):
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(2)
        case nil:
            EmptyView()
        }
    }

    private var completedSummary: String {
        var parts: [String] = []
        if let duration = item.duration {
            parts.append(item.hasResumePosition ? String(localized: "\(Format.duration(duration - item.resumePosition)) left") : Format.duration(duration))
        }
        if let bytes = record.fileBytes {
            parts.append(Format.bytes(Double(bytes)))
        }
        if let fileName = record.fileName {
            parts.append((fileName as NSString).pathExtension.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func actions(_ status: DownloadStatus?) -> some View {
        HStack(spacing: 8) {
            switch status {
            case .completed:
                Button(action: onPlay) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(CircleIconButtonStyle(size: 36))
                .help(item.hasResumePosition ? "Resume" : "Play")
                Button {
                    app.downloads.remove(record.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(CircleIconButtonStyle(size: 36))
                .help("Remove Download")
            case .failed:
                Button {
                    app.downloads.retry(record.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(CircleIconButtonStyle(size: 36))
                .help("Retry")
                cancelButton
            case .queued, .downloading:
                cancelButton
            case nil:
                EmptyView()
            }
        }
    }

    private var cancelButton: some View {
        Button {
            app.downloads.remove(record.id)
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(CircleIconButtonStyle(size: 36))
        .help("Cancel Download")
    }
}

/// Bytes received so far, in its own view so progress ticks don't redraw the whole list.
private struct TransferLine: View {
    var itemId: String

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        let progress = app.downloads.progress(of: itemId)
        VStack(alignment: .leading, spacing: 5) {
            ProgressView(value: progress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(palette.accent)
                .frame(maxWidth: 360)
            Text(label(progress))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.tertiaryText)
        }
    }

    private func label(_ progress: DownloadProgress?) -> String {
        guard let progress, progress.received > 0 else {
            return String(localized: "Preparing…")
        }
        guard let fraction = progress.fraction else {
            return Format.bytes(Double(progress.received))
        }
        return String(localized: "\(Format.bytes(Double(progress.received))) of \(Format.bytes(Double(progress.expected))) · \(Int(fraction * 100))%")
    }
}
