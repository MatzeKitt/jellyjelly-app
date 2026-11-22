import SwiftUI

struct AlbumView: View {
    @State var album: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var tracks: [BaseItem] = []
    @State private var moreByArtist: [BaseItem] = []
    @State private var loaded = false

    init(album: BaseItem) {
        _album = State(initialValue: album)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                MusicHeader(kind: String(localized: "Album"), title: album.displayName, artworkURL: app.client?.coverURL(album, width: 800),
                            subtitle: AnyView(artistLink), details: details) {
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
                        app.toggleFavorite(album)
                    } label: {
                        Image(systemName: album.isFavorite ? "heart.fill" : "heart")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 42, active: album.isFavorite))
                    .help(album.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                    MusicDownloadButton(container: album, songs: tracks)

                    Menu {
                        MusicMenuItems(item: album, app: app)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuStyle(.button)
                    .buttonStyle(CircleIconButtonStyle(size: 42))
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if !loaded {
                    LoadingView().frame(height: 240)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        AlbumTrackList(tracks: tracks, albumArtist: album.albumArtist) { index in
                            app.music.play(tracks, startingAt: index)
                        }
                        if let footer {
                            Text(footer)
                                .font(.system(size: 12))
                                .foregroundStyle(palette.tertiaryText)
                                .padding(.horizontal, 12)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, Metrics.pagePadding - 12)
                }

                if let overview = album.overview, !overview.isEmpty {
                    ExpandableText(text: overview, lines: 4)
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(.horizontal, Metrics.pagePadding)
                }

                if !moreByArtist.isEmpty {
                    Shelf(title: String(localized: "More by \(album.albumArtist ?? String(localized: "This Artist"))")) {
                        ForEach(moreByArtist) { other in
                            MusicCard(item: other, subtitle: other.productionYear.map(String.init) ?? "")
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
            if let change, change.itemId == album.id, let data = change.userData {
                album.userData = data
            }
            tracks.apply(change)
        }
    }

    @ViewBuilder
    private var artistLink: some View {
        if let artist = album.primaryArtist {
            Button(album.albumArtist ?? artist.name ?? "") {
                app.openArtist(artist)
            }
            .buttonStyle(.plain)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.accent)
        } else if let name = album.albumArtist {
            Text(name)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.accent)
        }
    }

    private var details: [String] {
        var values: [String] = []
        if let year = album.productionYear {
            values.append(String(year))
        }
        if let genres = album.genres, !genres.isEmpty {
            values.append(genres.prefix(2).joined(separator: ", "))
        }
        if !tracks.isEmpty {
            values.append(String(localized: "\(tracks.count) songs"))
        }
        if let length = tracks.totalDuration {
            values.append(length)
        }
        return values
    }

    private var footer: String? {
        guard let date = album.premiereDate else {
            return nil
        }
        return String(localized: "Released \(date.formatted(date: .long, time: .omitted))")
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if let full = try? await client.item(album.id) {
            album = full
        }
        tracks = (try? await app.songs(of: album)) ?? []
        loaded = true
        if let artistId = album.primaryArtist?.id {
            var query = ItemQuery()
            query.albumArtistIds = [artistId]
            query.includeItemTypes = [ItemType.musicAlbum]
            query.sortBy = ["ProductionYear", "SortName"]
            query.sortOrder = ["Descending", "Ascending"]
            query.limit = 24
            query.enableTotalRecordCount = false
            moreByArtist = ((try? await client.items(query).items) ?? []).filter { $0.id != album.id }
        }
    }
}
