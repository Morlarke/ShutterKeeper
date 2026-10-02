import Foundation

/// `.xmp` 附属文件的读写。
///
/// Lightroom Classic 对专有 RAW（NEF / CR3 / ARW / RAF ...）通过同名 `.xmp` 读取星级，
/// 这也是 Bridge 的做法。
public enum XMPSidecar {
    public enum WriteError: Error, LocalizedError {
        case notWritable(URL)
        case writeFailed(URL, Error)

        public var errorDescription: String? {
            switch self {
            case .notWritable(let url): return "无法写入 XMP 附属文件：\(url.lastPathComponent)"
            case .writeFailed(let url, let error):
                return "写入 XMP 附属文件失败：\(url.lastPathComponent)（\(error.localizedDescription)）"
            }
        }
    }

    public static func url(for file: FileRef) -> URL {
        file.sidecarURL
    }

    public static func exists(for file: FileRef) -> Bool {
        FileManager.default.fileExists(atPath: file.sidecarURL.path)
    }

    public static func readRating(for file: FileRef) throws -> Int? {
        readRating(at: file.sidecarURL)
    }

    public static func readRating(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return XMPPacket.rating(in: text)
    }

    /// 写入星级。
    ///
    /// 若附属文件已存在（例如 Lightroom 写过修图设置），只更新星级字段，其余内容保持不变。
    @discardableResult
    public static func writeRating(_ rating: Int, for file: FileRef) throws -> URL {
        try writeRating(rating, to: file.sidecarURL)
    }

    @discardableResult
    public static func writeRating(_ rating: Int, to url: URL) throws -> URL {
        let clamped = max(0, min(5, rating))
        let text: String
        if let data = try? Data(contentsOf: url), let existing = String(data: data, encoding: .utf8) {
            text = XMPPacket.settingRating(clamped, in: existing)
        } else {
            text = XMPPacket.packet(rating: clamped)
        }

        guard let encoded = text.data(using: .utf8) else {
            throw WriteError.notWritable(url)
        }
        do {
            try encoded.write(to: url, options: .atomic)
        } catch {
            throw WriteError.writeFailed(url, error)
        }
        return url
    }
}
