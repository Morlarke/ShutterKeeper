import Foundation

/// EXIF 方向标记（1–8）与旋转换算。
///
/// 旋转是**非破坏性**的：只改方向标记，不动一个像素。Lightroom / Bridge 也是这么做的。
public enum EXIFOrientation {
    public static let tag: UInt16 = 0x0112

    /// 顺时针转 90° 之后的新方向标记。
    public static func rotatedClockwise(_ value: Int) -> Int {
        switch value {
        case 1: return 6
        case 6: return 3
        case 3: return 8
        case 8: return 1
        case 2: return 7
        case 7: return 4
        case 4: return 5
        case 5: return 2
        default: return 6
        }
    }

    /// 逆时针转 90° 之后的新方向标记。
    public static func rotatedCounterClockwise(_ value: Int) -> Int {
        switch value {
        case 1: return 8
        case 8: return 3
        case 3: return 6
        case 6: return 1
        case 2: return 5
        case 5: return 4
        case 4: return 7
        case 7: return 2
        default: return 8
        }
    }

    public static func rotated(_ value: Int, clockwise: Bool) -> Int {
        clockwise ? rotatedClockwise(value) : rotatedCounterClockwise(value)
    }

    /// 显示用文字，例如「向右转 90°」。
    public static func describe(_ value: Int) -> String {
        switch value {
        case 1: return "正常"
        case 3: return "已转 180°"
        case 6: return "已向右转 90°"
        case 8: return "已向左转 90°"
        case 2, 4, 5, 7: return "已镜像翻转（\(value)）"
        default: return "方向标记 \(value)"
        }
    }
}

/// 定位并改写文件内部的 EXIF 方向标记。
///
/// 支持两种封装：
/// * JPEG：Exif 在 APP1 段里，段内是 TIFF 结构
/// * TIFF / DNG：本身就是 TIFF 结构
///
/// 两种情况都只改写 entry 的 value 字段（2 字节），文件大小不变、像素不动。
public enum OrientationWriter {
    public enum WriteError: Error, LocalizedError {
        case fileUnreadable(URL)
        case notSupported(URL)
        case noOrientationTag(URL)
        case ioFailure(URL, String)

        public var errorDescription: String? {
            switch self {
            case .fileUnreadable(let url):
                return "读不到文件：\(url.lastPathComponent)"
            case .notSupported(let url):
                return "这个格式不支持写入方向标记：\(url.lastPathComponent)"
            case .noOrientationTag(let url):
                return "\(url.lastPathComponent) 里没有方向标记，无法修改"
            case .ioFailure(let url, let message):
                return "写入 \(url.lastPathComponent) 失败：\(message)"
            }
        }
    }

