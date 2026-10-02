import Foundation

/// PNG 内部 XMP（`iTXt` 块，关键字 `XML:com.adobe.xmp`）的读写。
///
/// 和 TIFF 一样只在原地改 XMP 那一段：数据长度保持不变、重算该块的 CRC，
/// 文件大小不变，像素数据一个字节都不动。
public enum PNGXMPWriter {
    public enum WriteError: Error, LocalizedError {
        case notPNG(URL)
        case xmpTooLarge(URL, available: Int, needed: Int)
        case ioFailure(URL, String)

        public var errorDescription: String? {
            switch self {
            case .notPNG(let url):
                return "不是有效的 PNG 文件：\(url.lastPathComponent)"
            case .xmpTooLarge(let url, let available, let needed):
                return "\(url.lastPathComponent) 的 XMP 块放不下（可用 \(available) 字节，需要 \(needed) 字节）"
            case .ioFailure(let url, let message):
                return "写入 \(url.lastPathComponent) 失败：\(message)"
            }
        }
    }

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let xmpKeyword = "XML:com.adobe.xmp"

    /// XMP 块：数据区起点（关键字开头）与整块数据长度，以及 CRC 的位置。
    public struct Segment: Sendable {
        public let dataOffset: Int
        public let length: Int
        public let crcOffset: Int
        /// 关键字到「翻译关键字结束」之间的固定前缀长度（重写时原样保留）。
        let prefixLength: Int
    }

    // MARK: - 定位

    public static func xmpSegment(in url: URL) throws -> Segment? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        defer { try? handle.close() }

        let header = (try? handle.read(upToCount: 8)) ?? Data()
        guard [UInt8](header) == signature else { throw WriteError.notPNG(url) }

        var offset = 8
        while true {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else { return nil }
            let headerBytes = [UInt8](chunkHeader)
            let length = Int(
                UInt32(headerBytes[0]) << 24 | UInt32(headerBytes[1]) << 16
                    | UInt32(headerBytes[2]) << 8 | UInt32(headerBytes[3])
            )
            let type = String(bytes: headerBytes[4..<8], encoding: .ascii) ?? ""
            let dataOffset = offset + 8

            if type == "iTXt" {
                if let data = try handle.read(upToCount: min(length, 4096)),
                   let segment = parseITXt(
                    data: [UInt8](data),
                    dataOffset: dataOffset,
                    length: length,
                    crcOffset: dataOffset + length
                   ) {
                    return segment
                }
            }
            if type == "IEND" { return nil }
            offset = dataOffset + length + 4
            if offset <= 8 || length < 0 { return nil }
        }
    }

    /// 判断一个 iTXt 块是不是未压缩的 XMP 块，并算出文本起点。
    private static func parseITXt(data: [UInt8], dataOffset: Int, length: Int, crcOffset: Int) -> Segment? {
        guard let keywordEnd = data.firstIndex(of: 0x00) else { return nil }
        guard let keyword = String(bytes: data[0..<keywordEnd], encoding: .utf8),
              keyword == xmpKeyword else { return nil }
        // keyword \0 压缩标志 压缩方法 语言 \0 翻译关键字 \0 正文
        var index = keywordEnd + 1
        guard index + 1 < data.count else { return nil }
        let compressionFlag = data[index]
        guard compressionFlag == 0 else { return nil }  // 压缩的 XMP 不支持原地改
        index += 2
        guard let languageEnd = data[index...].firstIndex(of: 0x00) else { return nil }
        index = languageEnd + 1
        guard let translatedEnd = data[index...].firstIndex(of: 0x00) else { return nil }
        let prefixLength = translatedEnd + 1
        return Segment(
            dataOffset: dataOffset,
            length: length,
            crcOffset: crcOffset,
            prefixLength: prefixLength
        )
    }

    // MARK: - 读

    public static func readRating(from url: URL) throws -> Int? {
        guard let segment = try xmpSegment(in: url), let (_, text) = try readText(url: url, segment: segment) else {
            return nil
        }
        return XMPPacket.rating(in: text)
    }

    // MARK: - 写

    @discardableResult
    public static func writeRating(_ rating: Int, to url: URL) throws -> Bool {
        guard let segment = try xmpSegment(in: url) else { return false }
        guard let (prefix, text) = try readText(url: url, segment: segment) else {
            throw WriteError.ioFailure(url, "无法读取 XMP 块")
        }
        let merged = XMPPacket.settingRating(rating, in: text)
        let available = segment.length - prefix.count
        let data: Data
        do {
            data = try InPlaceXMP.fitted(merged, toByteCount: available)
        } catch {
            throw WriteError.xmpTooLarge(url, available: available, needed: merged.utf8.count)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forUpdating: url)
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        defer { try? handle.close() }

        // 1) 写数据区（前缀 + 补齐后的文本，总长度不变）
        var payload = prefix
        payload.append(contentsOf: data)
        guard payload.count == segment.length else {
            throw WriteError.xmpTooLarge(url, available: segment.length, needed: payload.count)
        }
        try handle.seek(toOffset: UInt64(segment.dataOffset))
        try handle.write(contentsOf: Data(payload))

        // 2) 重算并写回 CRC（CRC 覆盖块类型 + 数据）
        var crcInput = Array("iTXt".utf8)
        crcInput.append(contentsOf: payload)
        let crc = PNGCRC32.checksum(crcInput)
        let crcBytes: [UInt8] = [
            UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
            UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF),
        ]
        try handle.seek(toOffset: UInt64(segment.crcOffset))
        try handle.write(contentsOf: Data(crcBytes))
        try handle.synchronize()
        return true
    }

    /// 诊断用。
    public static func describe(url: URL) throws -> String {
        guard let segment = try xmpSegment(in: url) else {
            return "没有 XMP 块（iTXt），星级无法写入文件"
        }
        let rating = try readRating(from: url)
        return "XMP 块：偏移 \(segment.dataOffset)，长度 \(segment.length) 字节，当前星级：\(rating.map(String.init) ?? "无")"
    }

    // MARK: - 内部

    private static func readText(url: URL, segment: Segment) throws -> (prefix: [UInt8], text: String)? {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(segment.dataOffset))
        guard let data = try handle.read(upToCount: segment.length) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= segment.prefixLength else { return nil }
        let prefix = Array(bytes[0..<segment.prefixLength])
        let text = String(bytes: bytes[segment.prefixLength...], encoding: .utf8) ?? ""
        return (prefix, text)
    }
}
