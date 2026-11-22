import SwiftUI

struct ArtistView: View {
    @State var artist: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var topSongs: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var appearsOn: [BaseItem] = []
    @State private var loaded = false

    init(artist: BaseItem) {
        _artist = State(initialValue: artist)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                MusicHeader(kind: String(localized: "Artist"), title: artist.displayName,
                            artworkURL: app.client.map { $0.posterURL(artist, width: 600) ?? $0.artistImageURL(artist.id, width: 600) },
                            round: true, details: details) {
                    Button {
                        app.playMusic(artist)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                    .buttonStyle(AccentButtonStyle())

                    Button {
                        app.playMusic(artist, shuffle: true)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))

                    Button {
                        app.startInstantMix(artist)
                    } label: {
                        Label("Instant Mix", systemImage: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))

                    Button {
                        app.toggleFavorite(artist)
                    } label: {
                        Image(systemName: artist.isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 42, active: artist.isFavorite))
                    .help(artist.isFavorite ? "Remove from Favorites" : "Add to Favorites")
                }

                if let overview = artist.overview, !overview.isEmpty {
                    ExpandableText(text: overview, lines: 3)
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(.horizontal, Metrics.pagePadding)
                }

                if !loaded {
                    LoadingView().frame(height: 240)
                }

                if !topSongs.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: String(localized: "Top Songs"))
                            .padding(.horizontal, Metrics.pagePadding)
                        VStack(spacing: 2) {
                            ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
                                TrackRow(item: song, number: index + 1, showsArtwork: true, showsArtist: false, showsAlbum: true) {
                                    app.music.play(topSongs, startingAt: index)
                                }
                            }
                        }
                        .padding(.horizontal, Metrics.pagePadding - 12)
                    }
                }

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: String(localized: "Albums"), subtitle: "\(albums.count)")
                            .padding(.horizontal, Metrics.pagePadding)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                            ForEach(albums) { album in
                                MusicCard(item: album, subtitle: album.productionYear.map(String.init) ?? "")
                            }
                        }
                        .padding(.horizontal, Metrics.pagePadding)
                    }
                }

                if !appearsOn.isEmpty {
                    Shelf(title: String(localized: "Appears On")) {
                        ForEach(appearsOn) { album in
                            MusicCard(item: album)
                        }
                    }
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
            if let change, change.itemId == artist.id, let data = change.userData {
                artist.userData = data
            }
            topSongs.apply(change)
            albums.apply(change)
            appearsOn.apply(change)
        }
    }

    private var details: [String] {
        var values: [String] = []
        if !albums.isEmpty {
            values.append(albums.count == 1 ? String(localized: "1 album") : String(localized: "\(albums.count) albums"))
        }
        if let genres = artist.genres, !genres.isEmpty {
            values.append(genres.prefix(3).joined(separator: ", "))
        }
        return values
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if let full = try? await client.item(artist.id) {
            artist = full
        }
        async let own = client.items(albumQuery(albumArtist: true))
        async let featured = client.items(albumQuery(albumArtist: false))
        async let popular = client.items(topSongsQuery)
        albums = (try? await own.items) ?? []
        let ownIds = Set(albums.map(\.id))
        appearsOn = ((try? await featured.items) ?? []).filter { !ownIds.contains($0.id) }
        topSongs = (try? await popular.items) ?? []
        loaded = true
    }

    private func albumQuery(albumArtist: Bool) -> ItemQuery {
        var query = ItemQuery()
        if albumArtist {
            query.albumArtistIds = [artist.id]
        } else {
            query.artistIds = [artist.id]
        }
        query.includeItemTypes = [ItemType.musicAlbum]
        query.sortBy = ["ProductionYear", "PremiereDate", "SortName"]
        query.sortOrder = ["Descending", "Descending", "Ascending"]
        query.enableTotalRecordCount = false
        return query
    }

    /// Jellyfin has no charts, so the most played songs stand in for the top songs.
    private var topSongsQuery: ItemQuery {
        var query = ItemQuery()
        query.artistIds = [artist.id]
        query.includeItemTypes = [ItemType.audio]
        query.sortBy = ["PlayCount", "CommunityRating", "SortName"]
        query.sortOrder = ["Descending", "Descending", "Ascending"]
        query.limit = 10
        query.enableTotalRecordCount = false
        return query
    }
}
