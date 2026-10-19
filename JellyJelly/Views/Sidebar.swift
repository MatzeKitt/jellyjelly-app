import SwiftUI

struct Sidebar: View {
    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette

    private var collapsed: Bool { app.settings.sidebarCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the window's traffic lights.
            Color.clear.frame(height: 40)

            profile
                .padding(.horizontal, collapsed ? 0 : 14)
                .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    SidebarRow(title: String(localized: "Home"), systemImage: "house.fill", section: .home)
                    if app.hasYouTube {
                        SidebarRow(title: String(localized: "Subscriptions"), systemImage: "play.rectangle.on.rectangle.fill", section: .subscriptions)
                    }
                    SidebarRow(title: String(localized: "Search"), systemImage: "magnifyingglass", section: .search)
                    SidebarRow(title: String(localized: "Favorites"), systemImage: "heart.fill", section: .favorites)
                    SidebarRow(title: String(localized: "Downloads"), systemImage: "arrow.down.circle.fill", section: .downloads)

                    if !app.libraries.isEmpty {
                        if collapsed {
                            Divider().overlay(palette.hairline).padding(.vertical, 10).padding(.horizontal, 18)
                        } else {
                            Text("LIBRARIES")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(palette.tertiaryText)
                                .padding(.horizontal, 26)
                                .padding(.top, 22)
                                .padding(.bottom, 6)
                        }
                        ForEach(app.libraries) { library in
                            SidebarRow(title: library.displayName, systemImage: icon(for: library), section: .library(library.id))
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: String(localized: "Settings"), systemImage: "gearshape.fill", section: .settings)
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        app.settings.sidebarCollapsed.toggle()
                    }
                } label: {
                    SidebarLabel(title: String(localized: "Collapse"), systemImage: collapsed ? "sidebar.right" : "sidebar.left", isSelected: false, collapsed: collapsed)
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand Sidebar (⌃⌘S)" : "Collapse Sidebar (⌃⌘S)")
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .frame(width: collapsed ? 76 : 244)
        .background {
            ZStack {
                palette.sidebar.opacity(0.92)
                LinearGradient(colors: [palette.accent.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(palette.hairline).frame(width: 1).ignoresSafeArea()
        }
    }

    private var profile: some View {
        Menu {
            if let name = app.user?.name {
                Text("Signed in as \(name)")
            }
            if let server = app.serverName {
                Text("\(server) · Jellyfin \(app.serverVersion ?? "")")
            }
            Divider()
            Menu("Color Scheme") {
                ForEach(ThemeScheme.allCases) { scheme in
                    Button {
                        app.settings.theme = scheme
                    } label: {
                        if scheme == app.settings.theme {
                            Label(scheme.title, systemImage: "checkmark")
                        } else {
                            Text(scheme.title)
                        }
                    }
                }
            }
            Divider()
            Button("Sign Out") {
                Task { await app.signOut() }
            }
        } label: {
            HStack(spacing: 10) {
                ChannelAvatar(url: app.user.flatMap { user in user.primaryImageTag.flatMap { app.client?.userImageURL(userId: user.id, tag: $0) } },
                              name: app.user?.name, size: 38)
                    .overlay(Circle().strokeBorder(palette.accent, lineWidth: 2))
                if !collapsed {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.user?.name ?? "")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Text(app.serverName ?? "Jellyfin")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.tertiaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.tertiaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func icon(for library: BaseItem) -> String {
        if app.isYouTubeLibrary(library.id) {
            return "play.tv.fill"
        }
        switch library.collectionType {
        case "movies": return "film.fill"
        case "tvshows": return "tv.fill"
        case "homevideos": return "video.fill"
        case "musicvideos": return "music.note.tv.fill"
        case "boxsets": return "square.stack.fill"
        default: return "folder.fill"
        }
    }
}

private struct SidebarRow: View {
    var title: String
    var systemImage: String
    var section: SidebarSection

    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            if app.section == section {
                app.path = []
            } else {
                app.section = section
            }
        } label: {
            SidebarLabel(title: title, systemImage: systemImage, isSelected: app.section == section, collapsed: app.settings.sidebarCollapsed)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct SidebarLabel: View {
    var title: String
    var systemImage: String
    var isSelected: Bool
    var collapsed: Bool

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 22)
                .foregroundStyle(isSelected ? palette.accent : palette.secondaryText)
            if !collapsed {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? palette.text : palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, collapsed ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
        .frame(height: 38)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? palette.accent.opacity(0.16) : .white.opacity(hovering ? 0.06 : 0))
        }
        .overlay(alignment: .leading) {
            if isSelected && !collapsed {
                Capsule().fill(palette.accent).frame(width: 3, height: 18).offset(x: 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
