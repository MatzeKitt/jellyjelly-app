import SwiftUI

enum LibrarySort: String, CaseIterable, Identifiable {
    case name
    case dateAdded
    case releaseDate
    case datePlayed
    case rating
    case criticRating
    case runtime
    case latestUpload

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: String(localized: "Title")
        case .dateAdded: String(localized: "Date Added")
        case .releaseDate: String(localized: "Release Date")
        case .datePlayed: String(localized: "Date Played")
        case .rating: String(localized: "Rating")
        case .criticRating: String(localized: "Critics' Score")
        case .runtime: String(localized: "Runtime")
        case .latestUpload: String(localized: "Latest Upload")
        }
    }

    var sortBy: [String] {
        switch self {
        case .name: ["SortName"]
        case .dateAdded: ["DateCreated", "SortName"]
        case .releaseDate: ["PremiereDate", "ProductionYear", "SortName"]
        case .datePlayed: ["DatePlayed", "SortName"]
        case .rating: ["CommunityRating", "SortName"]
        case .criticRating: ["CriticRating", "SortName"]
        case .runtime: ["Runtime", "SortName"]
        case .latestUpload: ["DateLastContentAdded", "SortName"]
        }
    }

    var defaultDescending: Bool { self != .name }
}

struct LibraryView: View {
    var library: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var items: [BaseItem] = []
    @State private var total = 0
    @State private var loading = false
    @State private var loaded = false
    @State private var sort = LibrarySort.name
    @State private var descending = false
    @State private var unwatchedOnly = false
    @State private var favoritesOnly = false
    @State private var genres: [String] = []
    @State private var selectedGenres: Set<String> = []
    @State private var filterText = ""
    @State private var letters: [String] = []

    private var isYouTube: Bool { app.isYouTubeLibrary(library.id) }
    private var isFolderView: Bool {
        let type = library.collectionType ?? ""
        return !["movies", "tvshows", "boxsets"].contains(type) && !isYouTube
    }

    private var itemTypes: [String] {
        switch library.collectionType {
        case "movies": [ItemType.movie]
        case "tvshows": [ItemType.series]
        case "boxsets": [ItemType.boxSet]
        default: []
        }
    }

