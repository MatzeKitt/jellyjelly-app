import SwiftUI

/// The round download toggle on detail pages: download, cancel, retry, or remove.
struct DownloadButton: View {
    var item: BaseItem
    var size: CGFloat = 42

    @Environment(AppModel.self) private var app
    @State private var confirmingRemoval = false

    var body: some View {
        let status = app.downloads.status(of: item.id)
        Button {
            switch status {
            case nil:
                app.download(item)
            case .queued, .downloading:
                app.downloads.remove(item.id)
            case .failed:
                app.downloads.retry(item.id)
            case .completed:
                confirmingRemoval = true
            }
        } label: {
            switch status {
            case nil:
                Image(systemName: "arrow.down.circle")
            case .queued:
                Image(systemName: "clock")
            case .downloading:
                DownloadProgressRing(itemId: item.id)
                    .frame(width: size * 0.42, height: size * 0.42)
            case .failed:
                Image(systemName: "arrow.clockwise.circle")
            case .completed:
                Image(systemName: "arrow.down.circle.fill")
            }
        }
        .buttonStyle(CircleIconButtonStyle(size: size, active: status == .completed))
        .help(help(for: status))
        .confirmationDialog("Remove the download of “\(item.displayName)”?", isPresented: $confirmingRemoval) {
            Button("Remove Download", role: .destructive) {
                app.downloads.remove(item.id)
            }
        } message: {
            Text("It will no longer be available offline.")
        }
    }

    private func help(for status: DownloadStatus?) -> String {
        switch status {
        case nil: String(localized: "Download for Offline Viewing")
        case .queued: String(localized: "Waiting to Download (click to cancel)")
        case .downloading: String(localized: "Downloading (click to cancel)")
        case let .failed(message): String(localized: "Download failed: \(message) Click to retry.")
        case .completed: String(localized: "Downloaded (click to remove)")
        }
    }
}

/// A download button for a series, season, or channel. Asks before queueing everything.
struct ContainerDownloadButton: View {
    var container: BaseItem
    var title: String
    var fontSize: CGFloat = 14

    @Environment(AppModel.self) private var app

    var body: some View {
        let downloaded = app.downloads.records(in: container).count
        Button {
            app.download(container)
        } label: {
            Label(downloaded > 0 ? String(localized: "\(title) (\(downloaded) Downloaded)") : title, systemImage: "arrow.down.circle")
                .font(.system(size: fontSize, weight: .semibold))
        }
        .buttonStyle(AccentButtonStyle(prominent: false))
    }
}

/// A small marker on cards for items that are downloaded or downloading.
struct DownloadBadge: View {
    var itemId: String

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        switch app.downloads.status(of: itemId) {
        case .completed:
            badge {
                Image(systemName: "arrow.down")
                    .font(.system(size: 10, weight: .heavy))
            }
            .help("Downloaded")
        case .queued, .downloading:
            badge {
                DownloadProgressRing(itemId: itemId, lineWidth: 2)
                    .frame(width: 12, height: 12)
            }
            .help("Downloading")
        case .failed:
            badge {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.orange)
            }
            .help("Download failed")
        case nil:
            EmptyView()
        }
    }

    private func badge(@ViewBuilder content: () -> some View) -> some View {
        content()
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.black.opacity(0.72).shadow(.drop(radius: 3))))
            .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }
}

/// Reads the transfer progress on its own, so only the ring redraws while bytes arrive.
struct DownloadProgressRing: View {
    var itemId: String
    var lineWidth: CGFloat = 2.5

    @Environment(AppModel.self) private var app

    var body: some View {
        ProgressRing(progress: app.downloads.progress(of: itemId)?.fraction ?? 0, lineWidth: lineWidth)
    }
}

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 2.5

    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.25), value: progress)
        }
    }
}
