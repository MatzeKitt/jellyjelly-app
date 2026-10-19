import AppKit
import SwiftUI

/// Loads and caches artwork in memory and on disk.
actor ImageLoader {
    static let shared = ImageLoader()

    // NSCache is thread-safe, so the synchronous cache check needs no actor hop.
    private nonisolated(unsafe) let memory = NSCache<NSURL, NSImage>()
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]
    private let session: URLSession

    init() {
        memory.totalCostLimit = 400 * 1024 * 1024
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 1024 * 1024 * 1024)
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration)
    }

    nonisolated func cached(_ url: URL) -> NSImage? {
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> NSImage? {
        if let image = memory.object(forKey: url as NSURL) {
            return image
        }
        if let task = inFlight[url] {
            return await task.value
        }
        let session = self.session
        let task = Task<NSImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, response) = try? await session.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let image = NSImage(data: data)
            else {
                return nil
            }
            return image
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            memory.setObject(image, forKey: url as NSURL, cost: cost)
        }
        return image
    }
}

struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @State private var loadedURL: URL?

    var body: some View {
        ZStack {
            if let image, loadedURL == url {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                loadedURL = nil
                return
            }
            if let cached = ImageLoader.shared.cached(url) {
                image = cached
                loadedURL = url
                return
            }
            let loaded = await ImageLoader.shared.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) {
                image = loaded
                loadedURL = url
            }
        }
    }
}

extension RemoteImage where Placeholder == Color {
    init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = { Color.white.opacity(0.06) }
    }
}
