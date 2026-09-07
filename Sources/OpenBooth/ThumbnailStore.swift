//
//  ThumbnailStore.swift
//  OpenBooth
//
//  Small thumbnails (800 px) for gallery and collage. Fully decoding a 33 MP JPEG (~12 MB) takes
//  noticeable time per tile on the iPad; ImageIO reads only as much as needed via subsampling. The result lives in
//  memory (NSCache) and on disk under <event folder>/.thumbs/<name>.jpg, created already when saving.
//

import UIKit
import ImageIO

enum ThumbnailStore {
    static let maxPixel = 800
    private static let cache: NSCache<NSURL, UIImage> = { let c = NSCache<NSURL, UIImage>(); c.countLimit = 400; return c }()

    static func thumbURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".thumbs", isDirectory: true)
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".jpg")
    }

    /// Get a thumbnail: memory, then disk, otherwise generate (in the background).
    static func thumbnail(for url: URL) async -> UIImage? {
        if let img = cache.object(forKey: url as NSURL) { return img }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            let t = thumbURL(for: url)
            if let d = try? Data(contentsOf: t), let i = UIImage(data: d) { return i }
            return generate(for: url)
        }.value
        if let img { cache.setObject(img, forKey: url as NSURL) }
        return img
    }

    /// Generate a thumbnail and store it on disk. Runs synchronously, so call from a background task.
    @discardableResult
    nonisolated static func generate(for url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = UIImage(cgImage: cg)
        let t = thumbURL(for: url)
        try? FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = img.jpegData(compressionQuality: 0.82) { try? d.write(to: t, options: .atomic) }
        return img
    }

    /// When saving a photo: prepare the thumbnail in the background.
    static func prepare(_ url: URL) {
        Task.detached(priority: .utility) {
            if let img = generate(for: url) { await MainActor.run { cache.setObject(img, forKey: url as NSURL) } }
        }
    }

    static func remove(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
        try? FileManager.default.removeItem(at: thumbURL(for: url))
    }
}
