import Foundation

/// 磁盘上一个具体文件的轻量引用。
public struct FileRef: Hashable, Codable, Sendable {
    public let url: URL
    public let kind: MediaKind
    public let fileSize: Int64?
    public let modificationDate: Date?
    public let creationDate: Date?

    public init(
        url: URL,
        kind: MediaKind? = nil,
        fileSize: Int64? = nil,
        modificationDate: Date? = nil,
        creationDate: Date? = nil
    ) {
        self.url = url
        self.kind = kind ?? MediaTypes.kind(for: url)
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.creationDate = creationDate
    }

    public var fileName: String { url.lastPathComponent }

    /// 不含扩展名的主文件名，配对与改名都以它为依据。
    public var baseName: String { url.deletingPathExtension().lastPathComponent }

    public var fileExtension: String { url.pathExtension.lowercased() }

    public var directory: URL { url.deletingLastPathComponent() }

    /// 同名 `.xmp` 附属文件路径（仅对专有 RAW 有意义）。
    public var sidecarURL: URL {
        directory.appendingPathComponent(baseName).appendingPathExtension("xmp")
    }

    public func exists() -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

extension FileRef: CustomStringConvertible {
    public var description: String { fileName }
}
