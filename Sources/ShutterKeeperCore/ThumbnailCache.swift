import AVFoundation
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// 缩略图缓存。
///
/// 缓存目录可以整个删掉：删了下次重新生成，不丢任何数据。
public actor ThumbnailCache {
    public let root: URL
    private var inFlight: [String: Task<CGImage?, Never>] = [:]

    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func thumbnail(for file: FileRef, maxPixel: Int = 512) async -> CGImage? {
        let key = cacheKey(for: file, maxPixel: maxPixel)
        if let task = inFlight[key] { return await task.value }

        let task = Task<CGImage?, Never> { [root] in
            let cacheURL = ThumbnailCache.cacheURL(root: root, key: key)
            if let cached = ThumbnailCache.decodeImage(at: cacheURL) {
                return cached
            }
            guard let rendered = await ThumbnailCache.render(file: file, maxPixel: maxPixel) else {
                return nil
            }
            ThumbnailCache.encode(image: rendered, to: cacheURL)
            return rendered
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        return image
    }

    public func removeAll() throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    public func cachedByteCount() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    // MARK: - 内部实现

    private func cacheKey(for file: FileRef, maxPixel: Int) -> String {
        let stamp = file.modificationDate?.timeIntervalSince1970 ?? 0
        let raw = "\(file.url.path)|\(file.fileSize ?? -1)|\(stamp)|\(maxPixel)|v1"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cacheURL(root: URL, key: String) -> URL {
        let shard = String(key.prefix(2))
        let directory = root.appendingPathComponent(shard, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(key).jpg")
    }

    private static func decodeImage(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func encode(image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        CGImageDestinationFinalize(destination)
    }

    private static func render(file: FileRef, maxPixel: Int) async -> CGImage? {
        if file.kind == .video {
            return await renderVideo(file: file, maxPixel: maxPixel)
        }
        return renderImage(file: file, maxPixel: maxPixel)
    }

    private static func renderImage(file: FileRef, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // 某些 RAW 需要退回到完整解码
        let fallback: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, fallback as CFDictionary)
    }

    private static func renderVideo(file: FileRef, maxPixel: Int) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: file.url,
            size: CGSize(width: maxPixel, height: maxPixel),
            scale: 1,
            representationTypes: .thumbnail
        )
        let generator = QLThumbnailGenerator.shared
        return await withCheckedContinuation { continuation in
            generator.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
    }
}
