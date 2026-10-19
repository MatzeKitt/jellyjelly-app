import SwiftUI

/// A full-width backdrop that fades into the page background.
struct BackdropHeader<Content: View>: View {
    var imageURL: URL?
    var height: CGFloat = 560
    @ViewBuilder var content: () -> Content

    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                RemoteImage(url: imageURL) { palette.surface.opacity(0.4) }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.5), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            LinearGradient(colors: [palette.backgroundTop.opacity(0.95), palette.backgroundTop.opacity(0.5), .clear],
                           startPoint: .leading, endPoint: .init(x: 0.8, y: 0.5))
            content()
                .padding(.horizontal, Metrics.pagePadding + 8)
                .padding(.bottom, 32)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

/// Technical badges, like JellyGoose's: resolution, HDR, codecs, audio, container, bitrate.
struct MediaBadges: View {
    var item: BaseItem

    var body: some View {
        let video = item.videoStream
        let audio = item.audioStreams.first { $0.isDefault == true } ?? item.audioStreams.first
        HStack(spacing: 6) {
            if let resolution = MediaDescription.resolutionLabel(video) {
                InfoBadge(text: resolution, prominent: resolution == "4K")
            }
            if let range = MediaDescription.rangeLabel(video) {
                InfoBadge(text: range, prominent: true)
            }
            if let video {
                InfoBadge(text: MediaDescription.codecName(video.codec) + (video.bitDepth.map { $0 > 8 ? " \($0)-bit" : "" } ?? ""))
            }
            if let audio {
                InfoBadge(text: [MediaDescription.codecName(audio.codec), audio.channels.map(channelDescription)].compactMap { $0 }.joined(separator: " "))
            }
            if let container = item.primaryMediaSource?.container ?? item.container {
                InfoBadge(text: container.split(separator: ",").first.map { String($0).uppercased() } ?? container.uppercased())
            }
            if let bitrate = item.primaryMediaSource?.bitrate {
                InfoBadge(text: Format.bitrate(Double(bitrate)))
            }
            if !item.subtitleStreams.isEmpty {
                InfoBadge(text: String(localized: "CC", comment: "Badge for items with subtitles"))
            }
        }
    }
}

struct CastRow: View {
    var people: [Person]
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        Shelf(title: String(localized: "Cast & Crew")) {
            ForEach(people.prefix(30)) { person in
                VStack(spacing: 8) {
                    RemoteImage(url: app.client?.personImageURL(person)) {
                        ZStack {
                            palette.surface
                            Image(systemName: "person.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(palette.tertiaryText)
                        }
                    }
                    .frame(width: 96, height: 96)
                    .clipShape(Circle())
                    VStack(spacing: 2) {
                        Text(person.name ?? "")
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(person.role?.isEmpty == false ? person.role! : personType(person.type))
                            .font(.system(size: 11))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                    }
                    .frame(width: 110)
                }
            }
        }
    }

    private func personType(_ type: String?) -> String {
        switch type {
        case "Actor": String(localized: "Actor")
        case "Director": String(localized: "Director")
        case "Writer": String(localized: "Writer")
        case "Producer": String(localized: "Producer")
        case "GuestStar": String(localized: "Guest Star")
        case "Composer": String(localized: "Composer")
        default: type ?? ""
        }
    }
}

/// Lists every stream of the file, for checking direct-play compatibility at a glance.
struct MediaInfoSection: View {
    var item: BaseItem
    @Environment(\.palette) private var palette

    var body: some View {
        if let source = item.primaryMediaSource {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: String(localized: "Media Info"))
                VStack(alignment: .leading, spacing: 10) {
                    infoRow(String(localized: "File"), (source.path as NSString?)?.lastPathComponent ?? source.name ?? "")
                    infoRow(String(localized: "Container"), (source.container ?? "").uppercased())
                    if let size = source.size {
                        infoRow(String(localized: "Size"), Format.bytes(Double(size)))
                    }
                    if let bitrate = source.bitrate {
                        infoRow(String(localized: "Bitrate"), Format.bitrate(Double(bitrate)))
                    }
                    infoRow(String(localized: "Playback"), AVPlayerEngine.canPlay(source)
                        ? String(localized: "Direct Play · AVPlayer (native)")
                        : (MPVEngine.isAvailable ? String(localized: "Direct Play · mpv") : String(localized: "Needs mpv for direct play")))
                    ForEach(Array((source.mediaStreams ?? []).enumerated()), id: \.offset) { _, stream in
                        infoRow(streamType(stream.type), streamDescription(stream))
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(.horizontal, Metrics.pagePadding)
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .textSelection(.enabled)
        }
    }

    private func streamDescription(_ stream: MediaStream) -> String {
        switch stream.type {
        case "Video":
            return MediaDescription.video(stream)
        case "Audio":
            return MediaDescription.audio(stream) + (stream.isDefault == true ? " · " + String(localized: "Default") : "")
        default:
            var parts = [stream.displayTitle ?? stream.title ?? MediaDescription.codecName(stream.codec)]
            if stream.isExternal == true {
                parts.append(String(localized: "External"))
            }
            if stream.isForced == true {
                parts.append(String(localized: "Forced"))
            }
            return parts.joined(separator: " · ")
        }
    }

    private func streamType(_ type: String?) -> String {
        switch type {
        case "Video": String(localized: "Video")
        case "Audio": String(localized: "Audio")
        case "Subtitle": String(localized: "Subtitle")
        case "EmbeddedImage": String(localized: "Embedded Image")
        case "Data": String(localized: "Data")
        case let type?: type
        case nil: String(localized: "Stream")
        }
    }
}

extension View {
    /// Shows a long text with a "More" toggle.
    func expandableText(_ text: String, lines: Int = 3) -> some View {
        ExpandableText(text: text, lines: lines)
    }
}

struct ExpandableText: View {
    var text: String
    var lines: Int
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(expanded ? nil : lines)
                .textSelection(.enabled)
            if text.count > 220 {
                Button(expanded ? "Less" : "More") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expanded.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
            }
        }
    }
}
