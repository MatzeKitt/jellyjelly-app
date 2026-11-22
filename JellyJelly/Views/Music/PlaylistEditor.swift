import SwiftUI

/// Names a new playlist, or renames an existing one, and sets whether other users see it.
struct PlaylistEditor: View {
    var request: PlaylistSheet

    @Environment(AppModel.self) private var app
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var isPublic = false
    @State private var saving = false
    @FocusState private var focused: Bool

    private var isNew: Bool {
        if case .create = request {
            return true
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isNew ? "New Playlist" : "Edit Playlist")
                .font(.system(size: 18, weight: .bold))
            if case let .create(items) = request, !items.isEmpty {
                Text(items.count == 1 ? "Adds “\(items[0].displayName)”." : "Adds \(items.count) items.")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondaryText)
            }
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
            Toggle("Visible to all users on the server", isOn: $isPublic)
                .toggleStyle(.switch)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(24)
        .frame(width: 380)
        .task {
            focused = true
            if case let .edit(playlist) = request {
                name = playlist.name ?? ""
                isPublic = (try? await app.client?.playlistInfo(playlist.id))?.openAccess ?? false
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !saving else {
            return
        }
        saving = true
        Task {
            switch request {
            case let .create(items):
                if let playlist = await app.createPlaylist(name: trimmed, isPublic: isPublic, items: items), items.isEmpty {
                    // An empty playlist is only useful once it's open.
                    app.open(playlist)
                }
            case let .edit(playlist):
                await app.updatePlaylist(playlist, name: trimmed, isPublic: isPublic)
            }
            dismiss()
        }
    }
}
