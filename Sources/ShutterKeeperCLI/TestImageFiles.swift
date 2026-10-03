import Foundation
import ShutterKeeperCore

/// 自检用的最小 TIFF：1×1 图 + 可选 XMP 段（tag 700），带 padding。
enum TestTIFF {
    static func write(to url: URL, rating: Int?, padding: Int, includeXMP: Bool = true) throws {
        var data = Data()
        data.append(contentsOf: [0x49, 0x49])            // 小端
        data.append(littleEndian: UInt16(42))
        data.append(littleEndian: UInt32(8))             // IFD0 偏移

        var xmp = xmpText(rating: rating, padding: padding)
        var xmpBytes = [UInt8](xmp.utf8)

        // 条目：ImageWidth/Length、BitsPerSample、Compression、Photometric、
        // Orientation、StripOffsets、SamplesPerPixel、RowsPerStrip、StripByteCounts（+ XMP）
        let entryCount = includeXMP ? 11 : 10
        let dataStart = 8 + 2 + entryCount * 12 + 4
        let pixelOffset = dataStart
        let xmpOffset = pixelOffset + 1

        data.append(littleEndian: UInt16(entryCount))

        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            data.append(littleEndian: tag)
            data.append(littleEndian: type)
            data.append(littleEndian: count)
            data.append(littleEndian: value)
        }
        entry(256, 4, 1, 1)                              // ImageWidth
        entry(257, 4, 1, 1)                              // ImageLength
        entry(258, 3, 1, 8)                              // BitsPerSample: 8（单通道，内联）
        entry(259, 3, 1, 1)                              // Compression: none
        entry(262, 3, 1, 1)                              // Photometric: BlackIsZero
        entry(274, 3, 1, 1)                              // Orientation: 正常
        entry(273, 4, 1, UInt32(pixelOffset))            // StripOffsets
        entry(277, 3, 1, 1)                              // SamplesPerPixel
        entry(278, 4, 1, 1)                              // RowsPerStrip
        entry(279, 4, 1, 1)                              // StripByteCounts
        if includeXMP {
            entry(700, 1, UInt32(xmpBytes.count), UInt32(xmpOffset))
        }
        data.append(littleEndian: UInt32(0))             // 没有下一个 IFD

