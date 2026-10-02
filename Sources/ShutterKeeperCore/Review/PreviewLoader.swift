import CoreGraphics
import Foundation
import ImageIO

/// 大图加载器。
///
/// * 先在内存里缓存若干张（默认 8 张），切换时几乎无延迟
/// * 默认加载「屏幕够用」的分辨率；用户放大到 1:1 时再异步换成原始分辨率
/// * 对 RAW 走 ImageIO，优先使用系统 RAW 解码与内嵌预览
public actor PreviewLoader {
    public struct Preview: @unchecked Sendable {
        public let image: CGImage
        /// 这张图在方向校正之后的原始像素尺寸（用于计算 1:1 缩放上限）。
        public let orientedPixelSize: CGSize
        /// 实际解码出来的像素尺寸。
        public let decodedPixelSize: CGSize
        public let isFullResolution: Bool

        public var downsampleFactor: CGFloat {
            decodedPixelSize.width > 0 ? orientedPixelSize.width / decodedPixelSize.width : 1
        }
    }

    private var cache: [String: Preview] = [:]
    private var order: [String] = []
    private let capacity: Int

    public init(capacity: Int = 8) {
        self.capacity = max(2, capacity)
    }

    /// 屏幕预览。`maxPixel` 一般取预览区像素宽度的 1.5 倍左右。
    public func preview(for group: AssetGroup, maxPixel: Int) async -> Preview? {
        guard let file = group.previewFile, file.kind != .video else { return nil }
        let key = "\(file.url.path)|\(maxPixel)"
        return await load(key: key, url: file.url, maxPixel: maxPixel, fullResolution: false)
    }

    /// 原始分辨率（1:1 检查对焦用）。
    public func fullResolution(for group: AssetGroup) async -> Preview? {
        guard let file = group.previewFile, file.kind != .video else { return nil }
        guard let size = Self.orientedPixelSize(of: file.url) else { return nil }
        let maxPixel = Int(max(size.width, size.height))
        let key = "\(file.url.path)|full"
        return await load(key: key, url: file.url, maxPixel: maxPixel, fullResolution: true)
    }

    /// 预加载相邻的几张，切换时不用等。
    public func prefetch(groups: [AssetGroup], maxPixel: Int) async {
        for group in groups {
            guard let file = group.previewFile, file.kind != .video else { continue }
            let key = "\(file.url.path)|\(maxPixel)"
            if cache[key] != nil { continue }
            _ = await load(key: key, url: file.url, maxPixel: maxPixel, fullResolution: false)
        }
    }

    public func clear() {
        cache.removeAll()
        order.removeAll()
    }

    public func isCached(_ group: AssetGroup, maxPixel: Int) -> Bool {
        guard let file = group.previewFile else { return false }
        return cache["\(file.url.path)|\(maxPixel)"] != nil
    }

    // MARK: - 内部

    private func load(key: String, url: URL, maxPixel: Int, fullResolution: Bool) async -> Preview? {
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        guard let preview = Self.decode(url: url, maxPixel: maxPixel, fullResolution: fullResolution) else {
            return nil
        }
        cache[key] = preview
        touch(key)
        evictIfNeeded()
        return preview
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let victim = order.removeFirst()
            cache.removeValue(forKey: victim)
        }
    }

    static func decode(url: URL, maxPixel: Int, fullResolution: Bool) -> Preview? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let orientedSize = orientedPixelSize(source: source) ?? CGSize(width: maxPixel, height: maxPixel)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(64, maxPixel),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return Preview(
            image: image,
            orientedPixelSize: orientedSize,
            decodedPixelSize: CGSize(width: image.width, height: image.height),
            isFullResolution: fullResolution
        )
    }

    /// 方向校正之后的像素尺寸（旋转 90° 的照片要交换宽高）。
    public static func orientedPixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return orientedPixelSize(source: source)
    }

    static func orientedPixelSize(source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if (5...8).contains(orientation) {
            return CGSize(width: height, height: width)
        }
        return CGSize(width: width, height: height)
    }
}
