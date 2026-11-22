import SwiftUI

/// The start page of music: what was played lately, what's new, the playlists, and albums to discover.
struct MusicHomeView: View {
    @Environment(AppModel.self) private var app

    @State private var recentlyPlayed: [BaseItem] = []
    @State private var recentlyAdded: [BaseItem] = []
    @State private var mostPlayed: [BaseItem] = []
    @State private var favoriteSongs: [BaseItem] = []
    @State private var discover: [BaseItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 40) {
                HStack(alignment: .bottom) {
                    PageTitle(title: String(localized: "Listen Now"))
                    Spacer()
                    Button {
                        Task { await shuffleAll() }
                    } label: {
                        Label("Shuffle All", systemImage: "shuffle")
                    }
                    .buttonStyle(AccentButtonStyle())
                    .padding(.trailing, Metrics.pagePadding)
                }

                if !recentlyPlayed.isEmpty {
                    songShelf(String(localized: "Recently Played"), recentlyPlayed)
                }

                if !recentlyAdded.isEmpty {
                    Shelf(title: String(localized: "Recently Added")) {
                        ForEach(recentlyAdded) { album in
                            MusicCard(item: album)
                        }
                    }
                }

                if !app.musicPlaylists.isEmpty {
                    Shelf(title: String(localized: "Playlists")) {
                        ForEach(app.musicPlaylists) { playlist in
                            MusicCard(item: playlist)
                        }
                    }
                }

                if !mostPlayed.isEmpty {
                    songShelf(String(localized: "Most Played"), mostPlayed)
                }

                if !favoriteSongs.isEmpty {
                    songShelf(String(localized: "Favorite Songs"), favoriteSongs)
                }

                if !discover.isEmpty {
                    Shelf(title: String(localized: "Discover"), subtitle: String(localized: "Albums you haven't played yet")) {
                        ForEach(discover) { album in
                            MusicCard(item: album)
                        }
                    }
                }

                if loaded, recentlyPlayed.isEmpty, recentlyAdded.isEmpty, discover.isEmpty {
                    EmptyStateView(systemImage: "music.note.house", title: String(localized: "No music yet"),
                                   message: String(localized: "Add music to a Jellyfin library of the type “Music” and it shows up here."))
                        .frame(height: 360)
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: app.refreshGeneration) {
            await load()
        }
        .onChange(of: app.lastChange) { _, change in
            recentlyPlayed.apply(change)
            recentlyAdded.apply(change)
            mostPlayed.apply(change)
            favoriteSongs.apply(change)
            discover.apply(change)
            if let change, change.userData?.isFavorite == false {
                favoriteSongs.removeAll { $0.id == change.itemId }
            }
        }
    }

    /// Songs as cards; clicking one plays the shelf from there.
    private func songShelf(_ title: String, _ songs: [BaseItem]) -> some View {
        Shelf(title: title) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                MusicCard(item: song, width: 150) {
                    app.music.play(songs, startingAt: index)
                }
            }
        }
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if app.libraries.isEmpty, app.musicLibraries.isEmpty {
            await app.loadLibraries()
        }
        async let played = client.items(songQuery(sortBy: ["DatePlayed"], played: true))
        async let added = client.items(albumQuery(sortBy: ["DateCreated"]))
        async let popular = client.items(songQuery(sortBy: ["PlayCount", "DatePlayed"], played: true))
        async let favorites = client.items(favoritesQuery)
        async let unplayed = client.items(albumQuery(sortBy: ["Random"], unplayed: true))
        recentlyPlayed = (try? await played.items) ?? []
        recentlyAdded = (try? await added.items) ?? []
        mostPlayed = (try? await popular.items) ?? []
        favoriteSongs = (try? await favorites.items) ?? []
        discover = (try? await unplayed.items) ?? []
        loaded = true
    }

    private func songQuery(sortBy: [String], played: Bool) -> ItemQuery {
        var query = ItemQuery()
        query.parentId = app.musicParentId
        query.includeItemTypes = [ItemType.audio]
        query.sortBy = sortBy
        query.sortOrder = Array(repeating: "Descending", count: sortBy.count)
        query.isPlayed = played ? true : nil
        query.limit = 24
        query.enableTotalRecordCount = false
        return query
    }

    private func albumQuery(sortBy: [String], unplayed: Bool = false) -> ItemQuery {
        var query = ItemQuery()
        query.parentId = app.musicParentId
        query.includeItemTypes = [ItemType.musicAlbum]
        query.sortBy = sortBy
        query.sortOrder = Array(repeating: "Descending", count: sortBy.count)
        query.isPlayed = unplayed ? false : nil
        query.limit = 24
        query.enableTotalRecordCount = false
        return query
    }

    private var favoritesQuery: ItemQuery {
        var query = songQuery(sortBy: ["Random"], played: false)
        query.isFavorite = true
        return query
    }

    private func shuffleAll() async {
        guard let client = app.client else {
            return
        }
        var query = ItemQuery()
        query.parentId = app.musicParentId
        query.includeItemTypes = [ItemType.audio]
        query.sortBy = ["Random"]
        query.limit = 300
        query.enableTotalRecordCount = false
        if let songs = try? await client.items(query).items {
            app.music.play(songs, shuffle: true)
        }
    }
}
