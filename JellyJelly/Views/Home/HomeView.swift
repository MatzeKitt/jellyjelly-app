import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var feed = FeedModel(pageSize: 24)
    @State private var continueWatching: [BaseItem] = []
    @State private var nextUp: [BaseItem] = []
    @State private var latest: [(library: BaseItem, items: [BaseItem])] = []
    @State private var heroFallback: [BaseItem] = []
    @State private var loaded = false

    private var heroItems: [BaseItem] {
        let fromFeed = feed.items.filter { !$0.isPlayed }.prefix(6)
        return fromFeed.isEmpty ? Array(heroFallback.prefix(6)) : Array(fromFeed)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 44) {
                if !heroItems.isEmpty {
                    HeroCarousel(items: heroItems, queue: feed.items)
                } else {
                    Color.clear.frame(height: 60)
                }

                if !continueWatching.isEmpty {
                    Shelf(title: String(localized: "Continue Watching")) {
                        ForEach(continueWatching) { item in
                            LandscapeCard(item: item) {
                                app.play(item)
                            }
                        }
                    }
                }

                if app.hasYouTube {
                    FeedSection(feed: feed, limit: 24)
                }

                if !nextUp.isEmpty {
                    Shelf(title: String(localized: "Next Up")) {
                        ForEach(nextUp) { item in
                            LandscapeCard(item: item) {
                                app.play(item, queue: [])
                            }
                        }
                    }
                }

                ForEach(latest, id: \.library.id) { entry in
                    Shelf(title: String(localized: "Recently Added"), subtitle: entry.library.displayName) {
                        ForEach(entry.items) { item in
                            if entry.library.collectionType == "movies" || entry.library.collectionType == "tvshows" {
                                PosterCard(item: item) { app.open(item) }
                            } else {
                                LandscapeCard(item: item, width: 300) { app.open(item) }
                            }
                        }
                    }
                }

                if loaded && heroItems.isEmpty && continueWatching.isEmpty && feed.items.isEmpty && latest.isEmpty {
                    EmptyStateView(systemImage: "sparkles.tv", title: String(localized: "Nothing here yet"),
                                   message: String(localized: "Add some media to your Jellyfin libraries and it will show up here."))
                        .frame(height: 400)
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
            feed.apply(change, includeWatched: app.settings.feedIncludeWatched)
            continueWatching.apply(change)
            if let change, change.userData?.playbackPositionTicks == 0 || change.userData?.played == true {
                continueWatching.removeAll { $0.id == change.itemId }
            }
            nextUp.apply(change)
        }
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if app.libraries.isEmpty {
            await app.loadLibraries()
        }
        async let feedLoad: Void = feed.reload(app, keepCount: loaded)
        async let resume = client.resumeItems(limit: 20)
        async let upNext = client.nextUp(limit: 24)

        let hideYouTube = app.settings.hideYouTubeFromShelves
        nextUp = ((try? await upNext) ?? []).filter { !(hideYouTube && app.isYouTube($0)) }
        continueWatching = (try? await resume) ?? []
        await feedLoad

        var shelves: [(BaseItem, [BaseItem])] = []
        for library in app.libraries where !(hideYouTube && app.isYouTubeLibrary(library.id)) {
            if let items = try? await client.latest(parentId: library.id, limit: 20), !items.isEmpty {
                shelves.append((library, items))
            }
        }
        latest = shelves.map { (library: $0.0, items: $0.1) }
        if !app.hasYouTube {
            heroFallback = shelves.flatMap(\.1).filter { client.backdropURL($0) != nil }
        }
        loaded = true
    }
}

// MARK: - Feed

