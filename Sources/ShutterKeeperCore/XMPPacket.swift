import Foundation

/// XMP 数据包（packet）的生成与就地修改。
///
/// 附属文件 `.xmp` 与 JPEG 内部 XMP 使用同一份文本格式，因此读写逻辑共用。
public enum XMPPacket {
    public static let namespaceXMP = "http://ns.adobe.com/xap/1.0/"
    public static let namespaceRDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let namespaceAdobeMeta = "adobe:ns:meta/"
    /// JPEG APP1 段的标识字符串，以 NUL 结尾。
    public static let jpegAPP1Identifier = "http://ns.adobe.com/xap/1.0/"
    public static let toolkit = "ShutterKeeper 0.1"

    /// 生成一个只含星级的最小 XMP 数据包。
    public static func packet(rating: Int) -> String {
        let clamped = max(0, min(5, rating))
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="\(namespaceAdobeMeta)" x:xmptk="\(toolkit)">
         <rdf:RDF xmlns:rdf="\(namespaceRDF)">
          <rdf:Description rdf:about=""
            xmlns:xmp="\(namespaceXMP)"
            xmp:Rating="\(clamped)"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    /// 从任意一份 XMP 文本中读取星级。兼容属性写法与元素写法。
    public static func rating(in packet: String) -> Int? {
        for pattern in [
            #"xmp:Rating\s*=\s*"(-?\d+)""#,
            #"xmp:Rating\s*=\s*'(-?\d+)'"#,
            #"<xmp:Rating>\s*(-?\d+)\s*</xmp:Rating>"#,
        ] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(packet.startIndex..., in: packet)
            guard let match = regex.firstMatch(in: packet, range: range) else { continue }
            guard match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: packet) else { continue }
            if let value = Int(packet[valueRange]) { return value }
        }
        return nil
    }

    /// 在已有 XMP 文本中就地更新星级，其余内容（Lightroom 的修图设置、关键词等）原样保留。
    ///
    /// 如果没有星级字段，只往第一个 `rdf:Description` 元素里加一个属性，不重写整份文档。
    public static func settingRating(_ rating: Int, in packet: String) -> String {
        let clamped = max(0, min(5, rating))

        // 1) 属性写法：xmp:Rating="3"
        if let result = replaceFirstMatch(
            pattern: #"(xmp:Rating\s*=\s*")(-?\d+)(")"#,
            in: packet,
            with: "\(clamped)"
        ) {
            return result
        }
        // 2) 属性写法（单引号）
        if let result = replaceFirstMatch(
            pattern: #"(xmp:Rating\s*=\s*')(-?\d+)(')"#,
            in: packet,
            with: "\(clamped)"
        ) {
            return result
        }
        // 3) 元素写法：<xmp:Rating>3</xmp:Rating>
        if let result = replaceFirstMatch(
            pattern: #"(<xmp:Rating>)(-?\d+)(</xmp:Rating>)"#,
            in: packet,
            with: "\(clamped)"
        ) {
            return result
        }
        // 4) 没有星级字段：往第一个 rdf:Description 里加属性
        if let result = insertingRatingAttribute(clamped, into: packet) {
            return result
        }
        // 5) 结构不认识：整份重写（此刻文档里没有任何我们要保留的字段）
        return self.packet(rating: clamped)
    }

    // MARK: - 内部实现

    private static func replaceFirstMatch(pattern: String, in text: String, with replacement: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 2 else { return nil }
        guard let valueRange = Range(match.range(at: 2), in: text) else { return nil }
        var result = text
        result.replaceSubrange(valueRange, with: replacement)
        return result
    }

    private static func insertingRatingAttribute(_ rating: Int, into packet: String) -> String? {
        guard let start = packet.range(of: "<rdf:Description") else { return nil }
        let searchRange = start.lowerBound..<packet.endIndex
        guard let tagEnd = packet.range(of: ">", range: searchRange) else { return nil }

        let tagText = packet[start.lowerBound..<tagEnd.lowerBound]
        var attributes = ""
        if !tagText.contains("xmlns:xmp=") {
            attributes += "\n    xmlns:xmp=\"\(namespaceXMP)\""
        }
        attributes += "\n    xmp:Rating=\"\(rating)\""

        // 自闭合写法 <rdf:Description ... /> 必须插在 “/” 之前，
        // 否则会把 “/>” 劈成 “/” 和 “>”，生成非法 XML（Lightroom 就再也读不了了）。
        var insertIndex = tagEnd.lowerBound
        if insertIndex > start.lowerBound {
            var probe = packet.index(before: insertIndex)
            while probe > start.lowerBound,
                  packet[probe] == " " || packet[probe] == "\n" || packet[probe] == "\t" {
                probe = packet.index(before: probe)
            }
            if packet[probe] == "/" {
                insertIndex = probe
            }
        }

        var result = packet
        result.insert(contentsOf: attributes, at: insertIndex)
        return result
    }
}
