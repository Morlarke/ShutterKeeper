import Foundation
import Testing
@testable import ShutterKeeperCore

@Suite("XMP 数据包读写")
struct XMPPacketTests {
    @Test("生成的 XMP 能被解析回星级")
    func generatedPacketIsParsable() {
        let packet = XMPPacket.packet(rating: 4)
        #expect(XMPPacket.rating(in: packet) == 4)
        #expect(packet.contains(#"xmp:Rating="4""#))
        #expect(packet.contains("http://ns.adobe.com/xap/1.0/"))
    }

    @Test("兼容属性写法与元素写法")
    func ratingParsingVariants() {
        #expect(XMPPacket.rating(in: #"<rdf:Description xmp:Rating="2"/>"#) == 2)
        #expect(XMPPacket.rating(in: #"<rdf:Description xmp:Rating='3'/>"#) == 3)
        #expect(XMPPacket.rating(in: "<xmp:Rating>5</xmp:Rating>") == 5)
        #expect(XMPPacket.rating(in: "<rdf:Description/>") == nil)
    }

    @Test("改星级不会破坏 Lightroom 的修图设置")
    func updatingRatingPreservesLightroomFields() {
        let updated = XMPPacket.settingRating(5, in: TestSupport.lightroomSidecar)
        #expect(XMPPacket.rating(in: updated) == 5)
        #expect(updated.contains(#"crs:Exposure2012="+0.35""#))
        #expect(updated.contains(#"crs:Contrast2012="+12""#))
        #expect(updated.contains("xmp:CreatorTool"))
        #expect(updated.contains("<crs:ToneCurveName2012>Medium Contrast</crs:ToneCurveName2012>"))

        let expected = TestSupport.lightroomSidecar.replacingOccurrences(
            of: #"xmp:Rating="0""#,
            with: #"xmp:Rating="5""#
        )
        #expect(updated == expected, "除星级外应当逐字符一致")
    }

    @Test("原来没有星级字段时就地插入")
    func insertingRatingWhenFieldIsMissing() {
        let withoutRating = TestSupport.lightroomSidecar.replacingOccurrences(
            of: "xmp:Rating=\"0\"\n",
            with: ""
        )
        let updated = XMPPacket.settingRating(2, in: withoutRating)
        #expect(XMPPacket.rating(in: updated) == 2)
        #expect(updated.contains(#"crs:Exposure2012="+0.35""#))
    }

    @Test("缺少 xmp 命名空间声明时自动补上")
    func insertingRatingAddsNamespace() {
        let minimal = #"<x:xmpmeta><rdf:RDF><rdf:Description rdf:about=""/></rdf:RDF></x:xmpmeta>"#
        let updated = XMPPacket.settingRating(3, in: minimal)
        #expect(XMPPacket.rating(in: updated) == 3)
        #expect(updated.contains(#"xmlns:xmp="http://ns.adobe.com/xap/1.0/""#))
    }

    @Test("星级超出范围时收敛到 0–5")
    func ratingIsClamped() {
        #expect(XMPPacket.rating(in: XMPPacket.packet(rating: 9)) == 5)
        #expect(XMPPacket.rating(in: XMPPacket.packet(rating: -3)) == 0)
    }
}
