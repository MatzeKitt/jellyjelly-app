import SwiftUI

enum MusicSort: String, CaseIterable, Identifiable {
    case name
    case artist
    case album
    case year
    case dateAdded
    case playCount
    case datePlayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Title")
        case .artist: String(localized: "Artist")
        case .album: String(localized: "Album")
        case .year: String(localized: "Year")
        case .dateAdded: String(localized: "Date Added")
        case .playCount: String(localized: "Play Count")
        case .datePlayed: String(localized: "Date Played")
        }
    }

    var sortBy: [String] {
        switch self {
        case .name: ["SortName"]
        case .artist: ["AlbumArtist", "Album", "ParentIndexNumber", "IndexNumber", "SortName"]
        case .album: ["Album", "ParentIndexNumber", "IndexNumber", "SortName"]
        case .year: ["ProductionYear", "PremiereDate", "SortName"]
        case .dateAdded: ["DateCreated", "SortName"]
        case .playCount: ["PlayCount", "SortName"]
        case .datePlayed: ["DatePlayed", "SortName"]
        }
    }

    var defaultDescending: Bool {
        switch self {
        case .name, .artist, .album: false
        default: true
        }
    }

    static func options(for section: MusicSection) -> [MusicSort] {
        switch section {
        case .albums: [.name, .artist, .year, .dateAdded, .datePlayed]
        case .songs: [.name, .artist, .album, .dateAdded, .playCount, .datePlayed]
        default: [.name, .dateAdded]
        }
    }
}

