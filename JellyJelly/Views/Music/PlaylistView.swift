import SwiftUI

struct PlaylistView: View {
    @State var playlist: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var tracks: [BaseItem] = []
    @State private var loaded = false
    @State private var confirmingDelete = false

    init(playlist: BaseItem) {
        _playlist = State(initialValue: playlist)
    }

    var body: some View {
        // A list rather than a stack, for reordering songs by dragging them.
        List {
            header
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .padding(.bottom, 24)

            if !loaded {
                LoadingView()
                    .frame(height: 240)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else if tracks.isEmpty {
                EmptyStateView(systemImage: "music.note.list", title: String(localized: "This playlist is empty"),
                               message: String(localized: "Right-click a song, album, or artist and choose “Add to Playlist”."))
                    .frame(height: 280)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            ForEach(Array(tracks.enumerated()), id: \.element.entryKey) { index, track in
                TrackRow(item: track, number: index + 1, showsArtwork: true, showsAlbum: true, onPlay: {
                    app.music.play(tracks, startingAt: index)
                }, extraMenu: AnyView(
                    Button(role: .destructive) {
                        remove(track)
                    } label: {
                        Label("Remove from Playlist", systemImage: "minus.circle")
                    }
                ))
                .listRowInsets(EdgeInsets(top: 1, leading: Metrics.pagePadding - 12, bottom: 1, trailing: Metrics.pagePadding - 12))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onMove(perform: move)

            Color.clear
                .frame(height: 40)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: "\(app.refreshGeneration)|\(app.playlistGeneration)") {
            await load()
        }
        .onChange(of: app.lastChange) { _, change in
            if let change, change.itemId == playlist.id, let data = change.userData {
                playlist.userData = data
            }
            tracks.apply(change)
        }
        .confirmationDialog("Delete “\(playlist.displayName)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                app.deletePlaylist(playlist)
            }
        } message: {
            Text("The playlist is deleted on the server for every device. Its songs stay in your library.")
        }
    }

    private var header: some View {
        MusicHeader(kind: String(localized: "Playlist"), title: playlist.displayName, artworkURL: app.client?.coverURL(playlist, width: 800),
                    placeholderImage: "music.note.list", details: details) {
            Button {
                app.music.play(tracks, shuffle: false)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(tracks.isEmpty)

            Button {
                app.music.play(tracks, shuffle: true)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
            }
            .buttonStyle(AccentButtonStyle(prominent: false))
            .disabled(tracks.isEmpty)

            Button {
                app.toggleFavorite(playlist)
            } label: {
                Image(systemName: playlist.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(CircleIconButtonStyle(size: 42, active: playlist.isFavorite))
            .help(playlist.isFavorite ? "Remove from Favorites" : "Add to Favorites")

            Menu {
                Button {
                    app.music.playNext(tracks)
                } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button {
                    app.music.addToQueue(tracks)
                } label: {
                    Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                Button {
                    app.startInstantMix(playlist)
                } label: {
                    Label("Start Instant Mix", systemImage: "dot.radiowaves.left.and.right")
                }
                Divider()
                Button {
                    app.playlistSheet = .edit(playlist)
                } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                if playlist.canDelete != false {
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete Playlist…", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(CircleIconButtonStyle(size: 42))
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var details: [String] {
        var values: [String] = []
        if loaded {
            values.append(tracks.count == 1 ? String(localized: "1 song") : String(localized: "\(tracks.count) songs"))
        }
        if let length = tracks.totalDuration {
            values.append(length)
        }
        return values
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if let full = try? await client.item(playlist.id) {
            playlist = full
        }
        tracks = (try? await client.playlistItems(playlist.id)) ?? []
        loaded = true
    }

    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first, let entryId = tracks[from].playlistItemId, let client = app.client else {
            return
        }
        tracks.move(fromOffsets: source, toOffset: destination)
        // The server counts the new index after taking the song out.
        let newIndex = destination > from ? destination - 1 : destination
        Task {
            do {
                try await client.movePlaylistItem(playlist.id, entryId: entryId, to: newIndex)
            } catch {
                app.errorMessage = error.localizedDescription
                await load()
            }
        }
    }

    private func remove(_ track: BaseItem) {
        guard let entryId = track.playlistItemId, let client = app.client else {
            return
        }
        tracks.removeAll { $0.playlistItemId == entryId }
        Task {
            do {
                try await client.removeFromPlaylist(playlist.id, entryIds: [entryId])
            } catch {
                app.errorMessage = error.localizedDescription
                await load()
            }
        }
    }
}

private extension BaseItem {
    /// Unique per entry, since a playlist can hold the same song twice.
    var entryKey: String { playlistItemId ?? id }
}
