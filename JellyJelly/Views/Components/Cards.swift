import SwiftUI

// MARK: - Hover effect

/// The tvOS-like focus lift: scale, shadow, and an accent ring on hover.
struct HoverLift: ViewModifier {
    var cornerRadius: CGFloat = Metrics.cardCorner
    var scale: CGFloat = 1.035
    @State private var hovering = false
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(palette.accent.opacity(hovering ? 0.9 : 0), lineWidth: 2)
            }
            .scaleEffect(hovering ? scale : 1)
            .shadow(color: .black.opacity(hovering ? 0.5 : 0.25), radius: hovering ? 18 : 6, y: hovering ? 10 : 3)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
            .onHover { hovering = $0 }
            .zIndex(hovering ? 1 : 0)
    }
}

extension View {
    func hoverLift(cornerRadius: CGFloat = Metrics.cardCorner, scale: CGFloat = 1.035) -> some View {
        modifier(HoverLift(cornerRadius: cornerRadius, scale: scale))
    }
}

// MARK: - Building blocks

struct ProgressStrip: View {
    var progress: Double
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.55))
                Rectangle().fill(palette.accent).frame(width: proxy.size.width * progress)
            }
        }
        .frame(height: 4)
    }
}

struct DurationBadge: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

struct WatchedBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(palette.onAccent)
            .frame(width: 22, height: 22)
            .background(palette.accent, in: Circle())
            .shadow(radius: 3)
    }
}

struct CountBadge: View {
    var count: Int
    @Environment(\.palette) private var palette

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(palette.onAccent)
            .padding(.horizontal, 7)
            .frame(minWidth: 22, minHeight: 22)
            .background(palette.accent, in: Capsule())
            .shadow(radius: 3)
    }
}

struct InfoBadge: View {
    var text: String
    var prominent = false
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(prominent ? palette.onAccent : .white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(palette.accent)
                } else {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 1)
                }
            }
    }
}

struct ChannelAvatar: View {
    var url: URL?
    var name: String?
    var size: CGFloat = 36
    @Environment(\.palette) private var palette

    var body: some View {
        RemoteImage(url: url) {
            ZStack {
                palette.surface
                Text(String((name ?? "?").prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

struct SectionHeader: View {
    var title: String
    var subtitle: String?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(palette.text)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.accent)
            }
        }
    }
}

// MARK: - Shelf

struct Shelf<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, subtitle: subtitle)
                .padding(.horizontal, Metrics.pagePadding)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.shelfSpacing) {
                    content()
                }
                .padding(.horizontal, Metrics.pagePadding)
                .padding(.vertical, 12)
            }
            .scrollClipDisabled()
        }
    }
}

// MARK: - Cards