    /// 读取当前方向标记（1–8）。
    public static func readOrientation(of url: URL) throws -> Int? {
        guard let slot = try locateSlot(of: url) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw WriteError.fileUnreadable(url)
        }
        defer { try? handle.close() }
        try handle.seek(toOffset: slot.offset)
        guard let data = try handle.read(upToCount: slot.byteCount), let value = decode(data, byteCount: slot.byteCount, littleEndian: slot.littleEndian) else {
            return nil
        }
        return Int(value)
    }

    /// 写入方向标记。返回 false 表示文件里没有该标记（例如相机直出、缺 Orientation 的文件）。
    @discardableResult
    public static func writeOrientation(_ value: Int, to url: URL) throws -> Bool {
        guard let slot = try locateSlot(of: url) else { return false }
        guard let handle = try? FileHandle(forUpdating: url) else {
            throw WriteError.fileUnreadable(url)
        }
        defer { try? handle.close() }
        let data = encode(UInt32(max(1, min(8, value))), byteCount: slot.byteCount, littleEndian: slot.littleEndian)
        do {
            try handle.seek(toOffset: slot.offset)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw WriteError.ioFailure(url, error.localizedDescription)
        }
        return true
    }

    // MARK: - 内部

    struct Slot {
        let offset: UInt64
        let byteCount: Int
        let littleEndian: Bool
    }

    /// 方向标记在文件里的字节范围（校验「只改了这几个字节」时用）。
    public static func orientationByteRange(of url: URL) throws -> Range<Int>? {
        guard let slot = try locateSlot(of: url) else { return nil }
        let start = Int(slot.offset)
        return start..<(start + slot.byteCount)
    }

    static func locateSlot(of url: URL) throws -> Slot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw WriteError.fileUnreadable(url)
        }
        defer { try? handle.close() }

        let kind = MediaTypes.kind(for: url)
        let tiffBase: UInt64
        switch kind {
        case .jpeg:
            guard let base = try jpegExifBase(url: url, handle: handle) else { return nil }
            tiffBase = base
        case .tiff, .dng:
            tiffBase = 0
        default:
            throw WriteError.notSupported(url)
        }

        guard let header = try? read(handle, at: tiffBase, count: 8), header.count == 8 else { return nil }
        let littleEndian: Bool
        if header[0] == 0x49, header[1] == 0x49 {
            littleEndian = true
        } else if header[0] == 0x4D, header[1] == 0x4D {
            littleEndian = false
        } else {
            return nil
        }
        guard uint16(header, 2, littleEndian: littleEndian) == 42 else { return nil }
        let ifdOffset = UInt64(uint32(header, 4, littleEndian: littleEndian))
        let ifdBase = tiffBase + ifdOffset

        guard let countData = try? read(handle, at: ifdBase, count: 2), countData.count == 2 else { return nil }
        let entryCount = Int(uint16(countData, 0, littleEndian: littleEndian))
        guard entryCount > 0, entryCount < 4096 else { return nil }
        guard let entries = try? read(handle, at: ifdBase + 2, count: entryCount * 12),
              entries.count == entryCount * 12 else { return nil }

        for index in 0..<entryCount {
            let base = index * 12
            guard uint16(entries, base, littleEndian: littleEndian) == EXIFOrientation.tag else { continue }
            let type = uint16(entries, base + 2, littleEndian: littleEndian)
            let count = uint32(entries, base + 4, littleEndian: littleEndian)
            guard count == 1 else { return nil }
            switch type {
            case 3:  // SHORT
                return Slot(offset: ifdBase + 2 + UInt64(base) + 8, byteCount: 2, littleEndian: littleEndian)
            case 4:  // LONG
                return Slot(offset: ifdBase + 2 + UInt64(base) + 8, byteCount: 4, littleEndian: littleEndian)
            default:
                return nil
            }
        }
        return nil
    }

    /// JPEG 里 Exif APP1 段中 TIFF 头的绝对偏移。
    static func jpegExifBase(url: URL, handle: FileHandle) throws -> UInt64? {
        let identifier = Array("Exif\0\0".utf8)
        guard let head = try? read(handle, at: 0, count: 4), head.count == 4, head[0] == 0xFF, head[1] == 0xD8 else {
            throw WriteError.notSupported(url)
        }
        var offset: UInt64 = 2
        while true {
            guard let marker = try? read(handle, at: offset, count: 4), marker.count == 4 else { return nil }
            guard marker[0] == 0xFF else { return nil }
            let kind = marker[1]
            if kind == 0xDA || kind == 0xD9 { return nil }          // 到图像数据了
            let length = UInt64(UInt16(marker[2]) << 8 | UInt16(marker[3]))
            guard length >= 2 else { return nil }
            let payloadStart = offset + 4
            if kind == 0xE1 {
                if let prefix = try? read(handle, at: payloadStart, count: 6), prefix.count == 6, Array(prefix) == identifier {
                    return payloadStart + 6
                }
            }
            offset = payloadStart + (length - 2)
        }
    }

    static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data? {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count)
    }

    static func uint16(_ data: Data, _ index: Int, littleEndian: Bool) -> UInt16 {
        let bytes = [UInt8](data)
        let low = UInt16(bytes[index])
        let high = UInt16(bytes[index + 1])
        return littleEndian ? (low | high << 8) : (low << 8 | high)
    }

    static func uint32(_ data: Data, _ index: Int, littleEndian: Bool) -> UInt32 {
        let bytes = [UInt8](data)
        if littleEndian {
            return UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
                | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
        }
        return UInt32(bytes[index]) << 24 | UInt32(bytes[index + 1]) << 16
            | UInt32(bytes[index + 2]) << 8 | UInt32(bytes[index + 3])
    }

    static func decode(_ data: Data, byteCount: Int, littleEndian: Bool) -> UInt32? {
        guard data.count >= byteCount else { return nil }
        return byteCount == 2 ? UInt32(uint16(data, 0, littleEndian: littleEndian)) : uint32(data, 0, littleEndian: littleEndian)
    }

    static func encode(_ value: UInt32, byteCount: Int, littleEndian: Bool) -> Data {
        var bytes: [UInt8]
        if byteCount == 2 {
            let value16 = UInt16(value & 0xFFFF)
            bytes = littleEndian
                ? [UInt8(value16 & 0xFF), UInt8((value16 >> 8) & 0xFF)]
                : [UInt8((value16 >> 8) & 0xFF), UInt8(value16 & 0xFF)]
        } else {
            bytes = littleEndian
                ? [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
                : [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        return Data(bytes)
    }
}