    /// Updated after loading rather than computed, so re-rendering the page doesn't walk every loaded item.
    private func updateLetters() {
        guard sort == .name else {
            letters = []
            return
        }
        var seen: [String] = []
        for item in items {
            let letter = indexLetter(item)
            if seen.last != letter {
                seen.append(letter)
            }
        }
        letters = seen
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    if !loaded {
                        LoadingView().frame(height: 300)
                    } else if items.isEmpty {
                        EmptyStateView(systemImage: "tray", title: String(localized: "Nothing to show"), message: String(localized: "Try a different filter."))
                            .frame(height: 320)
                    } else {
                        grid
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
                        if let target = items.first(where: { indexLetter($0) == letter }) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(target.id, anchor: .top)
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .onAppear {
            if isYouTube, !loaded {
                sort = .latestUpload
                descending = true
            }
        }
        .task(id: reloadKey) {
            await load(reset: true)
        }
        .task(id: library.id) {
            if !isFolderView, let client = app.client {
                genres = ((try? await client.genres(parentId: library.id)) ?? []).compactMap(\.name)
            }
        }
        .onChange(of: app.lastChange) { _, change in
            items.apply(change)
        }
    }

    private var reloadKey: String {
        "\(library.id)|\(sort.rawValue)|\(descending)|\(unwatchedOnly)|\(favoritesOnly)|\(selectedGenres.sorted())|\(filterText)|\(app.refreshGeneration)"
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            PageTitle(title: library.displayName, subtitle: total > 0
                ? (isYouTube ? String(localized: "\(total) channels") : String(localized: "\(total) items"))
                : nil)
            HStack(spacing: 10) {
                Menu {
                    Picker("Sort By", selection: $sort) {
                        ForEach(LibrarySort.allCases.filter { isYouTube || $0 != .latestUpload }) { option in
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
                    unwatchedOnly.toggle()
                } label: {
                    FilterChip(title: String(localized: "Unwatched"), systemImage: "eye.slash", active: unwatchedOnly)
                }
                .buttonStyle(.plain)

                Button {
                    favoritesOnly.toggle()
                } label: {
                    FilterChip(title: String(localized: "Favorites"), systemImage: "heart", active: favoritesOnly)
                }
                .buttonStyle(.plain)

                if !genres.isEmpty {
                    Menu {
                        ForEach(genres, id: \.self) { genre in
                            Toggle(genre, isOn: Binding(
                                get: { selectedGenres.contains(genre) },
                                set: { on in
                                    if on {
                                        selectedGenres.insert(genre)
                                    } else {
                                        selectedGenres.remove(genre)
                                    }
                                }
                            ))
                        }
                        if !selectedGenres.isEmpty {
                            Divider()
                            Button("Clear Genres") { selectedGenres = [] }
                        }
                    } label: {
                        FilterChip(title: selectedGenres.isEmpty ? String(localized: "Genres") : String(localized: "\(selectedGenres.count) Genres"), systemImage: "theatermasks", active: !selectedGenres.isEmpty)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                if !isFolderView {
                    Button {
                        Task { await playRandom() }
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

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        if isYouTube {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 180), spacing: 20)], spacing: 28) {
                ForEach(items) { channel in
                    ChannelTile(channel: channel, size: 128) { app.open(channel) }
                        .id(channel.id)
                        .onAppear { loadMoreIfNeeded(channel) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        } else if isFolderView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 360), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                ForEach(items) { item in
                    LandscapeCard(item: item, width: 300) {
                        if item.isPlayable {
                            app.play(item)
                        } else {
                            app.open(item)
                        }
                    }
                    .id(item.id)
                    .onAppear { loadMoreIfNeeded(item) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 200), spacing: 22, alignment: .top)], alignment: .leading, spacing: 26) {
                ForEach(items) { item in
                    PosterCard(item: item, width: 170) { app.open(item) }
                        .id(item.id)
                        .onAppear { loadMoreIfNeeded(item) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.trailing, 24)
        }
    }

    private func indexLetter(_ item: BaseItem) -> String {
        guard let first = (item.displayName.uppercased()).first else {
            return "#"
        }
        return first.isLetter ? String(first) : "#"
    }

    // MARK: - Loading

    private func query(startIndex: Int) -> ItemQuery {
        var query = ItemQuery()
        query.parentId = library.id
        if isYouTube {
            query.includeItemTypes = [ItemType.series]
        } else if isFolderView {
            query.recursive = false
        } else {
            query.includeItemTypes = itemTypes
        }
        query.sortBy = sort.sortBy
        query.sortOrder = Array(repeating: descending ? "Descending" : "Ascending", count: sort.sortBy.count)
        if unwatchedOnly {
            query.isPlayed = false
        }
        if favoritesOnly {
            query.isFavorite = true
        }
        query.genres = Array(selectedGenres)
        query.searchTerm = filterText.count >= 2 ? filterText : nil
        query.startIndex = startIndex
        query.limit = 150
        return query
    }

    private func load(reset: Bool) async {
        guard let client = app.client else {
            return
        }
        loading = true
        defer { loading = false }
        let start = reset ? 0 : items.count
        guard let response = try? await client.items(query(startIndex: start)) else {
            loaded = true
            return
        }
        if reset {
            items = response.items
        } else {
            items += response.items
        }
        updateLetters()
        total = response.totalRecordCount ?? items.count
        loaded = true
    }

    private func loadMoreIfNeeded(_ item: BaseItem) {
        // Only the tail is searched, as this runs for every cell that scrolls into view. The next page is
        // requested about ten rows ahead, so fast scrolling doesn't run into the end of the list.
        guard !loading, items.count < total, items.suffix(60).contains(where: { $0.id == item.id }) else {
            return
        }
        Task { await load(reset: false) }
    }

    private func playRandom() async {
        guard let client = app.client else {
            return
        }
        var query = ItemQuery()
        query.parentId = library.id
        query.includeItemTypes = isYouTube || library.collectionType == "tvshows" ? [ItemType.episode] : [ItemType.movie, ItemType.video]
        query.sortBy = ["Random"]
        query.isPlayed = false
        query.limit = 50
        query.enableTotalRecordCount = false
        if let items = try? await client.items(query).items, let first = items.first {
            app.play(first, queue: Array(items.dropFirst()))
        }
    }
}

struct FilterChip: View {
    var title: String
    var systemImage: String
    var active: Bool
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(active ? palette.onAccent : palette.text)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(active ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.white.opacity(hovering ? 0.14 : 0.08)), in: Capsule())
            .contentShape(Capsule())
            .onHover { hovering = $0 }
    }
}

private struct LetterIndex: View {
    var letters: [String]
    var onSelect: (String) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 1) {
            ForEach(letters, id: \.self) { letter in
                Button {
                    onSelect(letter)
                } label: {
                    Text(letter)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 18, height: 15)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
        .background(.black.opacity(0.25), in: Capsule())
    }
}
