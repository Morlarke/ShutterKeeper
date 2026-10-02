import Foundation

/// 媒体类型。决定了「星际评分」最终写到哪里。
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    /// 专有 RAW（NEF / CR3 / ARW / RAF ...）：星级写入同名 `.xmp` 附属文件。
    case proprietaryRAW
    /// JPEG：星级写入文件内部 XMP 元数据段（不重编码像素）。
    case jpeg
    /// TIFF / TIF：星级写入文件内部 XMP（tag 700），只改那一段字节。
    case tiff
    /// PNG：星级写入文件内部 XMP（iTXt 块），只改那一段字节。
    case png
    /// PSD / PSB：Photoshop 工程文件，首版只记在软件内。
    case psd
    /// DNG：TIFF 封装。Lightroom 只认文件内部 XMP，忽略附属文件；首版仅存软件内数据库。
    case dng
    /// HEIC / HEIF：ISO BMFF 封装，首版仅存软件内数据库。
    case heic
    /// 视频：不打分。
    case video
    /// 其他可显示但不可打分的文件。
    case other
    /// 其它常见图片格式（BMP / GIF / AVIF / WebP / JP2 等）：能看能改名，星级只记在软件内。
    case otherImage

    /// 是否可以把星级写进文件（或其附属文件），使 Lightroom Classic 能读到。
    public var writesRatingToDisk: Bool {
        switch self {
        case .proprietaryRAW, .jpeg, .tiff, .png, .dng:
            return true
        case .psd, .heic, .otherImage, .video, .other:
            return false
        }
    }

    public var isRatable: Bool {
        self != .video
    }

    public var isPhoto: Bool {
        self != .video
    }

    /// 星级只能留在软件数据库里的格式（会明确提示用户）。
    public var isDatabaseOnly: Bool {
        switch self {
        case .psd, .heic, .otherImage:
            return true
        default:
            return false
        }
    }
}

public enum MediaTypes {
    /// 专有 RAW 扩展名（写 `.xmp` 附属文件）。
    public static let proprietaryRAWExtensions: Set<String> = [
        "nef", "nrw",                // Nikon
        "cr2", "cr3", "crw",         // Canon
        "arw", "srf", "sr2",         // Sony
        "raf",                       // Fujifilm
        "rw2", "raw",                // Panasonic / Leica
        "orf",                       // Olympus
        "pef", "ptx",                // Pentax
        "srw",                       // Samsung
        "rwl",                       // Leica
        "3fr", "fff",                // Hasselblad
        "iiq",                       // Phase One
        "mrw",                       // Minolta
        "x3f",                       // Sigma
        "dcr", "kdc", "dc2",         // Kodak
        "erf",                       // Epson
        "mef",                       // Mamiya
        "mos", "mfw",                // Leaf
        "gpr",                       // GoPro
        "insp",                      // Insta360
        "eip",                       // Phase One（封装）
        "cs1",                       // Sinar
        "rdc",                       // Ricoh
        "bay",                       // Casio
        "x3i",                       // Sigma
        "k25",                       // Kodak
        "mdc", "qtk",                // 其它小众 RAW
    ]

    public static let dngExtensions: Set<String> = ["dng"]

    public static let jpegExtensions: Set<String> = ["jpg", "jpeg", "jpe", "jfif"]

    public static let tiffExtensions: Set<String> = ["tif", "tiff"]

    public static let pngExtensions: Set<String> = ["png"]

    public static let psdExtensions: Set<String> = ["psd", "psb"]

    public static let heicExtensions: Set<String> = ["heic", "heif", "hif"]

    /// 其它常见图片格式：能显示、能改名、能配对，星级只记在软件数据库。
    public static let otherImageExtensions: Set<String> = [
        "bmp", "gif", "avif", "webp", "jp2", "jpf", "jpx", "j2k", "exr", "tga", "pcx", "ico",
    ]

    public static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mts", "m2ts", "mts", "3gp", "3g2", "mkv", "mpg", "mpeg", "wmv", "flv", "insv",
        "mxf", "ts", "m2t", "m2p", "vob", "asf", "dv", "r3d", "braw",
    ]

    public static let allExtensions: Set<String> =
        proprietaryRAWExtensions
        .union(dngExtensions)
        .union(jpegExtensions)
        .union(tiffExtensions)
        .union(pngExtensions)
        .union(psdExtensions)
        .union(heicExtensions)
        .union(otherImageExtensions)
        .union(videoExtensions)
        .union(["xmp"])

    public static func kind(forPathExtension ext: String) -> MediaKind {
        let e = ext.lowercased()
        if proprietaryRAWExtensions.contains(e) { return .proprietaryRAW }
        if dngExtensions.contains(e) { return .dng }
        if jpegExtensions.contains(e) { return .jpeg }
        if tiffExtensions.contains(e) { return .tiff }
        if pngExtensions.contains(e) { return .png }
        if psdExtensions.contains(e) { return .psd }
        if heicExtensions.contains(e) { return .heic }
        if otherImageExtensions.contains(e) { return .otherImage }
        if videoExtensions.contains(e) { return .video }
        return .other
    }

    public static func kind(for url: URL) -> MediaKind {
        kind(forPathExtension: url.pathExtension)
    }

    /// 附属文件（`.xmp`、缩略图等），不应出现在胶片条里。
    public static func isSidecar(pathExtension ext: String) -> Bool {
        ext.lowercased() == "xmp"
    }

    /// 跟着主文件走的附属文件扩展名（改名与导入时一起搬运）。
    public static let sidecarExtensions: Set<String> = ["xmp", "aae", "thm", "lrv", "dop", "pp3", "cos"]

    public static func isSidecarFile(_ ext: String) -> Bool {
        sidecarExtensions.contains(ext.lowercased())
    }
}
