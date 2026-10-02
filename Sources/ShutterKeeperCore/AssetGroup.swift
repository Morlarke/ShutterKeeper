import Foundation

/// 「一张片子」。
///
/// 使用者看到的是照片/视频，不是文件。RAW + JPG 配对后是一个 `AssetGroup`，
/// 胶片条里只出现一项，打分、筛选、删除都以它为单位。
public struct AssetGroup: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let folder: URL
    /// 展示用主文件名（取组内首选文件的基名，各成员共用同一基名，大小写可能不同）。
    public let baseName: String
    public let files: [FileRef]
    /// 拍摄时间。照片来自 EXIF，视频来自 AVFoundation，取不到时回退文件创建时间。
    public var captureDate: Date?
    /// 分组的排序键（拍摄时间优先，其次文件名）。
    public var sortKey: String

    public init(folder: URL, baseName: String, files: [FileRef], captureDate: Date? = nil) {
        self.folder = folder
        self.baseName = baseName
        self.files = files
        self.captureDate = captureDate
        self.id = AssetGroup.makeID(folder: folder, baseName: baseName)
        self.sortKey = AssetGroup.makeSortKey(captureDate: captureDate, baseName: baseName)
    }

    public static func makeID(folder: URL, baseName: String) -> String {
        "\(folder.standardizedFileURL.path)#\(baseName.lowercased())"
    }

    public static func makeSortKey(captureDate: Date?, baseName: String) -> String {
        if let date = captureDate {
            return String(format: "%.3f\u{0}%@", date.timeIntervalSince1970, baseName.lowercased())
        }
        return "\u{FFFF}\u{0}\(baseName.lowercased())"
    }

    // MARK: - 成员查询

    public var isVideo: Bool { files.allSatisfy { $0.kind == .video } }

    /// 视频不打分。
    public var isRatable: Bool { files.contains { $0.kind.isRatable } }

    public func first(kind: MediaKind) -> FileRef? {
        files.first { $0.kind == kind }
    }

    public var jpeg: FileRef? { first(kind: .jpeg) }
    public var tiff: FileRef? { first(kind: .tiff) }
    public var png: FileRef? { first(kind: .png) }
    public var proprietaryRAW: FileRef? { first(kind: .proprietaryRAW) }
    public var dng: FileRef? { first(kind: .dng) }
    public var heic: FileRef? { first(kind: .heic) }
    public var video: FileRef? { first(kind: .video) }

    /// 大图预览用哪个文件：优先 JPG（解码快、缓存省），其次 TIFF、PNG、HEIC、DNG、专有 RAW。
    public var previewFile: FileRef? {
        if let jpeg { return jpeg }
        if let tiff { return tiff }
        if let png { return png }
        if let heic { return heic }
        if let dng { return dng }
        if let proprietaryRAW { return proprietaryRAW }
        return video
    }

    /// 需要把星级写进文件（或附属文件）的成员。
    public var ratingWriteTargets: [FileRef] {
        files.filter { $0.kind.writesRatingToDisk }
    }

    /// 星级只能留在软件数据库里的成员（PSD / HEIC / 其它图片格式）。
    /// TIFF / DNG / PNG 会尝试写进文件，写不进去时由 `RatingService` 单独汇报。
    public var databaseOnlyTargets: [FileRef] {
        files.filter { $0.kind.isDatabaseOnly }
    }

    /// 删除时一并处理的文件：配对成员 + 相应 `.xmp` 附属文件。
    public var deletionTargets: [FileRef] {
        var result = files
        for file in files where file.kind == .proprietaryRAW || file.kind == .dng {
            let sidecar = FileRef(url: file.sidecarURL, kind: .other)
            if sidecar.exists() { result.append(sidecar) }
        }
        return result
    }

    /// 同一文件夹里跟这张片子配套的附属文件（`.xmp` / `.aae` 等）。
    ///
    /// 兼容 `IMG_1234.xmp` 与 `IMG_1234.NEF.xmp` 两种命名。
    public var sidecars: [FileRef] {
        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        let basenames = Set(files.map { $0.baseName.lowercased() })
        let fullnames = Set(files.map { $0.fileName.lowercased() })
        var result: [FileRef] = []
        for name in contents {
            let url = folder.appendingPathComponent(name)
            guard MediaTypes.isSidecarFile(url.pathExtension) else { continue }
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            guard basenames.contains(stem) || fullnames.contains(stem) else { continue }
            result.append(FileRef(url: url, kind: .other))
        }
        return result
    }

    /// 面板/胶片条上展示的文件名（配对时显示 RAW 名，更贴近摄影师的直觉）。
    public var displayName: String {
        if let proprietaryRAW { return proprietaryRAW.fileName }
        if let dng { return dng.fileName }
        if let jpeg { return jpeg.fileName }
        if let video { return video.fileName }
        return files.first?.fileName ?? baseName
    }

    public var isPaired: Bool { files.count > 1 }
}