/// A YouTube-style video tile: thumbnail, channel avatar, title, channel, and age.
struct VideoCard: View {
    var item: BaseItem
    var showChannel = true
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .bottomTrailing) {
                    Color.black
                    RemoteImage(url: app.client?.thumbURL(item, width: 720))
                    if let duration = item.duration {
                        DurationBadge(text: Format.time(duration))
                            .padding(8)
                            .padding(.bottom, item.progress == nil ? 0 : 4)
                    }
                    if let progress = item.progress {
                        ProgressStrip(progress: progress)
                    }
                    if item.isPlayed {
                        Color.black.opacity(0.35)
                        WatchedBadge()
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    DownloadBadge(itemId: item.id)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                .hoverLift()
            }
            .buttonStyle(.plain)

            HStack(alignment: .top, spacing: 10) {
                if showChannel {
                    Button {
                        if let channel = app.channel(for: item) {
                            app.open(channel)
                        }
                    } label: {
                        ChannelAvatar(url: app.client?.avatarURL(item), name: item.seriesName, size: 34)
                    }
                    .buttonStyle(.plain)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(metaLine)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .itemContextMenu(item)
    }

    private var metaLine: String {
        var parts: [String] = []
        if showChannel, let channel = item.seriesName {
            parts.append(channel)
        }
        if let age = Format.relativeDay(item.uploadDate) {
            parts.append(age)
        }
        return parts.joined(separator: " · ")
    }
}

/// A 16:9 card for Continue Watching, Next Up, and episode rows.
struct LandscapeCard: View {
    var item: BaseItem
    var width: CGFloat = 320
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    Color.black
                    RemoteImage(url: app.client?.thumbURL(item, width: 640))
                    LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    if let duration = item.duration {
                        let left = item.hasResumePosition ? max(0, duration - item.resumePosition) : duration
                        Text(item.hasResumePosition ? String(localized: "\(Format.duration(left)) left") : Format.duration(duration))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(10)
                            .padding(.bottom, item.progress == nil ? 0 : 4)
                    }
                    if let progress = item.progress {
                        ProgressStrip(progress: progress)
                    }
                    if item.isPlayed {
                        WatchedBadge()
                            .padding(8)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    DownloadBadge(itemId: item.id)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: width, height: width * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                .hoverLift()

                VStack(alignment: .leading, spacing: 2) {
                    Text(primaryTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    if let secondaryTitle {
                        Text(secondaryTitle)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .itemContextMenu(item)
    }

    private var primaryTitle: String {
        if item.isEpisode, !app.isYouTube(item), let series = item.seriesName {
            return series
        }
        return item.displayName
    }

    private var secondaryTitle: String? {
        if item.isEpisode {
            if app.isYouTube(item) {
                return [item.seriesName, Format.relativeDay(item.uploadDate)].compactMap { $0 }.joined(separator: " · ")
            }
            return [item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
        }
        return item.productionYear.map(String.init)
    }
}

/// A 2:3 poster for movies and shows.
struct PosterCard: View {
    var item: BaseItem
    var width: CGFloat = 180
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    RemoteImage(url: app.client?.posterURL(item, width: 400)) {
                        ZStack {
                            palette.surface
                            Text(item.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(palette.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding()
                        }
                    }
                    if item.isPlayed {
                        WatchedBadge().padding(8)
                    } else if item.isSeries, item.unplayedCount > 0 {
                        CountBadge(count: item.unplayedCount).padding(8)
                    }
                    if let progress = item.progress {
                        VStack {
                            Spacer()
                            ProgressStrip(progress: progress)
                        }
                    }
                    DownloadBadge(itemId: item.id)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCorner, style: .continuous))
                .hoverLift()

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                    if let year = item.productionYear {
                        Text(String(year))
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .itemContextMenu(item)
    }
}

/// A round channel tile with an unwatched counter.
struct ChannelTile: View {
    var channel: BaseItem
    var size: CGFloat = 96
    var isSelected = false
    var action: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ChannelAvatar(url: app.client?.avatarURL(channel, width: Int(size * 2)), name: channel.name, size: size)
                        .overlay {
                            Circle().strokeBorder(palette.accent, lineWidth: isSelected || hovering ? 3 : 0)
                        }
                        .scaleEffect(hovering ? 1.06 : 1)
                    if channel.unplayedCount > 0 {
                        CountBadge(count: channel.unplayedCount)
                            .offset(x: 4, y: -2)
                    }
                }
                Text(channel.displayName)
                    .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? palette.accent : palette.secondaryText)
                    .lineLimit(1)
                    .frame(width: size + 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25), value: hovering)
        .itemContextMenu(channel)
    }
}

// MARK: - Buttons

struct AccentButtonStyle: ButtonStyle {
    var prominent = true
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        AccentButtonBody(configuration: configuration, prominent: prominent, palette: palette)
    }

    private struct AccentButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        let palette: Palette
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(prominent ? palette.onAccent : .white)
                .padding(.horizontal, 20)
                .padding(.vertical, 11)
                .background {
                    Capsule().fill(prominent ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.white.opacity(hovering ? 0.22 : 0.14)))
                }
                .overlay {
                    Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.12), lineWidth: 1)
                }
                .brightness(prominent && hovering ? 0.08 : 0)
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.03 : 1))
                .animation(.spring(response: 0.2), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    var size: CGFloat = 42
    var active = false
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.38, weight: .semibold))
            .foregroundStyle(active ? palette.accent : .white)
            .frame(width: size, height: size)
            .background(.white.opacity(configuration.isPressed ? 0.25 : 0.14), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .contentShape(Circle())
    }
}

// MARK: - States

struct LoadingView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        ProgressView()
            .controlSize(.large)
            .tint(palette.accent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    var systemImage: String
    var title: String
    var message: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.accent)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(palette.text)
            if let message {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
