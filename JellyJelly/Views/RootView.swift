import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var app = app
        ZStack {
            palette.backgroundGradient.ignoresSafeArea()

            switch app.phase {
            case .launching:
                SplashView()
            case .signedOut:
                LoginView()
                    .transition(.opacity)
            case .signedIn:
                MainView()
                    .transition(.opacity)
            }

            if let request = app.resumePrompt {
                ResumePrompt(request: request)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(5)
            }

            if let player = app.player, app.showsFullPlayer {
                PlayerView(model: player)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.phase)
        .animation(.easeInOut(duration: 0.2), value: app.showsFullPlayer)
        .animation(.easeInOut(duration: 0.18), value: app.resumePrompt?.id)
        .task {
            await app.restoreSession()
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { app.errorMessage != nil && !app.showsFullPlayer },
            set: { if !$0 { app.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(app.errorMessage ?? "")
        }
        .confirmationDialog(
            "Download “\(app.downloadRequest?.container.displayName ?? "")”?",
            isPresented: Binding(
                get: { app.downloadRequest != nil },
                set: { if !$0 { app.downloadRequest = nil } }
            ),
            titleVisibility: .visible,
            presenting: app.downloadRequest
        ) { request in
            let unwatched = request.unwatched
            if !unwatched.isEmpty, unwatched.count < request.items.count {
                Button("Download \(unwatched.count) Unwatched (\(Format.bytes(Double(DownloadRequest.size(of: unwatched)))))") {
                    app.downloads.enqueue(unwatched)
                }
            }
            if !request.items.isEmpty {
                Button("Download All \(request.items.count) (\(Format.bytes(Double(DownloadRequest.size(of: request.items)))))") {
                    app.downloads.enqueue(request.items)
                }
            }
            Button(request.items.isEmpty ? "OK" : "Cancel", role: .cancel) {}
        } message: { request in
            Text(downloadMessage(request))
        }
    }

    private func downloadMessage(_ request: DownloadRequest) -> String {
        if request.items.isEmpty {
            return String(localized: "Everything in it is already downloaded.")
        }
        var message = app.isYouTube(request.container)
            ? String(localized: "\(request.items.count) videos aren't downloaded yet, \(request.unwatched.count) of them unwatched.")
            : String(localized: "\(request.items.count) items aren't downloaded yet, \(request.unwatched.count) of them unwatched.")
        if let free = app.downloads.availableBytes {
            message += " " + String(localized: "\(Format.bytes(Double(free))) of disk space is free.")
        }
        return message
    }
}

struct SplashView: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 18) {
            AppMark(size: 84)
            ProgressView().controlSize(.small).tint(palette.accent)
        }
    }
}

/// The JellyJelly wordmark glyph: a jellyfish bell with a play symbol.
struct AppMark: View {
    var size: CGFloat = 40
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [palette.accent, palette.accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.42, weight: .black))
                .foregroundStyle(palette.onAccent)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
        .shadow(color: palette.accent.opacity(0.45), radius: size * 0.2)
    }
}

struct MainView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Sidebar()
            ContentStack()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

/// Keeps every screen of the navigation stack alive so scroll positions survive "Back".
struct ContentStack: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: .topLeading) {
            sectionView
                .opacity(app.path.isEmpty ? 1 : 0)
                .allowsHitTesting(app.path.isEmpty)
                .id(app.section)

            ForEach(Array(app.path.enumerated()), id: \.offset) { index, route in
                routeView(route)
                    .id(route)
                    .opacity(index == app.path.count - 1 ? 1 : 0)
                    .allowsHitTesting(index == app.path.count - 1)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }

            if !app.path.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        app.goBack()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(CircleIconButtonStyle(size: 38))
                .help("Back (⌘[)")
                .padding(.leading, 24)
                .padding(.top, 34)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.22), value: app.path.count)
    }

    @ViewBuilder
    private var sectionView: some View {
        switch app.section {
        case .home:
            HomeView()
        case .subscriptions:
            SubscriptionsView()
        case .search:
            SearchView()
        case .favorites:
            FavoritesView()
        case .downloads:
            DownloadsView()
        case let .library(id):
            if let library = app.libraries.first(where: { $0.id == id }) {
                LibraryView(library: library)
            } else {
                LoadingView()
            }
        case .settings:
            SettingsView(embedded: true)
        }
    }

    @ViewBuilder
    private func routeView(_ route: Route) -> some View {
        switch route {
        case let .item(item):
            if item.isSeries && app.isYouTube(item) {
                ChannelView(channel: item)
            } else if item.isSeries {
                SeriesView(series: item)
            } else if item.isContainer {
                LibraryView(library: item)
            } else {
                ItemDetailView(item: item)
            }
        case let .library(library):
            LibraryView(library: library)
        }
    }
}

struct ResumePrompt: View {
    var request: PlayRequest
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture { app.resumePrompt = nil }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(url: app.client?.thumbURL(request.item, width: 900))
                        .frame(width: 460, height: 230)
                        .clipped()
                    LinearGradient(colors: [.clear, palette.surface], startPoint: .center, endPoint: .bottom)
                    if let progress = request.item.progress {
                        ProgressStrip(progress: progress)
                    }
                }
                .frame(width: 460, height: 230)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.item.displayName)
                            .font(.system(size: 18, weight: .bold))
                            .lineLimit(2)
                        if let series = request.item.seriesName {
                            Text(series)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.secondaryText)
                        }
                    }
                    HStack(spacing: 10) {
                        Button {
                            let request = request
                            app.resumePrompt = nil
                            app.play(request.item, queue: request.queue, mode: .resume)
                        } label: {
                            Label("Resume from \(Format.time(request.item.resumePosition))", systemImage: "play.fill")
                        }
                        .buttonStyle(AccentButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        Button {
                            let request = request
                            app.resumePrompt = nil
                            app.play(request.item, queue: request.queue, mode: .beginning)
                        } label: {
                            Label("Start Over", systemImage: "backward.end.fill")
                        }
                        .buttonStyle(AccentButtonStyle(prominent: false))
                    }
                }
                .padding(24)
            }
            .frame(width: 460)
            .background(palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .onExitCommand { app.resumePrompt = nil }
        }
    }
}
