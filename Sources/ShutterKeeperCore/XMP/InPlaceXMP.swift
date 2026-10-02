import Foundation

/// 在原地写入 XMP 时共用的工具。
///
/// TIFF 与 PNG 都把 XMP 放在文件内部一个「长度已经固定」的容器里
/// （TIFF 是 tag 700，PNG 是 iTXt 块），而且通常会留出大段空格做 padding。
/// 因此可以在不改变文件长度、不搬动任何其它字节的前提下更新星级 ——
/// 对几百 MB 的扫描 TIFF 来说这点很关键。
enum InPlaceXMP {
    enum Error: Swift.Error {
        case doesNotFit(available: Int, needed: Int)
    }

    /// 把文本调整到恰好 `length` 字节。
    ///
    /// * 短了：把空格补在 `<?xpacket end` 之前（XMP 规范里的 padding 位置）
    /// * 长了：先吃掉 padding 里的空格 —— 这正是 padding 的用途
    ///   （例如原来没有 `xmp:Rating` 字段，插入后会多出十几个字节）
    static func fitted(_ text: String, toByteCount length: Int) throws -> Data {
        var current = text
        if current.utf8.count > length {
            guard let trimmed = trimmingPadding(current, toByteCount: length) else {
                throw Error.doesNotFit(available: length, needed: current.utf8.count)
            }
            current = trimmed
        }
        var data = Data(current.utf8)
        let deficit = length - data.count
        guard deficit > 0 else {
            guard data.count == length else {
                throw Error.doesNotFit(available: length, needed: data.count)
            }
            return data
        }
        if let trailerRange = current.range(of: "<?xpacket end") {
            let padded = current[..<trailerRange.lowerBound]
                + String(repeating: " ", count: deficit)
                + current[trailerRange.lowerBound...]
            data = Data(String(padded).utf8)
        } else {
            data.append(Data(repeating: 0x20, count: deficit))
        }
        guard data.count == length else {
            throw Error.doesNotFit(available: length, needed: data.count)
        }
        return data
    }

    /// 吃掉 padding 里的空白，把文本缩到目标长度。
    private static func trimmingPadding(_ text: String, toByteCount length: Int) -> String? {
        let excess = text.utf8.count - length
        guard excess > 0 else { return text }

        let trailerMarker = "<?xpacket end"
        guard let trailerRange = text.range(of: trailerMarker) else {
            // 没有 trailer：从末尾删空白
            var candidate = Substring(text)
            var removed = 0
            while removed < excess, let last = candidate.last, last == " " || last == "\n" || last == "\t" {
                candidate = candidate.dropLast()
                removed += 1
            }
            guard removed >= excess else { return nil }
            return String(candidate)
        }

        // 只在 padding 区（正文与 trailer 之间）删空白
        var head = Substring(text[..<trailerRange.lowerBound])
        var removed = 0
        while removed < excess, let last = head.last, last == " " || last == "\n" || last == "\t" {
            head = head.dropLast()
            removed += 1
        }
        guard removed >= excess else { return nil }
        return String(head) + text[trailerRange.lowerBound...]
    }
}

/// PNG 用的 CRC32（多项式 0xEDB88320）。
public enum PNGCRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}
