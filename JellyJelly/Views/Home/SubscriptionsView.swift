import SwiftUI

/// The complete subscription feed with infinite scrolling.
struct SubscriptionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var feed = FeedModel(pageSize: 60)
    @State private var inProgress: [BaseItem] = []
    @State private var recentlyWatched: [BaseItem] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 36) {
                PageTitle(title: String(localized: "Subscriptions"), subtitle: String(localized: "\(app.channels.count) channels"))

                if !inProgress.isEmpty {
                    Shelf(title: String(localized: "Keep Watching")) {
                        ForEach(inProgress) { item in
                            LandscapeCard(item: item, width: 300) {
                                app.play(item)
                            }
                        }
                    }
                }

                FeedSection(feed: feed, limit: nil)

                if !recentlyWatched.isEmpty {
                    Shelf(title: String(localized: "Recently Watched")) {
                        ForEach(recentlyWatched) { item in
                            LandscapeCard(item: item, width: 300) {
                                app.play(item)
                            }
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
            feed.apply(change, includeWatched: app.settings.feedIncludeWatched)
            inProgress.apply(change)
            recentlyWatched.apply(change)
        }
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        await feed.reload(app, keepCount: feed.hasLoaded)
        var resume: [BaseItem] = []
        for library in app.youTubeLibraries {
            resume += (try? await client.resumeItems(limit: 20, parentId: library.id)) ?? []
        }
        inProgress = resume
        recentlyWatched = await loadRecentlyWatched(client)
    }

    /// The videos played last across all YouTube libraries, whether finished or not.
    private func loadRecentlyWatched(_ client: JellyfinClient) async -> [BaseItem] {
        var query = ItemQuery()
        query.includeItemTypes = [ItemType.episode, ItemType.video]
        query.sortBy = ["DatePlayed"]
        query.sortOrder = ["Descending"]
        query.limit = 20
        query.enableTotalRecordCount = false
        var items: [BaseItem] = []
        // `parentId` takes a single ID, so several libraries are fetched and merged.
        for library in app.youTubeLibraries {
            query.parentId = library.id
            items += (try? await client.items(query).items) ?? []
        }
        // Videos never played sort last and only show up where fewer than 20 videos were played.
        return Array(items
            .filter { $0.userData?.lastPlayedDate != nil }
            .sorted { ($0.userData?.lastPlayedDate ?? .distantPast) > ($1.userData?.lastPlayedDate ?? .distantPast) }
            .prefix(20))
    }
}

struct PageTitle: View {
    var title: String
    var subtitle: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 34, weight: .heavy))
                .foregroundStyle(palette.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, 52)
    }
}
