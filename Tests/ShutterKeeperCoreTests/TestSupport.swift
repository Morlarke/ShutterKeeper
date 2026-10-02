import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import ShutterKeeperCore

enum TestSupport {
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 生成一张带 EXIF 的 JPEG，用来测试元数据写入。
    static func writeJPEG(
        to url: URL,
        width: Int = 64,
        height: Int = 48,
        captureDate: String = "2026:09:27 18:30:00"
    ) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        for y in 0..<height {
            for x in 0..<width {
                context.setFillColor(
                    red: CGFloat(x) / CGFloat(width),
                    green: CGFloat(y) / CGFloat(height),
                    blue: 0.3,
                    alpha: 1
                )
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.9,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: captureDate,
                ],
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func makeFile(_ name: String, in directory: URL, contents: String = "x") throws -> FileRef {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return FileRef(url: url)
    }

    /// 一段贴近 Lightroom 实际输出的侧车文件内容，用来验证「合并而不是覆盖」。
    static let lightroomSidecar = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000 1.000000, 0000/00/00-00:00:00        ">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmp:Rating="0"
        xmp:CreatorTool="Adobe Photoshop Lightroom Classic 13.0"
        crs:Exposure2012="+0.35"
        crs:Contrast2012="+12"
        crs:WhiteBalance="As Shot">
       <crs:ToneCurveName2012>Medium Contrast</crs:ToneCurveName2012>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>
    """
}
