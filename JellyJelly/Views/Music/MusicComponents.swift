import SwiftUI

// MARK: - Artwork

/// Square cover art with a note as placeholder.
struct CoverArt: View {
    var url: URL?
    var cornerRadius: CGFloat = 8
    var systemImage = "music.note"
    @Environment(\.palette) private var palette

    var body: some View {
        // The square sizes the image, so covers that aren't square are cropped instead of widening the card.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: url) {
                    ZStack {
                        LinearGradient(colors: [palette.surface, palette.accentDeep.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: systemImage)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(palette.accent.opacity(0.7))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

/// Animated bars for the song that's playing; still while paused.
struct NowPlayingIndicator: View {
    var isPlaying: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(palette.accent)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: isPlaying)
    }
}

/// The round play button on cards, shown on hover.
struct CardPlayButton: View {
    var size: CGFloat = 40
    var action: () -> Void
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(palette.onAccent)
                .offset(x: size * 0.03)
                .frame(width: size, height: size)
                .background(Circle().fill(palette.accent.shadow(.drop(radius: 6))))
                .scaleEffect(hovering ? 1.1 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.2), value: hovering)
        .help("Play")
    }
}

// MARK: - Cards

/// A square card for albums, playlists, and songs, with a play button on hover.
struct MusicCard: View {
    var item: BaseItem
    var width: CGFloat = 170
    var subtitle: String?
    /// Clicking the artwork; songs play, everything else opens.
    var action: (() -> Void)?

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var placeholderImage: String {
        item.isPlaylist ? "music.note.list" : "music.note"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    if let action {
                        action()
                    } else {
                        app.open(item)
                    }
                } label: {
                    CoverArt(url: app.client?.coverURL(item, width: Int(width * 2)), cornerRadius: Metrics.cardCorner, systemImage: placeholderImage)
                }
                .buttonStyle(.plain)
                if hovering, !item.isAudio {
                    CardPlayButton {
                        app.playMusic(item)
                    }
                    .padding(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .frame(width: width, height: width)
            .hoverLift { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                if let line = subtitle ?? defaultSubtitle {
                    Text(line)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        .itemContextMenu(item)
    }

    private var defaultSubtitle: String? {
        if item.isPlaylist {
            return item.childCount.map { String(localized: "\($0) songs") }
        }
        if item.isAlbum {
            return [item.albumArtist, item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: " · ")
        }
        return item.artistLine
    }
}

/// A round artist tile.
struct ArtistCard: View {
    var artist: BaseItem
    var size: CGFloat = 150

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Button {
                    app.open(artist)
                } label: {
                    ChannelAvatar(url: app.client?.posterURL(artist, width: Int(size * 2)), name: artist.name, size: size)
                        .overlay {
                            Circle().strokeBorder(palette.accent, lineWidth: hovering ? 3 : 0)
                        }
                        .scaleEffect(hovering ? 1.04 : 1)
                }
                .buttonStyle(.plain)
                if hovering {
                    CardPlayButton(size: 36) {
                        app.playMusic(artist, shuffle: true)
                    }
                    .help("Shuffle")
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25), value: hovering)
            Text(artist.displayName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(width: size + 16)
        }
        .itemContextMenu(artist)
    }
}

// MARK: - Track rows

/// A song in a list: number or cover, title and artists, optionally the album, then favorite and length.
/// Double-clicking plays it, like in Music.
struct TrackRow: View {
    var item: BaseItem
    var number: Int?
    var showsArtwork = false
    var showsArtist = true
    var showsAlbum = false
    var onPlay: () -> Void
    /// Extra actions at the end of the context menu, e.g. removing from a playlist.
    var extraMenu: AnyView?

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var isCurrent: Bool { app.music.current?.id == item.id }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                if hovering {
                    Button(action: onPlay) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(palette.text)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else if isCurrent {
                    NowPlayingIndicator(isPlaying: app.music.isPlaying)
                } else if let number {
                    Text("\(number)")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .frame(width: 28)

            if showsArtwork {
                CoverArt(url: app.client?.coverURL(item, width: 96), cornerRadius: 5)
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isCurrent ? palette.accent : palette.text)
                    .lineLimit(1)
                if showsArtist, let artists = item.artistLine {
                    Text(artists)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsAlbum, let album = item.album {
                Button(album) {
                    app.open(item)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
            }

            Button {
                app.toggleFavorite(item)
            } label: {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.isFavorite ? palette.accent : palette.tertiaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(item.isFavorite || hovering ? 1 : 0)
            .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            SongDownloadMark(itemId: item.id)
                .frame(width: 14)

            Text(item.duration.map(Format.time) ?? "")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 48, alignment: .trailing)

            Menu {
                MusicMenuItems(item: item, app: app)
                if let extraMenu {
                    Divider()
                    extraMenu
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .frame(height: showsArtwork ? 54 : 44)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? palette.accent.opacity(0.1) : .white.opacity(hovering ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onPlay)
        .onHover { hovering = $0 }
        .contextMenu {
            MusicMenuItems(item: item, app: app)
            if let extraMenu {
                Divider()
                extraMenu
            }
        }
    }
}

/// A small mark beside songs that are downloaded or downloading.
private struct SongDownloadMark: View {
    var itemId: String

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        switch app.downloads.status(of: itemId) {
        case .completed:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(palette.tertiaryText)
                .help("Downloaded")
        case .queued, .downloading:
            DownloadProgressRing(itemId: itemId, lineWidth: 2)
                .frame(width: 11, height: 11)
                .help("Downloading")
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .help("Download failed")
        case nil:
            EmptyView()
        }
    }
}

/// The download button of an album or playlist page, for all of its songs: download what's missing,
/// cancel while downloading, or remove once everything is downloaded.
struct MusicDownloadButton: View {
    var container: BaseItem
    var songs: [BaseItem]

    @Environment(AppModel.self) private var app
    @State private var confirmingRemoval = false

    var body: some View {
        let statuses = songs.map { app.downloads.status(of: $0.id) }
        let completed = statuses.filter { $0 == .completed }.count
        let pending = statuses.contains { $0 == .queued || $0 == .downloading }
        let isComplete = !songs.isEmpty && completed == songs.count
        Button {
            if isComplete {
                confirmingRemoval = true
            } else if pending {
                for song in songs where [.queued, .downloading].contains(app.downloads.status(of: song.id)) {
                    app.downloads.remove(song.id)
                }
            } else {
                download(statuses)
            }
        } label: {
            if pending {
                ProgressRing(progress: Double(completed) / Double(max(songs.count, 1)))
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: isComplete ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .buttonStyle(CircleIconButtonStyle(size: 42, active: isComplete))
        .disabled(songs.isEmpty)
        .help(help(completed: completed, pending: pending, isComplete: isComplete))
        .confirmationDialog("Remove the downloads of “\(container.displayName)”?", isPresented: $confirmingRemoval) {
            Button("Remove Downloads", role: .destructive) {
                songs.forEach { app.downloads.remove($0.id) }
            }
        } message: {
            Text("The songs will no longer be available offline.")
        }
    }

    /// Asks before downloading songs that aren't downloaded yet; failed ones are simply retried.
    private func download(_ statuses: [DownloadStatus?]) {
        for song in songs {
            if case .failed = app.downloads.status(of: song.id) {
                app.downloads.retry(song.id)
            }
        }
        if statuses.contains(nil) {
            app.download(container)
        }
    }

    private func help(completed: Int, pending: Bool, isComplete: Bool) -> String {
        if isComplete {
            return String(localized: "Downloaded (click to remove)")
        }
        if pending {
            return String(localized: "Downloaded \(completed) of \(songs.count) songs (click to cancel)")
        }
        return String(localized: "Download for Offline Listening")
    }
}

/// Songs grouped by disc, with a heading per disc when an album has several.
struct AlbumTrackList: View {
    var tracks: [BaseItem]
    var albumArtist: String?
    var onPlay: (Int) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        let discs = Dictionary(grouping: tracks.indices) { tracks[$0].parentIndexNumber ?? 1 }
        let numbers = discs.keys.sorted()
        VStack(alignment: .leading, spacing: 2) {
            ForEach(numbers, id: \.self) { disc in
                if numbers.count > 1 {
                    Label("Disc \(disc)", systemImage: "opticaldisc")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(palette.tertiaryText)
                        .padding(.horizontal, 12)
                        .padding(.top, disc == numbers.first ? 0 : 18)
                        .padding(.bottom, 6)
                }
                ForEach(discs[disc] ?? [], id: \.self) { index in
                    let track = tracks[index]
                    // The artists only show where they differ from the album's.
                    TrackRow(item: track, number: track.indexNumber, showsArtist: track.artistLine != albumArtist) {
                        onPlay(index)
                    }
                }
            }
        }
    }
}

// MARK: - Menus

/// Right-click actions for songs, albums, artists, and playlists.
struct MusicMenuItems: View {
    var item: BaseItem
    var app: AppModel

    var body: some View {
        Button {
            app.playMusic(item)
        } label: {
            Label("Play", systemImage: "play.fill")
        }
        if !item.isAudio {
            Button {
                app.playMusic(item, shuffle: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
        }
        Button {
            app.queueMusic(item, next: true)
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            app.queueMusic(item, next: false)
        } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
        AddToPlaylistMenu(items: [item], app: app)
        Button {
            app.startInstantMix(item)
        } label: {
            Label("Start Instant Mix", systemImage: "dot.radiowaves.left.and.right")
        }
        Divider()
        if item.isAudio, item.albumId != nil {
            Button {
                app.open(item)
            } label: {
                Label("Go to Album", systemImage: "square.stack")
            }
        }
        if !item.isArtist, !item.isPlaylist, let artist = item.primaryArtist {
            Button {
                app.openArtist(artist)
            } label: {
                Label("Go to \(artist.name ?? String(localized: "Artist"))", systemImage: "music.mic")
            }
        }
        if !item.isAudio {
            Button {
                app.open(item)
            } label: {
                Label("Show Details", systemImage: "info.circle")
            }
        }
        Button {
            app.toggleFavorite(item)
        } label: {
            Label(item.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: item.isFavorite ? "heart.slash" : "heart")
        }
        DownloadMenuItems(item: item, app: app)
    }
}

/// A submenu of the user's playlists, plus one to put the items into a new playlist.
struct AddToPlaylistMenu: View {
    var items: [BaseItem]
    var app: AppModel

    var body: some View {
        Menu {
            Button {
                app.playlistSheet = .create(adding: items)
            } label: {
                Label("New Playlist…", systemImage: "plus")
            }
            let playlists = app.musicPlaylists.filter { playlist in !items.contains { $0.id == playlist.id } }
            if !playlists.isEmpty {
                Divider()
                ForEach(playlists) { playlist in
                    Button(playlist.displayName) {
                        app.addToPlaylist(playlist, items: items)
                    }
                }
            }
        } label: {
            Label("Add to Playlist", systemImage: "text.badge.plus")
        }
    }
}

// MARK: - Page header

/// The top of an album, artist, or playlist page: artwork beside the title, details, and actions,
/// over a blurred copy of the artwork.
struct MusicHeader<Actions: View>: View {
    var kind: String
    var title: String
    var artworkURL: URL?
    var round = false
    var placeholderImage = "music.note"
    var subtitle: AnyView?
    var details: [String]
    @ViewBuilder var actions: () -> Actions

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .bottom, spacing: 28) {
            Group {
                if round {
                    ChannelAvatar(url: artworkURL, name: title, size: 220)
                } else {
                    CoverArt(url: artworkURL, cornerRadius: 14, systemImage: placeholderImage)
                        .frame(width: 240, height: 240)
                }
            }
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

            VStack(alignment: .leading, spacing: 10) {
                Text(kind.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(palette.accent)
                Text(title)
                    .font(.system(size: 36, weight: .heavy))
                    .foregroundStyle(palette.text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                if let subtitle {
                    subtitle
                }
                if !details.isEmpty {
                    Text(details.joined(separator: "  ·  "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                }
                HStack(spacing: 12) {
                    actions()
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 84)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            RemoteImage(url: artworkURL) { Color.clear }
                .frame(height: 420)
                .frame(maxWidth: .infinity)
                .blur(radius: 70)
                .opacity(0.45)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .clipped()
                .allowsHitTesting(false)
        }
    }
}

extension [BaseItem] {
    /// The total length of the songs, e.g. "1h 12m".
    var totalDuration: String? {
        let seconds = compactMap(\.duration).reduce(0, +)
        return seconds > 0 ? Format.duration(seconds) : nil
    }
}
