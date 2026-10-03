import Foundation

/// XMP 数据包（packet）的生成与就地修改。
///
/// 附属文件 `.xmp` 与 JPEG / PNG / TIFF 内部 XMP 使用同一份文本格式，因此读写逻辑共用。
public enum XMPPacket {
    public static let namespaceXMP = "http://ns.adobe.com/xap/1.0/"
    public static let namespaceTIFF = "http://ns.adobe.com/tiff/1.0/"
    public static let namespaceRDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    public static let namespaceAdobeMeta = "adobe:ns:meta/"
    /// JPEG APP1 段的标识字符串，以 NUL 结尾。
    public static let jpegAPP1Identifier = "http://ns.adobe.com/xap/1.0/"
    public static let toolkit = "ShutterKeeper beta-0.11"

    // MARK: - 生成

    /// 生成一个只含星级的最小 XMP 数据包。
    public static func packet(rating: Int) -> String {
        packet(values: [
            Attribute(prefix: "xmp", uri: namespaceXMP, name: "Rating", value: "\(max(0, min(5, rating)))"),
        ])
    }

    struct Attribute {
        let prefix: String
        let uri: String
        let name: String
        let value: String
    }

    static func packet(values: [Attribute]) -> String {
        var namespaces: [String] = []
        var attributes: [String] = []
        var seen = Set<String>()
        for value in values {
            if seen.insert(value.prefix).inserted {
                namespaces.append("xmlns:\(value.prefix)=\"\(value.uri)\"")
            }
            attributes.append("\(value.prefix):\(value.name)=\"\(value.value)\"")
        }
        let namespaceLines = namespaces.map { "    \($0)" }.joined(separator: "\n")
        let attributeLines = attributes.map { "    \($0)" }.joined(separator: "\n")
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="\(namespaceAdobeMeta)" x:xmptk="\(toolkit)">
         <rdf:RDF xmlns:rdf="\(namespaceRDF)">
          <rdf:Description rdf:about=""
        \(namespaceLines)
        \(attributeLines)/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    // MARK: - 读取

    /// 从任意一份 XMP 文本中读取星级。兼容属性写法与元素写法。
    public static func rating(in packet: String) -> Int? {
        value(of: "xmp:Rating", in: packet)
    }

    /// 读取方向标记（tiff:Orientation）。
    public static func orientation(in packet: String) -> Int? {
        value(of: "tiff:Orientation", in: packet)
    }

    static func value(of qualifiedName: String, in packet: String) -> Int? {
        let escaped = NSRegularExpression.escapedPattern(for: qualifiedName)
        let patterns = [
            "\(escaped)\\s*=\\s*\"(-?\\d+)\"",
            "\(escaped)\\s*=\\s*'(-?\\d+)'",
            "<\(escaped)>\\s*(-?\\d+)\\s*</\(escaped)>",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(packet.startIndex..., in: packet)
            guard let match = regex.firstMatch(in: packet, range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: packet) else { continue }
            if let value = Int(packet[valueRange]) { return value }
        }
        return nil
    }

    // MARK: - 修改

    /// 就地更新星级，其余内容（Lightroom 的修图设置、关键词等）原样保留。
    public static func settingRating(_ rating: Int, in packet: String) -> String {
        settingValue(
            attribute: Attribute(prefix: "xmp", uri: namespaceXMP, name: "Rating", value: "\(max(0, min(5, rating)))"),
            in: packet
        )
    }

    /// 就地更新方向标记（非破坏性旋转用）。
    public static func settingOrientation(_ orientation: Int, in packet: String) -> String {
        settingValue(
            attribute: Attribute(prefix: "tiff", uri: namespaceTIFF, name: "Orientation", value: "\(max(1, min(8, orientation)))"),
            in: packet
        )
    }

    static func settingValue(attribute: Attribute, in packet: String) -> String {
        let qualifiedName = "\(attribute.prefix):\(attribute.name)"
        let escaped = NSRegularExpression.escapedPattern(for: qualifiedName)

        // 1) 属性写法（双引号）
        if let result = replaceFirstMatch(
            pattern: "(\(escaped)\\s*=\\s*\")(-?\\d+)(\")",
            in: packet,
            with: attribute.value
        ) {
            return result
        }
        // 2) 属性写法（单引号）
        if let result = replaceFirstMatch(
            pattern: "(\(escaped)\\s*=\\s*')(-?\\d+)(')",
            in: packet,
            with: attribute.value
        ) {
            return result
        }
        // 3) 元素写法
        if let result = replaceFirstMatch(
            pattern: "(<\(escaped)>)(-?\\d+)(</\(escaped)>)",
            in: packet,
            with: attribute.value
        ) {
            return result
        }
        // 4) 没有这个字段：往第一个 rdf:Description 里加属性
        if let result = insertingAttribute(attribute, into: packet) {
            return result
        }
        // 5) 结构不认识：重写一份只含该字段的数据包
        return self.packet(values: [attribute])
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

    private static func insertingAttribute(_ attribute: Attribute, into packet: String) -> String? {
        guard let start = packet.range(of: "<rdf:Description") else { return nil }
        let searchRange = start.lowerBound..<packet.endIndex
        guard let tagEnd = packet.range(of: ">", range: searchRange) else { return nil }

        let tagText = packet[start.lowerBound..<tagEnd.lowerBound]
        var attributes = ""
        if !tagText.contains("xmlns:\(attribute.prefix)=") {
            attributes += "\n    xmlns:\(attribute.prefix)=\"\(attribute.uri)\""
        }
        attributes += "\n    \(attribute.prefix):\(attribute.name)=\"\(attribute.value)\""

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
