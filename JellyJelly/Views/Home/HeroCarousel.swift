import SwiftUI

/// The full-bleed spotlight at the top of Home, cycling through the newest videos.
struct HeroCarousel: View {
    var items: [BaseItem]
    var queue: [BaseItem] = []

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var index = 0
    @State private var hovering = false

    private var item: BaseItem? {
        items.isEmpty ? nil : items[min(index, items.count - 1)]
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let item {
                artwork(for: item)
                    .id(item.id)
                    .transition(.opacity)
                scrims
                details(for: item)
                    .id("details-\(item.id)")
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
            pager
        }
        .frame(height: 560)
        .frame(maxWidth: .infinity)
        .clipped()
        .onHover { hovering = $0 }
        .task(id: items.map(\.id)) {
            index = min(index, max(0, items.count - 1))
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(9))
                if !hovering, items.count > 1, app.player == nil {
                    withAnimation(.easeInOut(duration: 0.6)) {
                        index = (index + 1) % items.count
                    }
                }
            }
        }
    }

    private func artwork(for item: BaseItem) -> some View {
        GeometryReader { proxy in
            // Videos show their own thumbnail rather than the channel banner.
            RemoteImage(url: app.isYouTube(item)
                ? app.client?.thumbURL(item, width: 1920)
                : app.client?.backdropURL(item) ?? app.client?.thumbURL(item, width: 1920))
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
        }
        // Fade into whatever is behind, so there's no seam with the page gradient.
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(colors: [palette.backgroundTop.opacity(0.95), palette.backgroundTop.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .init(x: 0.75, y: 0.5))
            LinearGradient(colors: [.black.opacity(0.35), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2))
        }
        .allowsHitTesting(false)
    }

    private func details(for item: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if app.isYouTube(item) {
                Button {
                    if let channel = app.channel(for: item) {
                        app.open(channel)
                    }
                } label: {
                    HStack(spacing: 10) {
                        ChannelAvatar(url: app.client?.avatarURL(item), name: item.seriesName, size: 30)
                        Text(item.seriesName ?? "")
                            .font(.system(size: 15, weight: .semibold))
                        Text("NEW")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(1)
                            .foregroundStyle(palette.onAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(palette.accent, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                .buttonStyle(.plain)
            } else if let logo = app.client?.logoURL(item) {
                RemoteImage(url: logo, contentMode: .fit) { Color.clear }
                    .frame(maxWidth: 420, maxHeight: 130, alignment: .leading)
            }

            if !(app.client?.logoURL(item) != nil && !app.isYouTube(item)) {
                Text(item.displayName)
                    .font(.system(size: 40, weight: .heavy))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.5), radius: 12)
            }

            Text(metadata(for: item).joined(separator: "  ·  "))
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.secondaryText)

            if let overview = item.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(3)
                    .frame(maxWidth: 620, alignment: .leading)
            }

            HStack(spacing: 12) {
                Button {
                    if item.isPlayable {
                        let start = queue.firstIndex { $0.id == item.id }
                        app.play(item, queue: start.map { Array(queue[($0 + 1)...].prefix(50)) } ?? [])
                    } else {
                        app.open(item)
                    }
                } label: {
                    Label(item.hasResumePosition ? "Resume" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(AccentButtonStyle())

                Button {
                    app.open(item)
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .buttonStyle(AccentButtonStyle(prominent: false))

                if item.isPlayable {
                    Button {
                        app.togglePlayed(item)
                    } label: {
                        Image(systemName: item.isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                    }
                    .buttonStyle(CircleIconButtonStyle(size: 42, active: item.isPlayed))
                    .help(item.isPlayed ? "Mark as Unwatched" : "Mark as Watched")
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, Metrics.pagePadding + 8)
        .padding(.bottom, 64)
        .frame(maxWidth: 760, alignment: .leading)
    }

    private func metadata(for item: BaseItem) -> [String] {
        var values: [String] = []
        if app.isYouTube(item) {
            if let age = Format.relativeDay(item.uploadDate) {
                values.append(age)
            }
        } else if let year = item.productionYear {
            values.append(String(year))
        }
        if let rating = item.officialRating {
            values.append(rating)
        }
        if let duration = item.duration {
            values.append(Format.duration(duration))
        }
        if item.isSeries, let count = item.childCount {
            values.append(String(localized: "\(count) Seasons"))
        }
        return values
    }

    private var pager: some View {
        HStack(spacing: 8) {
            ForEach(items.indices, id: \.self) { position in
                Capsule()
                    .fill(position == index ? palette.accent : .white.opacity(0.3))
                    .frame(width: position == index ? 26 : 8, height: 8)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            index = position
                        }
                    }
            }
        }
        .padding(.horizontal, Metrics.pagePadding + 8)
        .padding(.bottom, 28)
        .opacity(items.count > 1 ? 1 : 0)
        .animation(.spring(response: 0.3), value: index)
    }
}
