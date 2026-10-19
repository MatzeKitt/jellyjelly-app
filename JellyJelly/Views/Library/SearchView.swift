import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var searching = false
    @FocusState private var focused: Bool

    private func group(_ predicate: (BaseItem) -> Bool) -> [BaseItem] {
        results.filter(predicate)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                VStack(alignment: .leading, spacing: 18) {
                    PageTitle(title: String(localized: "Search"))
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(palette.accent)
                        TextField("Videos, channels, movies, shows…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 20, weight: .medium))
                            .focused($focused)
                        if searching {
                            ProgressView().controlSize(.small)
                        } else if !query.isEmpty {
                            Button {
                                query = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(palette.tertiaryText)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .background(palette.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(palette.accent.opacity(focused ? 0.7 : 0.1), lineWidth: 1.5))
                    .padding(.horizontal, Metrics.pagePadding)
                }

                let channels = group { $0.isSeries && app.isYouTube($0) }
                if !channels.isEmpty {
                    Shelf(title: String(localized: "Channels")) {
                        ForEach(channels) { channel in
                            ChannelTile(channel: channel, size: 96) { app.open(channel) }
                        }
                    }
                }

                let videos = group { $0.isEpisode && app.isYouTube($0) }
                if !videos.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: String(localized: "Videos")).padding(.horizontal, Metrics.pagePadding)
                        VideoGrid(items: videos) { app.play($0) }
                    }
                }

                let movies = group { $0.isMovie }
                if !movies.isEmpty {
                    Shelf(title: String(localized: "Movies")) {
                        ForEach(movies) { item in PosterCard(item: item) { app.open(item) } }
                    }
                }

                let shows = group { $0.isSeries && !app.isYouTube($0) }
                if !shows.isEmpty {
                    Shelf(title: String(localized: "Shows")) {
                        ForEach(shows) { item in PosterCard(item: item) { app.open(item) } }
                    }
                }

                let episodes = group { ($0.isEpisode || $0.type == ItemType.video) && !app.isYouTube($0) }
                if !episodes.isEmpty {
                    Shelf(title: String(localized: "Episodes")) {
                        ForEach(episodes) { item in LandscapeCard(item: item) { app.open(item) } }
                    }
                }

                if !query.isEmpty, !searching, results.isEmpty {
                    EmptyStateView(systemImage: "magnifyingglass", title: String(localized: "No results"), message: String(localized: "Nothing matches “\(query)”."))
                        .frame(height: 300)
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .onAppear { focused = true }
        .task(id: query) {
            await search()
        }
        .onChange(of: app.lastChange) { _, change in
            results.apply(change)
        }
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespaces)
        guard term.count >= 2, let client = app.client else {
            results = []
            return
        }
        // Debounce typing.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else {
            return
        }
        searching = true
        defer { searching = false }
        var query = ItemQuery()
        query.searchTerm = term
        query.includeItemTypes = [ItemType.movie, ItemType.series, ItemType.episode, ItemType.video]
        query.sortBy = ["SortName"]
        query.limit = 120
        query.enableTotalRecordCount = false
        if let response = try? await client.items(query), !Task.isCancelled {
            results = response.items
        }
    }
}

struct FavoritesView: View {
    @Environment(AppModel.self) private var app

    @State private var items: [BaseItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                PageTitle(title: String(localized: "Favorites"))

                let channels = items.filter { $0.isSeries && app.isYouTube($0) }
                if !channels.isEmpty {
                    Shelf(title: String(localized: "Channels")) {
                        ForEach(channels) { channel in
                            ChannelTile(channel: channel, size: 96) { app.open(channel) }
                        }
                    }
                }
                let videos = items.filter { $0.isEpisode && app.isYouTube($0) }
                if !videos.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: String(localized: "Videos")).padding(.horizontal, Metrics.pagePadding)
                        VideoGrid(items: videos) { app.play($0) }
                    }
                }
                let movies = items.filter(\.isMovie)
                if !movies.isEmpty {
                    Shelf(title: String(localized: "Movies")) {
                        ForEach(movies) { item in PosterCard(item: item) { app.open(item) } }
                    }
                }
                let shows = items.filter { $0.isSeries && !app.isYouTube($0) }
                if !shows.isEmpty {
                    Shelf(title: String(localized: "Shows")) {
                        ForEach(shows) { item in PosterCard(item: item) { app.open(item) } }
                    }
                }
                let episodes = items.filter { ($0.isEpisode || $0.type == ItemType.video) && !app.isYouTube($0) }
                if !episodes.isEmpty {
                    Shelf(title: String(localized: "Episodes")) {
                        ForEach(episodes) { item in LandscapeCard(item: item) { app.open(item) } }
                    }
                }
                if loaded && items.isEmpty {
                    EmptyStateView(systemImage: "heart", title: String(localized: "No favorites yet"),
                                   message: String(localized: "Right-click any video, channel, movie, or show and choose “Add to Favorites”."))
                        .frame(height: 400)
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: app.refreshGeneration) {
            guard let client = app.client else {
                return
            }
            var query = ItemQuery()
            query.isFavorite = true
            query.includeItemTypes = [ItemType.movie, ItemType.series, ItemType.episode, ItemType.video]
            query.sortBy = ["SortName"]
            query.limit = 500
            items = (try? await client.items(query).items) ?? []
            loaded = true
        }
        .onChange(of: app.lastChange) { _, change in
            items.apply(change)
            if let change, change.userData?.isFavorite == false {
                items.removeAll { $0.id == change.itemId }
            }
        }
    }
}
