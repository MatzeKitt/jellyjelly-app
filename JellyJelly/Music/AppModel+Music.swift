import Foundation

/// Browsing, queueing, and playlist actions for music.
extension AppModel {
    var hasMusic: Bool { !musicLibraries.isEmpty }

    /// Limits queries to the music library, so audiobooks in other libraries stay out. With several
    /// music libraries, queries go across all libraries instead.
    var musicParentId: String? {
        musicLibraries.count == 1 ? musicLibraries.first?.id : nil
    }

    // MARK: - Songs

    /// The songs of an album, artist, or playlist in their natural order; a song is just itself.
    func songs(of item: BaseItem) async throws -> [BaseItem] {
        guard let client else {
            throw APIError.notAuthenticated
        }
        if item.isAudio {
            return [item]
        }
        if item.isPlaylist {
            return try await client.playlistItems(item.id).filter(\.isAudio)
        }
        var query = ItemQuery()
        query.includeItemTypes = [ItemType.audio]
        query.enableTotalRecordCount = false
        if item.isArtist {
            query.artistIds = [item.id]
            query.parentId = musicParentId
            query.sortBy = ["ProductionYear", "Album", "ParentIndexNumber", "IndexNumber", "SortName"]
            query.limit = 1000
        } else {
            query.parentId = item.id
            query.sortBy = ["ParentIndexNumber", "IndexNumber", "SortName"]
        }
        query.sortOrder = Array(repeating: "Ascending", count: query.sortBy.count)
        return try await client.items(query).items
    }

    func playMusic(_ item: BaseItem, shuffle: Bool = false) {
        Task {
            do {
                music.play(try await songs(of: item), shuffle: shuffle)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Queues the songs of an item next or at the end of the queue.
    func queueMusic(_ item: BaseItem, next: Bool) {
        Task {
            do {
                let songs = try await songs(of: item)
                if next {
                    music.playNext(songs)
                } else {
                    music.addToQueue(songs)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Plays songs similar to an item, as a new queue.
    func startInstantMix(_ item: BaseItem) {
        guard let client else {
            return
        }
        Task {
            do {
                let songs = try await client.instantMix(itemId: item.id).filter(\.isAudio)
                if songs.isEmpty {
                    errorMessage = String(localized: "Jellyfin found no similar music for “\(item.displayName)”.")
                } else {
                    music.play(songs, shuffle: false)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Playlists

    func loadPlaylists() async {
        guard let client else {
            return
        }
        var query = ItemQuery()
        query.includeItemTypes = [ItemType.playlist]
        query.fields = JellyfinClient.standardFields + ["CanDelete"]
        query.enableTotalRecordCount = false
        if let items = try? await client.items(query).items {
            musicPlaylists = items.filter(\.isMusic)
        }
    }

    /// Adds songs, or everything in an album or artist, which the server expands to its songs.
    func addToPlaylist(_ playlist: BaseItem, items: [BaseItem]) {
        guard let client, !items.isEmpty else {
            return
        }
        Task {
            do {
                try await client.addToPlaylist(playlist.id, itemIds: items.map(\.id))
                playlistGeneration += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Returns the new playlist, or `nil` if the server refused it.
    @discardableResult
    func createPlaylist(name: String, isPublic: Bool, items: [BaseItem]) async -> BaseItem? {
        guard let client else {
            return nil
        }
        do {
            let id = try await client.createPlaylist(name: name, itemIds: items.map(\.id), isPublic: isPublic)
            await loadPlaylists()
            return musicPlaylists.first { $0.id == id } ?? BaseItem(id: id, name: name, type: ItemType.playlist, mediaType: "Audio")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func updatePlaylist(_ playlist: BaseItem, name: String, isPublic: Bool) async {
        guard let client else {
            return
        }
        do {
            try await client.updatePlaylist(playlist.id, name: name, isPublic: isPublic)
            await loadPlaylists()
            playlistGeneration += 1
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes the playlist on the server; its songs stay in the library.
    func deletePlaylist(_ playlist: BaseItem) {
        guard let client else {
            return
        }
        Task {
            do {
                try await client.deleteItem(playlist.id)
                musicPlaylists.removeAll { $0.id == playlist.id }
                if case let .item(shown)? = path.last, shown.id == playlist.id {
                    goBack()
                }
                playlistGeneration += 1
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
