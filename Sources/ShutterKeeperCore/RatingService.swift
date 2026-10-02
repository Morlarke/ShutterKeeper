import Foundation

/// 一次打分操作的结果。
public struct RatingWriteOutcome: Sendable {
    /// 星级已写入磁盘的文件（RAW 的 `.xmp`、JPG 内部元数据）。
    public var writtenFiles: [URL] = []
    /// 首版无法写入文件、只存在软件数据库里的文件（DNG / HEIC）。
    public var databaseOnlyFiles: [URL] = []
    /// 视频不打分。
    public var skippedFiles: [URL] = []
    public var errors: [String] = []

    public var succeeded: Bool { errors.isEmpty }
}

/// 打分的唯一入口：把「一张片子的星级」写进它所有的文件。
///
/// 配对后的 RAW + JPG 会被写成同样的星级，保证 Lightroom Classic 里两边一致。
public enum RatingService {
    @discardableResult
    public static func write(rating: Int, to group: AssetGroup) -> RatingWriteOutcome {
        var outcome = RatingWriteOutcome()
        let clamped = max(0, min(5, rating))

        for file in group.files {
            switch file.kind {
            case .proprietaryRAW:
                do {
                    try XMPSidecar.writeRating(clamped, for: file)
                    outcome.writtenFiles.append(file.url)
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            case .jpeg:
                do {
                    try JPEGMetadataWriter.writeRating(clamped, to: file.url)
                    outcome.writtenFiles.append(file.url)
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            case .tiff, .dng:
                // TIFF 与 DNG 都是 TIFF 结构，改文件内部的 XMP 段（tag 700）
                do {
                    let wrote = try TIFFXMPWriter.writeRating(clamped, to: file.url)
                    if wrote {
                        outcome.writtenFiles.append(file.url)
                    } else {
                        // 没有 XMP 段的文件（例如相机直出 DNG）无处可写
                        outcome.databaseOnlyFiles.append(file.url)
                    }
                } catch TIFFXMPWriter.WriteError.notTIFF {
                    // 扩展名说是 TIFF/DNG，但结构不是：同样只能留在软件内
                    outcome.databaseOnlyFiles.append(file.url)
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            case .png:
                do {
                    let wrote = try PNGXMPWriter.writeRating(clamped, to: file.url)
                    if wrote {
                        outcome.writtenFiles.append(file.url)
                    } else {
                        outcome.databaseOnlyFiles.append(file.url)
                    }
                } catch PNGXMPWriter.WriteError.notPNG {
                    outcome.databaseOnlyFiles.append(file.url)
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            case .psd, .heic, .otherImage:
                // PSD/PSB 与 HEIC 的内部元数据写入较复杂，其它图片格式 Lightroom 也不读，
                // 这些一律只记在软件数据库里。
                outcome.databaseOnlyFiles.append(file.url)
            case .video, .other:
                outcome.skippedFiles.append(file.url)
            }
        }
        return outcome
    }

    /// 从文件里读回星级（用于数据库被删除后恢复）。
    ///
    /// 优先读 JPG 内部元数据，其次读 RAW 的 `.xmp` 附属文件。
    public static func readRatingFromFiles(for group: AssetGroup) -> Int? {
        if let jpeg = group.jpeg, let rating = try? JPEGMetadataWriter.readRating(from: jpeg.url) {
            return rating
        }
        for file in group.files where file.kind == .tiff || file.kind == .png {
            if let rating = readRating(from: file) { return rating }
        }
        if let raw = group.proprietaryRAW, let rating = try? XMPSidecar.readRating(for: raw) {
            return rating
        }
        for file in group.files where file.kind == .dng || file.kind == .heic || file.kind == .psd {
            if let rating = readRating(from: file) { return rating }
        }
        return nil
    }

    /// 从单个文件读回星级（不限类型）。
    public static func readRating(from file: FileRef) -> Int? {
        switch file.kind {
        case .jpeg:
            return try? JPEGMetadataWriter.readRating(from: file.url)
        case .proprietaryRAW:
            return try? XMPSidecar.readRating(for: file)
        case .tiff, .dng:
            if let rating = try? TIFFXMPWriter.readRating(from: file.url) {
                return rating
            }
            return ExifReader.ratingFromImageMetadata(url: file.url)
        case .png:
            if let rating = try? PNGXMPWriter.readRating(from: file.url) {
                return rating
            }
            return ExifReader.ratingFromImageMetadata(url: file.url)
        case .psd, .heic, .otherImage:
            return ExifReader.ratingFromImageMetadata(url: file.url)
        case .video, .other:
            return nil
        }
    }

    /// 交叉验证用：让 ImageIO 自己去解析 XMP，看它读到几星。
    public static func readRatingViaImageIO(for file: FileRef) -> Int? {
        ExifReader.ratingFromImageMetadata(url: file.url)
    }
}
