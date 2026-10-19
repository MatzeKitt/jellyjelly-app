import SwiftUI

/// A YouTube channel (a Jellyfin series): banner, avatar, and its uploads as a video grid.
struct ChannelView: View {
    @State var channel: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var videos: [BaseItem] = []
    @State private var total = 0
    @State private var unwatchedOnly = false
    @State private var oldestFirst = false
    @State private var loading = false

    init(channel: BaseItem) {
        _channel = State(initialValue: channel)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                banner
                header
                controls
                if videos.isEmpty && !loading {
                    EmptyStateView(systemImage: "play.slash", title: unwatchedOnly ? String(localized: "All caught up") : String(localized: "No videos"),
                                   message: unwatchedOnly ? String(localized: "You've watched everything from this channel.") : nil)
                        .frame(height: 260)
                } else {
                    VideoGrid(items: videos, showChannel: false) { video in
                        let index = videos.firstIndex { $0.id == video.id } ?? 0
                        app.play(video, queue: Array(videos[(index + 1)...].prefix(50)))
                    } onReachEnd: {
                        Task { await load(reset: false) }
                    }
                }
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: "\(unwatchedOnly)|\(oldestFirst)|\(app.refreshGeneration)") {
            await load(reset: true)
        }
        .task(id: channel.id) {
            if let full = try? await app.client?.item(channel.id) {
                channel = full
            }
        }
        .onChange(of: app.lastChange) { _, change in
            videos.apply(change)
            if unwatchedOnly, let change, change.userData?.played == true {
                videos.removeAll { $0.id == change.itemId }
            }
            if let change, change.itemId == channel.id, let data = change.userData {
                channel.userData = data
            }
        }
    }

    private var banner: some View {
        ZStack {
            if let url = app.client?.backdropURL(channel, width: 2560) {
                GeometryReader { proxy in
                    RemoteImage(url: url)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else {
                // No banner: a blurred, enlarged avatar makes a soft color field.
                GeometryReader { proxy in
                    RemoteImage(url: app.client?.avatarURL(channel, width: 200)) { palette.surface }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 60)
                        .opacity(0.7)
                        .clipped()
                }
            }
            LinearGradient(colors: [.clear, palette.backgroundTop], startPoint: .center, endPoint: .bottom)
        }
        .frame(height: 260)
        .clipped()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 24) {
            ChannelAvatar(url: app.client?.avatarURL(channel, width: 300), name: channel.name, size: 120)
                .overlay(Circle().strokeBorder(palette.backgroundTop, lineWidth: 4))
                .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 8) {
                Text(channel.displayName)
                    .font(.system(size: 34, weight: .heavy))
                HStack(spacing: 12) {
                    if let count = channel.recursiveItemCount {
                        Text("\(count) videos")
                    }
                    if channel.unplayedCount > 0 {
                        Text("\(channel.unplayedCount) unwatched")
                            .foregroundStyle(palette.accent)
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.secondaryText)
                if let overview = channel.overview, !overview.isEmpty {
                    ExpandableText(text: overview, lines: 2)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Metrics.pagePadding)
        .padding(.top, -80)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                app.play(channel)
            } label: {
                Label("Play Oldest Unwatched", systemImage: "play.fill")
            }
            .buttonStyle(AccentButtonStyle())

            Button {
                app.togglePlayed(channel)
            } label: {
                Label(channel.isPlayed ? "Mark All Unwatched" : "Mark All Watched", systemImage: "checkmark.circle")
            }
            .buttonStyle(AccentButtonStyle(prominent: false))

            Button {
                app.toggleFavorite(channel)
            } label: {
                Image(systemName: channel.isFavorite ? "heart.fill" : "heart")
            }
            .buttonStyle(CircleIconButtonStyle(size: 42, active: channel.isFavorite))

            ContainerDownloadButton(container: channel, title: String(localized: "Download"))

            Spacer()

            Button {
                unwatchedOnly.toggle()
            } label: {
                FilterChip(title: String(localized: "Unwatched"), systemImage: "eye.slash", active: unwatchedOnly)
            }
            .buttonStyle(.plain)

            Button {
                oldestFirst.toggle()
            } label: {
                FilterChip(title: oldestFirst ? String(localized: "Oldest First") : String(localized: "Newest First"), systemImage: "arrow.up.arrow.down", active: false)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private func load(reset: Bool) async {
        guard let client = app.client, reset || (!loading && videos.count < total) else {
            return
        }
        loading = true
        defer { loading = false }
        var query = ItemQuery()
        query.parentId = channel.id
        query.includeItemTypes = [ItemType.episode, ItemType.video]
        query.sortBy = app.settings.feedOrder.sortBy
        query.sortOrder = Array(repeating: oldestFirst ? "Ascending" : "Descending", count: query.sortBy.count)
        query.isPlayed = unwatchedOnly ? false : nil
        query.startIndex = reset ? 0 : videos.count
        query.limit = 60
        query.fields = ["Overview", "PrimaryImageAspectRatio", "DateCreated"]
        guard let response = try? await client.items(query) else {
            return
        }
        videos = reset ? response.items : videos + response.items
        total = response.totalRecordCount ?? videos.count
    }
}