        // 数据区
        data.append(0x7F)                                // 唯一的像素
        if includeXMP {
            data.append(contentsOf: xmpBytes)
        }
        xmpBytes.removeAll()
        xmp.removeAll()
        try data.write(to: url)
    }

    /// 除 XMP 段以外的全部字节（用来证明写入没有碰到别处）。
    static func bytesOutsideXMP(at url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard let range = try xmpRange(at: url) else { return raw }
        var result = raw.prefix(range.offset)
        result.append(raw.suffix(from: range.offset + range.length))
        return Data(result)
    }

    static func xmpRange(at url: URL) throws -> (offset: Int, length: Int)? {
        let raw = try Data(contentsOf: url)
        guard raw.count > 8, raw[0] == 0x49, raw[1] == 0x49 else { return nil }
        let ifdOffset = Int(littleEndianUInt32(raw, 4))
        let count = Int(littleEndianUInt16(raw, ifdOffset))
        for index in 0..<count {
            let base = ifdOffset + 2 + index * 12
            guard base + 12 <= raw.count else { break }
            let tag = littleEndianUInt16(raw, base)
            guard tag == 700 else { continue }
            let length = Int(littleEndianUInt32(raw, base + 4))
            let offset = Int(littleEndianUInt32(raw, base + 8))
            return (offset, length)
        }
        return nil
    }

    static func xmpText(rating: Int?, padding: Int) -> String {
        let ratingAttribute = rating.map { #" xmp:Rating="\#($0)""# } ?? ""
        let body = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"\(ratingAttribute)/></rdf:RDF></x:xmpmeta>
        """
        return "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + body
            + String(repeating: " ", count: max(0, padding))
            + "<?xpacket end=\"w\"?>"
    }

    static func littleEndianUInt16(_ data: Data, _ index: Int) -> UInt16 {
        UInt16(data[index]) | UInt16(data[index + 1]) << 8
    }

    static func littleEndianUInt32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index]) | UInt32(data[index + 1]) << 8
            | UInt32(data[index + 2]) << 16 | UInt32(data[index + 3]) << 24
    }
}

/// 自检用的最小 PNG：IHDR + iTXt(XMP) + IDAT + IEND。
enum TestPNG {
    static func write(to url: URL, rating: Int?, padding: Int) throws {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var ihdr = Data()
        ihdr.append(bigEndian: UInt32(1))                // 宽
        ihdr.append(bigEndian: UInt32(1))                // 高
        ihdr.append(contentsOf: [8, 2, 0, 0, 0])         // 8 位、真彩色、无压缩
        data.append(chunk(type: "IHDR", payload: [UInt8](ihdr)))

        let xmp = TestTIFF.xmpText(rating: rating, padding: padding)
        var payload = [UInt8]("XML:com.adobe.xmp".utf8)
        payload.append(0)                                // 关键字结束
        payload.append(0)                                // 压缩标志：未压缩
        payload.append(0)                                // 压缩方法
        payload.append(0)                                // 语言标签（空）
        payload.append(0)                                // 翻译关键字（空）
        payload.append(contentsOf: Array(xmp.utf8))
        data.append(chunk(type: "iTXt", payload: payload))

        data.append(chunk(type: "IDAT", payload: [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01]))
        data.append(chunk(type: "IEND", payload: []))
        try data.write(to: url)
    }

    static func chunk(type: String, payload: [UInt8]) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(payload.count))
        let typeBytes = [UInt8](type.utf8)
        data.append(contentsOf: typeBytes)
        data.append(contentsOf: payload)
        var crcInput = typeBytes
        crcInput.append(contentsOf: payload)
        data.append(bigEndian: PNGCRC32.checksum(crcInput))
        return data
    }

    static func xmpChunkRange(at url: URL) throws -> (dataOffset: Int, length: Int, crcOffset: Int)? {
        let raw = try Data(contentsOf: url)
        var offset = 8
        while offset + 8 <= raw.count {
            let length = Int(bigEndianUInt32(raw, offset))
            let type = String(bytes: raw[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            if type == "iTXt" {
                let dataOffset = offset + 8
                if raw.count > dataOffset + 19,
                   String(bytes: raw[dataOffset..<(dataOffset + 17)], encoding: .utf8) == "XML:com.adobe.xmp" {
                    return (dataOffset, length, dataOffset + length)
                }
            }
            if type == "IEND" { return nil }
            offset = offset + 8 + length + 4
        }
        return nil
    }

    /// 除 XMP 块数据与它的 CRC 以外的全部字节。
    static func bytesOutsideXMP(at url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard let range = try xmpChunkRange(at: url) else { return raw }
        var result = raw.prefix(range.dataOffset)
        result.append(raw.suffix(from: range.crcOffset + 4))
        return Data(result)
    }

    static func chunkCRC(at url: URL) throws -> UInt32? {
        let raw = try Data(contentsOf: url)
        guard let range = try xmpChunkRange(at: url), range.crcOffset + 4 <= raw.count else { return nil }
        return bigEndianUInt32(raw, range.crcOffset)
    }

    static func chunkCRCInput(at url: URL) throws -> [UInt8] {
        let raw = try Data(contentsOf: url)
        guard let range = try xmpChunkRange(at: url) else { return [] }
        return Array(raw[(range.dataOffset - 4)..<(range.crcOffset)])
    }

    static func bigEndianUInt32(_ data: Data, _ index: Int) -> UInt32 {
        UInt32(data[index]) << 24 | UInt32(data[index + 1]) << 16
            | UInt32(data[index + 2]) << 8 | UInt32(data[index + 3])
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    mutating func append(bigEndian value: UInt32) {
        append(contentsOf: [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }
}
