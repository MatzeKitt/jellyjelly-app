import SwiftUI

struct SeriesView: View {
    @State var series: BaseItem

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeason: String?
    @State private var episodes: [BaseItem] = []
    @State private var nextUp: BaseItem?

    init(series: BaseItem) {
        _series = State(initialValue: series)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                BackdropHeader(imageURL: app.client?.backdropURL(series), height: 600) {
                    hero
                }

                if !seasons.isEmpty {
                    seasonPicker
                }

                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(episodes) { episode in
                        EpisodeRow(episode: episode) {
                            let index = episodes.firstIndex { $0.id == episode.id } ?? 0
                            app.play(episode, queue: Array(episodes[(index + 1)...]))
                        }
                    }
                }
                .padding(.horizontal, Metrics.pagePadding)

                if let people = series.people, !people.isEmpty {
                    CastRow(people: people)
                }
            }
            .padding(.bottom, 60)
        }
        .scrollIndicators(.never)
        .ignoresSafeArea(edges: .top)
        .task(id: app.refreshGeneration) {
            await load()
        }
        .task(id: selectedSeason) {
            await loadEpisodes()
        }
        .onChange(of: app.lastChange) { _, change in
            episodes.apply(change)
            seasons.apply(change)
            if let change, change.itemId == series.id, let data = change.userData {
                series.userData = data
            }
        }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let logo = app.client?.logoURL(series) {
                RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                    .frame(maxWidth: 420, maxHeight: 130, alignment: .leading)
            } else {
                Text(series.displayName)
                    .font(.system(size: 42, weight: .heavy))
            }
            HStack(spacing: 12) {
                if let year = series.productionYear {
                    Text(String(year))
                }
                if let rating = series.officialRating {
                    Text(rating)
                }
                if let count = series.childCount {
                    Text("\(count) Seasons")
                }
                if let status = series.status {
                    Text(status == "Continuing" ? "Continuing" : "Ended")
                }
                if let rating = series.communityRating {
                    Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                }
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.secondaryText)

            if let overview = series.overview {
                ExpandableText(text: overview, lines: 3)
                    .frame(maxWidth: 700, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    if let nextUp {
                        let index = episodes.firstIndex { $0.id == nextUp.id }
                        app.play(nextUp, queue: index.map { Array(episodes[($0 + 1)...]) } ?? [])
                    } else {
                        app.play(series)
                    }
                } label: {
                    Label(playTitle, systemImage: "play.fill")
                }
                .buttonStyle(AccentButtonStyle())

                Button {
                    app.togglePlayed(series)
                } label: {
                    Image(systemName: series.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(CircleIconButtonStyle(size: 42, active: series.isPlayed))
                .help(series.isPlayed ? "Mark Series as Unwatched" : "Mark Series as Watched")

                Button {
                    app.toggleFavorite(series)
                } label: {
                    Image(systemName: series.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(CircleIconButtonStyle(size: 42, active: series.isFavorite))

                Button {
                    app.download(series)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(CircleIconButtonStyle(size: 42))
                .help("Download Series…")
            }
        }
    }

    private var playTitle: String {
        guard let nextUp else {
            return String(localized: "Play")
        }
        guard let label = nextUp.episodeLabel else {
            return nextUp.hasResumePosition ? String(localized: "Resume") : String(localized: "Play")
        }
        return nextUp.hasResumePosition
            ? String(localized: "Resume \(label)", comment: "Resume the episode with this season/episode label")
            : String(localized: "Play \(label)", comment: "Play the episode with this season/episode label")
    }

    private var seasonPicker: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasons) { season in
                        Button {
                            selectedSeason = season.id
                        } label: {
                            HStack(spacing: 6) {
                                Text(season.displayName)
                                if season.isPlayed {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .heavy))
                                }
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selectedSeason == season.id ? palette.onAccent : palette.text)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(selectedSeason == season.id ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.white.opacity(0.08)), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .itemContextMenu(season)
                    }
                }
            }
            if let season = seasons.first(where: { $0.id == selectedSeason }) {
                Button {
                    app.togglePlayed(season)
                } label: {
                    Label(season.isPlayed ? "Mark Season Unwatched" : "Mark Season Watched", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(AccentButtonStyle(prominent: false))

                ContainerDownloadButton(container: season, title: String(localized: "Download Season"), fontSize: 12)
            }
        }
        .padding(.horizontal, Metrics.pagePadding)
    }

    private func load() async {
        guard let client = app.client else {
            return
        }
        if let full = try? await client.item(series.id) {
            series = full
        }
        seasons = (try? await client.seasons(seriesId: series.id)) ?? []
        nextUp = try? await client.nextUp(limit: 1, seriesId: series.id).first
        if selectedSeason == nil || !seasons.contains(where: { $0.id == selectedSeason }) {
            selectedSeason = nextUp?.seasonId ?? seasons.first { !$0.isPlayed }?.id ?? seasons.first?.id
        } else {
            await loadEpisodes()
        }
    }

    private func loadEpisodes() async {
        guard let client = app.client, let selectedSeason else {
            return
        }
        episodes = (try? await client.episodes(seriesId: series.id, seasonId: selectedSeason)) ?? []
    }
}

struct EpisodeRow: View {
    var episode: BaseItem
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 20) {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    RemoteImage(url: app.client?.thumbURL(episode, width: 520))
                    if let progress = episode.progress {
                        ProgressStrip(progress: progress)
                    }
                    if hovering {
                        Color.black.opacity(0.35)
                        Image(systemName: "play.fill")
                            .font(.system(size: 28))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if episode.isPlayed {
                        WatchedBadge()
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    DownloadBadge(itemId: episode.id)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: 260, height: 146)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if let index = episode.indexNumber {
                            Text("\(index)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(palette.accent)
                        }
                        Text(episode.displayName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                    }
                    HStack(spacing: 10) {
                        if let duration = episode.duration {
                            Text(Format.duration(duration))
                        }
                        if let date = episode.premiereDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.tertiaryText)
                    if let overview = episode.overview {
                        Text(overview)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .padding(10)
            .background(.white.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .itemContextMenu(episode)
    }
}