/// The subscription feed: a channel strip and a grid of the newest unwatched videos.
struct FeedSection: View {
    var feed: FeedModel
    /// Shows at most this many videos with a link to the full feed; nil shows all with paging.
    var limit: Int?

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    private var visible: [BaseItem] {
        limit.map { Array(feed.items.prefix($0)) } ?? feed.items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: String(localized: "New from Your Channels"), subtitle: feed.total > 0 ? String(localized: "\(feed.total) unwatched") : nil)
                Spacer()
                FeedOrderMenu {
                    Task { await feed.reload(app) }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)

            ChannelStrip(selection: Binding(
                get: { feed.channelFilter },
                set: { value in
                    feed.channelFilter = value
                    Task { await feed.reload(app) }
                }
            ))

            if feed.items.isEmpty {
                if feed.hasLoaded {
                    EmptyStateView(systemImage: "checkmark.seal", title: String(localized: "You're all caught up"),
                                   message: feed.channelFilter == nil
                                       ? String(localized: "There are no unwatched videos in your channels.")
                                       : String(localized: "No unwatched videos from this channel."))
                        .frame(height: 260)
                } else {
                    LoadingView().frame(height: 260)
                }
            } else {
                VideoGrid(items: visible) { item in
                    play(item)
                } onReachEnd: {
                    if limit == nil {
                        Task { await feed.loadMore(app) }
                    }
                }

                if let limit, feed.total > limit {
                    Button {
                        app.section = .subscriptions
                    } label: {
                        Label("Show All \(feed.total) Videos", systemImage: "arrow.right")
                            .labelStyle(TrailingIconLabelStyle())
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                    .frame(maxWidth: .infinity)
                } else if limit == nil, feed.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
        }
    }

    private func play(_ item: BaseItem) {
        guard let index = feed.items.firstIndex(where: { $0.id == item.id }) else {
            app.play(item)
            return
        }
        // Up next continues down the feed.
        app.play(item, queue: Array(feed.items[(index + 1)...].prefix(50)))
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
        }
    }
}

struct FeedOrderMenu: View {
    var onChange: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var settings = app.settings
        Menu {
            Picker("Sort By", selection: $settings.feedOrder) {
                ForEach(FeedOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            Picker("Order", selection: $settings.feedOldestFirst) {
                Text("Newest First").tag(false)
                Text("Oldest First").tag(true)
            }
            Divider()
            Toggle("Include Watched Videos", isOn: $settings.feedIncludeWatched)
        } label: {
            Label(app.settings.feedOldestFirst ? "Oldest First" : "Newest First", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .onChange(of: app.settings.feedOrder) { onChange() }
        .onChange(of: app.settings.feedOldestFirst) { onChange() }
        .onChange(of: app.settings.feedIncludeWatched) { onChange() }
    }
}

/// Channel avatars to filter the feed, ordered by most recent upload.
struct ChannelStrip: View {
    @Binding var selection: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                AllChannelsTile(isSelected: selection == nil) {
                    selection = nil
                }
                ForEach(app.channels) { channel in
                    ChannelTile(channel: channel, size: 64, isSelected: selection == channel.id) {
                        selection = selection == channel.id ? nil : channel.id
                    }
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
            .padding(.vertical, 6)
        }
        .scrollClipDisabled()
    }
}

private struct AllChannelsTile: View {
    var isSelected: Bool
    var action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? palette.onAccent : palette.accent)
                    .frame(width: 64, height: 64)
                    .background(isSelected ? AnyShapeStyle(palette.accent) : AnyShapeStyle(palette.surface), in: Circle())
                Text("All")
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? palette.accent : palette.secondaryText)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
    }
}

struct VideoGrid: View {
    var items: [BaseItem]
    var showChannel = true
    var onPlay: (BaseItem) -> Void
    var onReachEnd: () -> Void = {}

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 290, maximum: 440), spacing: 22, alignment: .top)], alignment: .leading, spacing: 30) {
            ForEach(items) { item in
                VideoCard(item: item, showChannel: showChannel) {
                    onPlay(item)
                }
                .onAppear {
                    if item.id == items.last?.id {
                        onReachEnd()
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }
}
