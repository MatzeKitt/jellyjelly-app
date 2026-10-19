import Foundation

/// Picks the right artwork for each card style, following Jellyfin's parent fallbacks.
extension JellyfinClient {
    func posterURL(_ item: BaseItem, width: Int = 360) -> URL? {
        if let tag = item.imageTag("Primary") {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: width)
        }
        if let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemId: seriesId, type: "Primary", tag: tag, maxWidth: width)
        }
        return nil
    }

    /// A 16:9 image: episode stills, thumbs, or backdrops.
    func thumbURL(_ item: BaseItem, width: Int = 640) -> URL? {
        if item.isEpisode || item.type == ItemType.video, let tag = item.imageTag("Primary") {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: width)
        }
        if let tag = item.imageTag("Thumb") {
            return imageURL(itemId: item.id, type: "Thumb", tag: tag, maxWidth: width)
        }
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: width, index: 0)
        }
        if let parent = item.parentThumbItemId, let tag = item.parentThumbImageTag {
            return imageURL(itemId: parent, type: "Thumb", tag: tag, maxWidth: width)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parent, type: "Backdrop", tag: tag, maxWidth: width, index: 0)
        }
        if let tag = item.imageTag("Primary") {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: width)
        }
        return nil
    }

    func backdropURL(_ item: BaseItem, width: Int = 1920) -> URL? {
        if let tag = item.backdropImageTags?.first {
            return imageURL(itemId: item.id, type: "Backdrop", tag: tag, maxWidth: width, index: 0)
        }
        if let parent = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: parent, type: "Backdrop", tag: tag, maxWidth: width, index: 0)
        }
        return nil
    }

    func logoURL(_ item: BaseItem, width: Int = 600) -> URL? {
        if let tag = item.imageTag("Logo") {
            return imageURL(itemId: item.id, type: "Logo", tag: tag, maxWidth: width)
        }
        if let parent = item.parentLogoItemId, let tag = item.parentLogoImageTag {
            return imageURL(itemId: parent, type: "Logo", tag: tag, maxWidth: width)
        }
        return nil
    }

    /// The channel (series) picture for a video, or the item's own picture for a channel.
    func avatarURL(_ item: BaseItem, width: Int = 120) -> URL? {
        if item.isSeries, let tag = item.imageTag("Primary") {
            return imageURL(itemId: item.id, type: "Primary", tag: tag, maxWidth: width)
        }
        if let seriesId = item.seriesId, let tag = item.seriesPrimaryImageTag {
            return imageURL(itemId: seriesId, type: "Primary", tag: tag, maxWidth: width)
        }
        return nil
    }

    func personImageURL(_ person: Person, width: Int = 200) -> URL? {
        guard let tag = person.primaryImageTag else {
            return nil
        }
        return imageURL(itemId: person.id, type: "Primary", tag: tag, maxWidth: width)
    }
}
