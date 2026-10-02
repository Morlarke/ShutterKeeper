import Foundation

/// JPEG 文件内部 XMP 元数据的读写。
///
/// 只替换 APP1 里的 XMP 数据段，像素数据与原始 EXIF 段一个字节都不动 ——
/// 因此不会二次压缩、不改变画质。副作用是文件修改时间会更新（拍摄日期不变）。
public enum JPEGMetadataWriter {
    public enum WriteError: Error, LocalizedError {
        case notJPEG(URL)
        case malformed(URL)
        case packetTooLarge(Int)
        case readFailed(URL, Error)

        public var errorDescription: String? {
            switch self {
            case .notJPEG(let url):
                return "不是有效的 JPEG 文件：\(url.lastPathComponent)"
            case .malformed(let url):
                return "JPEG 结构解析失败：\(url.lastPathComponent)"
            case .packetTooLarge(let size):
                return "XMP 数据段过大（\(size) 字节），无法写入单个 JPEG 段"
            case .readFailed(let url, let error):
                return "读取失败：\(url.lastPathComponent)（\(error.localizedDescription)）"
            }
        }
    }

    static let identifierBytes: [UInt8] = Array(XMPPacket.jpegAPP1Identifier.utf8) + [0x00]
    static let maxSegmentLength = 65535

    // MARK: - 读取

    public static func readRating(from url: URL) throws -> Int? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WriteError.readFailed(url, error)
        }
        guard let packet = try xmpPacket(in: [UInt8](data), url: url),
              let text = String(data: Data(packet), encoding: .utf8) else {
            return nil
        }
        return XMPPacket.rating(in: text)
    }

    // MARK: - 写入

    public static func writeRating(_ rating: Int, to url: URL) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WriteError.readFailed(url, error)
        }
        let output = try rewriting(bytes: [UInt8](data), rating: rating, source: url)
        try FileReplacement.replaceContents(of: url, with: Data(output))
    }

    /// 纯函数版本，便于单元测试。
    static func rewriting(bytes: [UInt8], rating: Int, source: URL?) throws -> [UInt8] {
        let failureURL = source ?? URL(fileURLWithPath: "/dev/null")
        guard bytes.count > 3, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw WriteError.notJPEG(failureURL)
        }

        let scan = try scanSegments(bytes, url: failureURL)

        // 算出新的 XMP 数据包文本
        let existingText = scan.xmpSegment.flatMap { segment -> String? in
            let packetBytes = bytes[segment.packetStart..<segment.end].filter { $0 != 0x00 }
            return String(data: Data(packetBytes), encoding: .utf8)
        }
        let newText = existingText.map { XMPPacket.settingRating(rating, in: $0) }
            ?? XMPPacket.packet(rating: rating)
        let packetBytes = [UInt8](newText.utf8)
        let segmentLength = 2 + identifierBytes.count + packetBytes.count
        guard segmentLength <= maxSegmentLength else {
            throw WriteError.packetTooLarge(segmentLength)
        }

        var newSegment: [UInt8] = [0xFF, 0xE1, UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)]
        newSegment.append(contentsOf: identifierBytes)
        newSegment.append(contentsOf: packetBytes)

        // 拼接：XMP 段已存在则替换，否则插到 EXIF APP1（或 APP0）之后
        if let xmp = scan.xmpSegment {
            var output = Array(bytes[0..<xmp.start])
            output.append(contentsOf: newSegment)
            output.append(contentsOf: bytes[xmp.end...])
            return output
        }

        var output = Array(bytes[0..<scan.insertionOffset])
        output.append(contentsOf: newSegment)
        output.append(contentsOf: bytes[scan.insertionOffset...])
        return output
    }

    // MARK: - JPEG 段扫描

    struct XMPSegment {
        let start: Int        // 0xFF 的位置
        let packetStart: Int  // 数据包正文起点
        let end: Int          // 段结束（不含）
    }

    struct ScanResult {
        var xmpSegment: XMPSegment?
        var insertionOffset: Int
        var scanDataOffset: Int?  // SOS 段起点，用于校验像素数据未变动
    }

    static func scanSegments(_ bytes: [UInt8], url: URL) throws -> ScanResult {
        var index = 2
        var xmpSegment: XMPSegment?
        var insertionOffset = 2
        var scanDataOffset: Int?

        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else {
                throw WriteError.malformed(url)
            }
            // 跳过填充字节 0xFF 0xFF...
            while index + 1 < bytes.count, bytes[index + 1] == 0xFF {
                index += 1
            }
            guard index + 1 < bytes.count else { break }
            let marker = bytes[index + 1]

            // 无长度字段的标记
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                index += 2
                continue
            }
            // 图像数据开始，后面是熵编码数据，不再扫描
            if marker == 0xDA {
                scanDataOffset = index
                break
            }
            guard index + 3 < bytes.count else {
                throw WriteError.malformed(url)
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            guard length >= 2 else { throw WriteError.malformed(url) }
            let payloadStart = index + 4
            let end = index + 2 + length
            guard end <= bytes.count else { throw WriteError.malformed(url) }

            if marker == 0xE1, end - payloadStart >= identifierBytes.count {
                let slice = Array(bytes[payloadStart..<(payloadStart + identifierBytes.count)])
                if slice == identifierBytes, xmpSegment == nil {
                    xmpSegment = XMPSegment(start: index, packetStart: payloadStart + identifierBytes.count, end: end)
                    // 已经找到 XMP 段，不需要再找插入点
                }
            }

            if xmpSegment == nil {
                // APP0(JFIF) 或 APP1(EXIF) 之后就是插入 XMP 的好位置
                if marker == 0xE0 || marker == 0xE1 {
                    insertionOffset = end
                }
            }

            guard marker != 0xD9 else { break }  // EOI
            index = end
        }

        return ScanResult(xmpSegment: xmpSegment, insertionOffset: insertionOffset, scanDataOffset: scanDataOffset)
    }

    static func xmpPacket(in bytes: [UInt8], url: URL) throws -> [UInt8]? {
        let scan = try scanSegments(bytes, url: url)
        guard let segment = scan.xmpSegment else { return nil }
        return Array(bytes[segment.packetStart..<segment.end])
    }

    // MARK: - 不改变像素数据的证据

    /// 供诊断使用：列出 JPEG 各段布局、XMP 段位置、图像数据起点。
    public static func describe(url: URL) throws -> String {
        let bytes = [UInt8](try Data(contentsOf: url))
        let scan = try? scanSegments(bytes, url: url)
        var lines: [String] = []
        lines.append("文件大小：\(bytes.count) 字节")
        if let xmp = scan?.xmpSegment {
            let packetBytes = bytes[xmp.packetStart..<xmp.end]
            lines.append("XMP 段：偏移 \(xmp.start)，数据包 \(packetBytes.count) 字节")
        } else {
            lines.append("XMP 段：无")
        }
        if let offset = scan?.scanDataOffset {
            lines.append("图像数据（SOS）起点：偏移 \(offset)，其后 \(bytes.count - offset) 字节为压缩像素数据")
        } else {
            lines.append("图像数据：未找到 SOS 标记")
        }
        return lines.joined(separator: "\n")
    }

    /// 返回从 SOS 标记开始到文件末尾的字节，用于比较「写入星级前后像素数据是否完全一致」。
    public static func pixelDataFingerprint(of url: URL) throws -> Data? {
        let bytes = [UInt8](try Data(contentsOf: url))
        let scan = try scanSegments(bytes, url: url)
        guard let offset = scan.scanDataOffset else { return nil }
        return Data(bytes[offset...])
    }
}
