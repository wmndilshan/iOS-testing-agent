import AppKit
import ImageIO

/// Screenshots shown in the app, decoded once at a display size and kept. Decoding a full-resolution PNG inside a view body ran on every redraw,
/// and a streaming run redraws constantly. The key includes the file's modification date, because a retried step rewrites the same file name.
@MainActor
enum ImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 60
        return cache
    }()

    private static func key(_ url: URL, maxPixels: Int) -> (key: NSString, stamp: Date?) {
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ("\(url.path)|\(stamp?.timeIntervalSince1970 ?? 0)|\(maxPixels)" as NSString, stamp)
    }

    /// Changes when the file is rewritten (a retried step saves a new screenshot under the same name), so a view can reload.
    static func version(of url: URL) -> String { key(url, maxPixels: 0).key as String }

    /// The image when it is already decoded, with no disk read beyond the date check.
    static func cached(_ url: URL, maxPixels: Int = 1400) -> NSImage? {
        cache.object(forKey: key(url, maxPixels: maxPixels).key)
    }

    /// Decodes off the main thread, at no more than `maxPixels` on the long side.
    static func load(_ url: URL, maxPixels: Int = 1400) async -> NSImage? {
        let entry = key(url, maxPixels: maxPixels).key
        if let hit = cache.object(forKey: entry) { return hit }
        let image = await Task.detached(priority: .userInitiated) { downsample(url, maxPixels: maxPixels) }.value
        if let image { cache.setObject(image, forKey: entry) }
        return image
    }

    nonisolated private static func downsample(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