/// All albums, artists, songs, or playlists, with sorting, a favorites filter, and an A–Z index.
struct MusicBrowseView: View {
    var section: MusicSection

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var sort = MusicSort.name
    @State private var descending = false
    @State private var favoritesOnly = false
    @State private var filterText = ""
    @State private var letters: [String] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    if !loaded {
                        LoadingView().frame(height: 300)
                    } else if items.isEmpty {
                        emptyState
                    } else {
                        content
                        if loading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        }
                    }
                }
                .padding(.bottom, 60)
            }
            .scrollIndicators(.never)
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .trailing) {
                if letters.count > 3 {
                    LetterIndex(letters: letters) { letter in
                        if let target = items.first(where: { $0.indexLetter == letter }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .task(id: reloadKey) {
            await load(reset: true)
        }
        .onChange(of: app.lastChange) { _, change in
            items.apply(change)
        }
    }

    private var reloadKey: String {
        "\(section.rawValue)|\(sort.rawValue)|\(descending)|\(favoritesOnly)|\(filterText)|\(app.refreshGeneration)|\(app.playlistGeneration)"
    }

    private var subtitle: String? {
        guard total > 0 else {
            return nil
        }
        switch section {
        case .albums: return String(localized: "\(total) albums")
        case .artists: return String(localized: "\(total) artists")
        case .songs: return String(localized: "\(total) songs")
        case .playlists: return String(localized: "\(total) playlists")
        case .listenNow: return nil
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: section.title, subtitle: subtitle)
            HStack(spacing: 10) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(MusicSort.options(for: section)) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Picker("Order", selection: $descending) {
                        Text("Ascending").tag(false)
                        Text("Descending").tag(true)
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterChip(title: sort.title, systemImage: "arrow.up.arrow.down", active: false)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .onChange(of: sort) { _, value in
                    descending = value.defaultDescending
                }

                Button {
                    favoritesOnly.toggle()
                } label: {
                    FilterChip(title: String(localized: "Favorites"), systemImage: "heart", active: favoritesOnly)
                }
                .buttonStyle(.plain)

                if section == .playlists {
                    Button {
                        app.playlistSheet = .create(adding: [])
                    } label: {
                        FilterChip(title: String(localized: "New Playlist"), systemImage: "plus", active: false)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await shuffleLibrary() }
                    } label: {
                        FilterChip(title: String(localized: "Shuffle"), systemImage: "shuffle", active: false)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(palette.tertiaryText)
                    TextField("Filter", text: $filterText)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                }
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(.white.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if section == .playlists, !favoritesOnly, filterText.isEmpty {
            EmptyStateView(systemImage: "music.note.list", title: String(localized: "No playlists yet"),
                           message: String(localized: "Create one with “New Playlist”, or right-click any song or album and choose “Add to Playlist”."))
                .frame(height: 320)
        } else {
            EmptyStateView(systemImage: "music.note", title: String(localized: "Nothing to show"), message: String(localized: "Try a different filter."))
                .frame(height: 320)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch section {
        case .artists:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 20, alignment: .top)], spacing: 28) {
                ForEach(items) { artist in
                    ArtistCard(artist: artist, size: 150)
                        .id(artist.id)
                        .onAppear { loadMoreIfNeeded(artist) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.trailing, 24)
        case .songs:
            LazyVStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, song in
                    TrackRow(item: song, showsArtwork: true, showsAlbum: true) {
                        app.music.play(items, startingAt: index)
                    }
                    .id(song.id)
                    .onAppear { loadMoreIfNeeded(song) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding - 12)
            .padding(.trailing, 24)
        default:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                ForEach(items) { item in
                    MusicCard(item: item)
                        .id(item.id)
                        .onAppear { loadMoreIfNeeded(item) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.trailing, 24)
        }
    }

    // MARK: - Loading

    private func query(startIndex: Int) -> ItemQuery {
        var query = ItemQuery()
        switch section {
        case .albums:
            query.parentId = app.musicParentId
            query.includeItemTypes = [ItemType.musicAlbum]
        case .songs:
            query.parentId = app.musicParentId
            query.includeItemTypes = [ItemType.audio]
        case .playlists:
            query.includeItemTypes = [ItemType.playlist]
            query.fields.append("CanDelete")
        case .artists, .listenNow:
            query.parentId = app.musicParentId
        }
        query.sortBy = sort.sortBy
        if sort == .name {
            query.fields.append("SortName")
        }
        query.sortOrder = Array(repeating: descending ? "Descending" : "Ascending", count: sort.sortBy.count)
        if favoritesOnly {
            query.isFavorite = true
        }
        query.searchTerm = filterText.count >= 2 ? filterText : nil
        query.startIndex = startIndex
        query.limit = section == .songs ? 300 : 150
        return query
    }

    private func load(reset: Bool) async {
        guard let client = app.client else {
            return
        }
        loading = true
        defer { loading = false }
        let start = reset ? 0 : items.count
        let query = query(startIndex: start)
        let result = section == .artists ? try? await client.albumArtists(query) : try? await client.items(query)
        guard var response = result else {
            loaded = true
            return
        }
        if section == .playlists {
            response.items = response.items.filter(\.isMusic)
        }
        if reset {
            items = response.items
        } else {
            items += response.items
        }
        total = response.totalRecordCount ?? items.count
        letters = sort == .name ? items.reduce(into: []) { seen, item in
            if !seen.contains(item.indexLetter) {
                seen.append(item.indexLetter)
            }
        } : []
        loaded = true
    }

    private func loadMoreIfNeeded(_ item: BaseItem) {
        guard !loading, items.count < total, items.suffix(60).contains(where: { $0.id == item.id }) else {
            return
        }
        Task { await load(reset: false) }
    }

    /// Plays random songs from the library, or from the favorites while that filter is on.
    private func shuffleLibrary() async {
        guard let client = app.client else {
            return
        }
        var query = ItemQuery()
        query.parentId = app.musicParentId
        query.includeItemTypes = [ItemType.audio]
        query.sortBy = ["Random"]
        query.isFavorite = favoritesOnly ? true : nil
        query.limit = 300
        query.enableTotalRecordCount = false
        if let songs = try? await client.items(query).items {
            app.music.play(songs, shuffle: true)
        }
    }
}
