import SwiftUI

/// The complete subscription feed with infinite scrolling.
struct SubscriptionsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    @State private var feed = FeedModel(pageSize: 60)
    @State private var inProgress: [BaseItem] = []

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
