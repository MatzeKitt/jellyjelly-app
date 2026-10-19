import SwiftUI

/// Details for a playable item: a movie, an episode, or a video.
struct ItemDetailView: View {
    @State var item: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var related: [BaseItem] = []

    init(item: BaseItem) {
        _item = State(initialValue: item)
    }

    private var isYouTube: Bool { app.isYouTube(item) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                BackdropHeader(imageURL: isYouTube ? app.client?.thumbURL(item, width: 1920) : (app.client?.backdropURL(item) ?? app.client?.thumbURL(item, width: 1920))) {
                    heroContent
                }

                if let overview = item.overview, !overview.isEmpty {
                    ExpandableText(text: overview, lines: 4)
                        .frame(maxWidth: 820, alignment: .leading)
                        .padding(.horizontal, Metrics.pagePadding)
                }

                credits

                if !related.isEmpty {
                    if isYouTube {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: item.seriesName.map { String(localized: "More from \($0)") } ?? String(localized: "More from this channel"))
                                .padding(.horizontal, Metrics.pagePadding)
                            VideoGrid(items: related, showChannel: false) { video in
                                app.play(video)
                            }
                        }
                    } else {
                        Shelf(title: item.isEpisode ? (item.seasonName ?? String(localized: "More Episodes")) : String(localized: "More Like This")) {
                            ForEach(related) { other in
                                if other.isEpisode {
                                    LandscapeCard(item: other) { app.open(other) }
                                } else {
                                    PosterCard(item: other) { app.open(other) }
                                }
                            }
                        }
                    }
                }

                if let people = item.people, !people.isEmpty, !isYouTube {
                    CastRow(people: people)
                }

                MediaInfoSection(item: item)
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: app.refreshGeneration) {
            await load()
        }
        .onChange(of: app.lastChange) { _, change in
            if let change, change.itemId == item.id, let data = change.userData {
                item.userData = data
            }
            related.apply(change)
        }
    }

    private var heroContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isYouTube {
                Button {
                    if let channel = app.channel(for: item) {
                        app.open(channel)
                    }
                } label: {
                    HStack(spacing: 10) {
                        ChannelAvatar(url: app.client?.avatarURL(item), name: item.seriesName, size: 34)
                        Text(item.seriesName ?? "")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
            } else if let logo = app.client?.logoURL(item) {
                RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                    .frame(maxWidth: 380, maxHeight: 110, alignment: .leading)
            } else if item.isEpisode, let series = item.seriesName {
                Text(series)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }

            Text(item.displayName)
                .font(.system(size: 38, weight: .heavy))
                .lineLimit(3)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: 820, alignment: .leading)

            HStack(spacing: 12) {
                Text(metadata.joined(separator: "  ·  "))
                if let rating = item.communityRating {
                    Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                }
                if let critic = item.criticRating {
                    Label("\(Int(critic))%", systemImage: "rosette")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.secondaryText)

            MediaBadges(item: item)

            HStack(spacing: 12) {
                Button {
                    app.play(item, queue: queueAfterItem, mode: item.hasResumePosition ? .resume : .beginning)
                } label: {
                    Label(item.hasResumePosition ? "Resume \(Format.time(item.resumePosition))" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(AccentButtonStyle())

                if item.hasResumePosition {
                    Button {
                        app.play(item, queue: queueAfterItem, mode: .beginning)
                    } label: {
                        Label("Start Over", systemImage: "backward.end.fill")
                    }
                    .buttonStyle(AccentButtonStyle(prominent: false))
                }

                Button {
                    app.togglePlayed(item)
                } label: {
                    Image(systemName: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(CircleIconButtonStyle(size: 42, active: item.isPlayed))
                .help(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")

                Button {
                    app.toggleFavorite(item)
                } label: {
                    Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(CircleIconButtonStyle(size: 42, active: item.isFavorite))
                .help(item.isFavorite ? "Remove from Favorites" : "Add to Favorites")

                DownloadButton(item: item)
            }
            .padding(.top, 6)

            if let progress = item.progress {
                ProgressStrip(progress: progress)
                    .frame(width: 260)
                    .clipShape(Capsule())
            }
        }
    }

    private var metadata: [String] {
        var values: [String] = []
        if isYouTube {
            if let date = item.uploadDate {
                values.append(date.formatted(date: .long, time: .omitted))
            }
        } else {
            if let label = item.episodeLabel {
                values.append(label)
            }
            if let year = item.productionYear {
                values.append(String(year))
            }
            if let rating = item.officialRating {
                values.append(rating)
            }
        }
        if let duration = item.duration {
            values.append(Format.duration(duration))
            let remaining = item.hasResumePosition ? duration - item.resumePosition : duration
            let end = Date.now.addingTimeInterval(remaining)
            values.append(String(localized: "Ends at \(end.formatted(date: .omitted, time: .shortened))"))
        }
        return values
    }

    @ViewBuilder
    private var credits: some View {
        let directors = (item.people ?? []).filter { $0.type == "Director" }.compactMap(\.name)
        let studios = (item.studios ?? []).compactMap(\.name)
        let genres = item.genres ?? []
        if !isYouTube, !(directors.isEmpty && studios.isEmpty && genres.isEmpty) {
            VStack(alignment: .leading, spacing: 8) {
                if !genres.isEmpty {
                    creditRow(String(localized: "Genres"), genres.joined(separator: ", "))
                }
                if !directors.isEmpty {
                    creditRow(String(localized: "Director"), directors.joined(separator: ", "))
                }
                if !studios.isEmpty {
                    creditRow(String(localized: "Studio"), studios.joined(separator: ", "))
                }
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    private func creditRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var queueAfterItem: [BaseItem] {
        guard let index = related.firstIndex(where: { $0.id == item.id }) else {
            return []
        }
        return Array(related[(index + 1)...])
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if let full = try? await client.item(item.id) {
            item = full
        }
        if isYouTube, let seriesId = item.seriesId {
            var query = ItemQuery()
            query.parentId = seriesId
            query.includeItemTypes = [ItemType.episode, ItemType.video]
            query.sortBy = app.settings.feedOrder.sortBy
            query.sortOrder = Array(repeating: "Descending", count: query.sortBy.count)
            query.excludeItemTypes = []
            query.limit = 24
            related = ((try? await client.items(query).items) ?? []).filter { $0.id != item.id }
        } else if item.isEpisode, let seriesId = item.seriesId {
            related = (try? await client.episodes(seriesId: seriesId, seasonId: item.seasonId)) ?? []
        } else {
            var query = ItemQuery()
            query.includeItemTypes = [ItemType.movie]
            query.genres = Array((item.genres ?? []).prefix(1))
            query.sortBy = ["Random"]
            query.limit = 20
            related = ((try? await client.items(query).items) ?? []).filter { $0.id != item.id }
        }
    }
}
