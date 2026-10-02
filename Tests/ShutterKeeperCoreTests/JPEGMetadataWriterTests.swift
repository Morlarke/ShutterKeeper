import Foundation
import Testing
@testable import ShutterKeeperCore

@Suite("JPG 内部元数据写入")
struct JPEGMetadataWriterTests {
    @Test("写星级不会动到压缩像素数据")
    func writingRatingKeepsPixelsIdentical() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("IMG_0001.JPG")
        try TestSupport.writeJPEG(to: url)
        let before = try #require(try JPEGMetadataWriter.pixelDataFingerprint(of: url))

        try JPEGMetadataWriter.writeRating(4, to: url)

        let after = try #require(try JPEGMetadataWriter.pixelDataFingerprint(of: url))
        #expect(before == after, "压缩像素数据必须一个字节都不变")
        #expect(try JPEGMetadataWriter.readRating(from: url) == 4)
    }

    @Test("ImageIO 自己能读回星级（Lightroom 走同一套标准）")
    func imageIOReadsBackRating() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("IMG_0002.JPG")
        try TestSupport.writeJPEG(to: url)
        try JPEGMetadataWriter.writeRating(3, to: url)

        #expect(ExifReader.ratingFromImageMetadata(url: url) == 3)
    }

    @Test("反复改星级只保留一个 XMP 段")
    func repeatedWritesKeepSingleSegment() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("IMG_0003.JPG")
        try TestSupport.writeJPEG(to: url)

        for rating in [1, 2, 5, 0] {
            try JPEGMetadataWriter.writeRating(rating, to: url)
            #expect(try JPEGMetadataWriter.readRating(from: url) == rating)
        }

        let description = try JPEGMetadataWriter.describe(url: url)
        let mentions = description.components(separatedBy: "XMP 段：").count - 1
        #expect(mentions == 1)
        #expect(!description.contains("XMP 段：无"))
    }

    @Test("原始 EXIF 在写入后仍然完好")
    func exifSurvivesRewrite() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("IMG_0004.JPG")
        try TestSupport.writeJPEG(to: url, captureDate: "2025:01:02 03:04:05")
        let before = try ExifReader.read(url: url)

        try JPEGMetadataWriter.writeRating(2, to: url)

        let after = try ExifReader.read(url: url)
        #expect(before.captureDate == after.captureDate)
        #expect(before.pixelWidth == after.pixelWidth)
        #expect(before.pixelHeight == after.pixelHeight)
    }

    @Test("不是 JPEG 就报错，不瞎写")
    func rejectsNonJPEG() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("not-an-image.JPG")
        try Data("definitely not a jpeg".utf8).write(to: url)

        #expect(throws: (any Error).self) {
            try JPEGMetadataWriter.writeRating(3, to: url)
        }
    }

    @Test("第二次写入是原地替换，不是追加")
    func mergesIntoExistingPacket() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("IMG_0005.JPG")
        try TestSupport.writeJPEG(to: url)
        try JPEGMetadataWriter.writeRating(1, to: url)
        let firstSize = try Data(contentsOf: url).count

        try JPEGMetadataWriter.writeRating(5, to: url)
        let secondSize = try Data(contentsOf: url).count

        #expect(try JPEGMetadataWriter.readRating(from: url) == 5)
        #expect(abs(secondSize - firstSize) < 64, "文件不应明显增长")
    }
}
