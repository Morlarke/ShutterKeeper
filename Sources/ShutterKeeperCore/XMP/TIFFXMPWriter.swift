import Foundation

/// TIFF / DNG 内部 XMP（tag 700）的读写。
///
/// 这类文件动辄一两百 MB，所以**只动 XMP 那一段字节**：找到 tag 700 的偏移，
/// 读出来合并星级，再原长度写回去。文件大小不变，图像数据一个字节都不碰。
///
/// 如果文件里没有 XMP 段（例如相机直出的 DNG），就没有安全的位置可写，
/// 这时返回 false，由调用方把星级留在软件数据库里并提示用户。
public enum TIFFXMPWriter {
    public enum WriteError: Error, LocalizedError {
        case notTIFF(URL)
        case xmpTooLarge(URL, available: Int, needed: Int)
        case ioFailure(URL, String)

        public var errorDescription: String? {
            switch self {
            case .notTIFF(let url):
                return "不是有效的 TIFF/DNG 文件：\(url.lastPathComponent)"
            case .xmpTooLarge(let url, let available, let needed):
                return "\(url.lastPathComponent) 的 XMP 段放不下（可用 \(available) 字节，需要 \(needed) 字节）"
            case .ioFailure(let url, let message):
                return "写入 \(url.lastPathComponent) 失败：\(message)"
            }
        }
    }

    /// XMP 段在文件里的位置。
    public struct Segment: Sendable {
        public let offset: Int
        public let length: Int
    }

    static let xmpTag: UInt16 = 700

    // MARK: - 定位

    /// 找到 IFD0 里的 XMP 段；没有就返回 nil。
    public static func xmpSegment(in url: URL) throws -> Segment? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        defer { try? handle.close() }

        let header = (try? handle.read(upToCount: 8)) ?? Data()
        guard header.count == 8 else { throw WriteError.notTIFF(url) }
        let bytes = [UInt8](header)
        let isLittleEndian: Bool
        if bytes[0] == 0x49, bytes[1] == 0x49 {
            isLittleEndian = true
        } else if bytes[0] == 0x4D, bytes[1] == 0x4D {
            isLittleEndian = false
        } else {
            throw WriteError.notTIFF(url)
        }

        func uint16(_ data: [UInt8], _ index: Int) -> UInt16 {
            let pair = (UInt16(data[index]), UInt16(data[index + 1]))
            return isLittleEndian ? (pair.0 | pair.1 << 8) : (pair.0 << 8 | pair.1)
        }
        func uint32(_ data: [UInt8], _ index: Int) -> UInt32 {
            let value: UInt32
            if isLittleEndian {
                value = UInt32(data[index]) | UInt32(data[index + 1]) << 8
                    | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
            } else {
                value = UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16
                    | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
            }
            return value
        }

        guard uint16(bytes, 2) == 42 else { throw WriteError.notTIFF(url) }
        let ifdOffset = Int(uint32(bytes, 4))
        guard ifdOffset > 0 else { return nil }

        guard (try? handle.seek(toOffset: UInt64(ifdOffset))) != nil,
              let countData = try? handle.read(upToCount: 2),
              countData.count == 2 else { return nil }
        let entryCount = Int(uint16([UInt8](countData), 0))
        guard entryCount > 0, entryCount < 4096 else { return nil }

        guard let entriesData = try? handle.read(upToCount: entryCount * 12),
              entriesData.count == entryCount * 12 else { return nil }
        let entries = [UInt8](entriesData)

        for index in 0..<entryCount {
            let base = index * 12
            let tag = uint16(entries, base)
            guard tag == xmpTag else { continue }
            let count = Int(uint32(entries, base + 4))
            // 长度超过 4 字节时，entry 里存的是数据偏移；XMP 包不会短到内联
            guard count > 4 else { return nil }
            let offset = Int(uint32(entries, base + 8))
            guard offset > 0 else { return nil }
            return Segment(offset: offset, length: count)
        }
        return nil
    }

    // MARK: - 读

    public static func readRating(from url: URL) throws -> Int? {
        guard let segment = try xmpSegment(in: url) else { return nil }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(segment.offset))
        guard let data = try handle.read(upToCount: segment.length),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return XMPPacket.rating(in: text)
    }

    // MARK: - 写

    /// 写入星级。返回 false 表示文件里没有 XMP 段，写不进去。
    @discardableResult
    public static func writeRating(_ rating: Int, to url: URL) throws -> Bool {
        guard let segment = try xmpSegment(in: url) else { return false }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        defer { try? handle.close() }

        try handle.seek(toOffset: UInt64(segment.offset))
        guard let existing = try handle.read(upToCount: segment.length),
              let text = String(data: existing, encoding: .utf8) else {
            throw WriteError.ioFailure(url, "无法读取 XMP 段")
        }

        let merged = XMPPacket.settingRating(rating, in: text)
        let data: Data
        do {
            data = try InPlaceXMP.fitted(merged, toByteCount: segment.length)
        } catch {
            throw WriteError.xmpTooLarge(url, available: segment.length, needed: merged.utf8.count)
        }

        try handle.seek(toOffset: UInt64(segment.offset))
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return true
    }

    /// 诊断用：打印 TIFF 的 XMP 段位置。
    public static func describe(url: URL) throws -> String {
        guard let segment = try xmpSegment(in: url) else {
            return "没有 XMP 段（tag 700），星级无法写入文件"
        }
        let rating = try readRating(from: url)
        return "XMP 段：偏移 \(segment.offset)，长度 \(segment.length) 字节，当前星级：\(rating.map(String.init) ?? "无")"
    }
}
