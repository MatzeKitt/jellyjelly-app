import SwiftUI

/// Right-click actions, the Mac counterpart of JellyGoose's long-press menu.
struct ItemContextMenu: ViewModifier {
    var item: BaseItem
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content.contextMenu {
            if item.isPlayable || item.isSeries || item.isSeason {
                Button {
                    app.play(item)
                } label: {
                    Label(item.hasResumePosition ? "Resume from \(Format.time(item.resumePosition))" : "Play", systemImage: "play.fill")
                }
                if item.hasResumePosition {
                    Button {
                        app.play(item, mode: .beginning)
                    } label: {
                        Label("Play from Beginning", systemImage: "backward.end.fill")
                    }
                }
            }
            Button {
                app.open(item)
            } label: {
                Label("Show Details", systemImage: "info.circle")
            }
            if let channel = app.channel(for: item) {
                Button {
                    app.open(channel)
                } label: {
                    Label("Go to \(channel.displayName)", systemImage: "person.crop.circle")
                }
            } else if item.isEpisode, let seriesId = item.seriesId {
                Button {
                    app.open(BaseItem(id: seriesId, name: item.seriesName, type: ItemType.series))
                } label: {
                    Label("Go to Series", systemImage: "tv")
                }
            }
            Divider()
            Button {
                app.togglePlayed(item)
            } label: {
                if item.isPlayed {
                    Label("Mark as Unwatched", systemImage: "eye.slash")
                } else {
                    Label(item.isSeries || item.isSeason ? "Mark All as Watched" : "Mark as Watched", systemImage: "checkmark.circle")
                }
            }
            Button {
                app.toggleFavorite(item)
            } label: {
                Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
            if item.hasResumePosition {
                Button {
                    app.removeFromContinueWatching(item)
                } label: {
                    Label("Remove from Continue Watching", systemImage: "xmark.circle")
                }
            }
            downloadActions
        }
    }

    @ViewBuilder
    private var downloadActions: some View {
        if item.isPlayable {
            Divider()
            switch app.downloads.status(of: item.id) {
            case nil:
                Button {
                    app.download(item)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            case .queued, .downloading:
                Button {
                    app.downloads.remove(item.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .failed:
                Button {
                    app.downloads.retry(item.id)
                } label: {
                    Label("Retry Download", systemImage: "arrow.clockwise")
                }
                Button {
                    app.downloads.remove(item.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            case .completed:
                Button(role: .destructive) {
                    app.downloads.remove(item.id)
                } label: {
                    Label("Remove Download", systemImage: "trash")
                }
            }
        } else if item.isSeries || item.isSeason || item.type == ItemType.boxSet || item.type == ItemType.folder {
            Divider()
            Button {
                app.download(item)
            } label: {
                Label(containerDownloadTitle + "…", systemImage: "arrow.down.circle")
            }
            let downloaded = app.downloads.records(in: item).count
            if downloaded > 0 {
                Button(role: .destructive) {
                    app.removeDownload(item)
                } label: {
                    Label(downloaded == 1 ? "Remove 1 Download" : "Remove \(downloaded) Downloads", systemImage: "trash")
                }
            }
        }
    }

    private var containerDownloadTitle: String {
        if item.isSeason {
            return String(localized: "Download Season")
        }
        if item.isSeries {
            return app.isYouTube(item) ? String(localized: "Download Videos") : String(localized: "Download Series")
        }
        return String(localized: "Download All")
    }
}

extension View {
    func itemContextMenu(_ item: BaseItem) -> some View {
        modifier(ItemContextMenu(item: item))
    }
}

extension Array where Element == BaseItem {
    /// Applies a broadcast user-data change to a local copy of a list.
    mutating func apply(_ change: ItemChange?) {
        guard let change, let index = firstIndex(where: { $0.id == change.itemId }) else {
            return
        }
        self[index].userData = change.userData ?? self[index].userData
    }
}
