import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 通过 ImageIO 读取照片元数据。
///
/// 对 RAW 文件，ImageIO 只读取文件头/内嵌预览，不做完整解码，因此很快。
public enum ExifReader {
    public enum ReadError: Error, LocalizedError {
        case unreadable(URL)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let url): return "无法读取文件元数据：\(url.lastPathComponent)"
            }
        }
    }

    public static func read(url: URL) throws -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ReadError.unreadable(url)
        }
        return read(source: source)
    }

    public static func read(source: CGImageSource) -> PhotoMetadata {
        var metadata = PhotoMetadata()
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]

        metadata.pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        metadata.pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        metadata.orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue

        metadata.captureDate = parseExifDate(
            (exif[kCGImagePropertyExifDateTimeOriginal] as? String)
                ?? (exif[kCGImagePropertyExifDateTimeDigitized] as? String)
                ?? (tiff[kCGImagePropertyTIFFDateTime] as? String)
        )

        metadata.cameraMake = nonEmpty(tiff[kCGImagePropertyTIFFMake] as? String)
        metadata.cameraModel = nonEmpty(tiff[kCGImagePropertyTIFFModel] as? String)
        metadata.lensModel = nonEmpty(
            (exif[kCGImagePropertyExifLensModel] as? String)
                ?? (exif[kCGImagePropertyExifAuxLensModel] as? String)
        )

        if let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoValues.first {
            metadata.iso = first.intValue
        }
        metadata.fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
        metadata.exposureTime = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
        metadata.focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue

        metadata.rating = ratingFromImageMetadata(source: source)
        return metadata
    }

    /// 用 ImageIO 自己的 XMP 解析器读星级。
    ///
    /// 这是一条独立于本程序实现的读取路径，用来交叉验证我们写进去的元数据。
    public static func ratingFromImageMetadata(source: CGImageSource) -> Int? {
        guard let imageMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { return nil }
        guard let tag = CGImageMetadataCopyTagWithPath(imageMetadata, nil, "xmp:Rating" as CFString) else {
            return nil
        }
        guard let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    public static func ratingFromImageMetadata(url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return ratingFromImageMetadata(source: source)
    }

    // MARK: - 视频

    /// 视频没有 EXIF 拍摄时间时回退文件创建时间（用户已确认可接受）。
    public static func videoMetadata(url: URL) async -> PhotoMetadata {
        var metadata = PhotoMetadata()
        let asset = AVURLAsset(url: url)
        if let creationDate = try? await asset.load(.creationDate), let date = creationDate.dateValue {
            metadata.captureDate = date
        }
        if let duration = try? await asset.load(.duration) {
            metadata.duration = CMTimeGetSeconds(duration)
        }
        if let tracks = try? await asset.loadTracks(withMediaType: .video), let track = tracks.first {
            if let size = try? await track.load(.naturalSize) {
                metadata.pixelWidth = Int(abs(size.width))
                metadata.pixelHeight = Int(abs(size.height))
            }
        }
        return metadata
    }

    /// 同步版本：只取文件系统信息，避免在列表渲染时阻塞。
    public static func fileSystemFallback(for url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }

    // MARK: - 辅助

    static func parseExifDate(_ string: String?) -> Date? {
        guard let string, string.count >= 19 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: String(string.prefix(19)))
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
