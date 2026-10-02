import Foundation
import Testing
@testable import ShutterKeeperCore

@Suite("打分流与数据库")
struct RatingFlowTests {
    @Test("配对打分两种格式一起写")
    func pairWritesBothFormats() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let jpegURL = directory.appendingPathComponent("IMG_9000.JPG")
        try TestSupport.writeJPEG(to: jpegURL)
        let raw = try TestSupport.makeFile("IMG_9000.NEF", in: directory)

        let group = try #require(Pairing.group([FileRef(url: jpegURL), raw]).first)
        let outcome = RatingService.write(rating: 4, to: group)

        #expect(outcome.writtenFiles.count == 2)
        #expect(outcome.errors.isEmpty)
        #expect(try JPEGMetadataWriter.readRating(from: jpegURL) == 4)
        #expect(try XMPSidecar.readRating(for: raw) == 4)
        #expect(RatingService.readRatingFromFiles(for: group) == 4)
    }

    @Test("视频不打分")
    func videoIsSkipped() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let video = try TestSupport.makeFile("MVI_0001.MP4", in: directory)
        let group = try #require(Pairing.group([video]).first)
        let outcome = RatingService.write(rating: 5, to: group)

        #expect(outcome.writtenFiles.isEmpty)
        #expect(outcome.skippedFiles.count == 1)
        #expect(RatingService.readRatingFromFiles(for: group) == nil)
    }

    @Test("DNG 首版只记录在软件内")
    func dngIsDatabaseOnly() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let dng = try TestSupport.makeFile("IMG_6000.DNG", in: directory)
        let group = try #require(Pairing.group([dng]).first)
        let outcome = RatingService.write(rating: 3, to: group)

        #expect(outcome.writtenFiles.isEmpty)
        #expect(outcome.databaseOnlyFiles.count == 1)
    }

    @Test("已有侧车文件时合并不覆盖")
    func sidecarMergesInsteadOfOverwriting() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let rawURL = directory.appendingPathComponent("IMG_7000.NEF")
        try Data("raw".utf8).write(to: rawURL)
        let sidecarURL = rawURL.deletingPathExtension().appendingPathExtension("xmp")
        try Data(TestSupport.lightroomSidecar.utf8).write(to: sidecarURL)

        try XMPSidecar.writeRating(3, for: FileRef(url: rawURL))

        let text = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(text.contains(#"xmp:Rating="3""#))
        #expect(text.contains(#"crs:Exposure2012="+0.35""#), "Lightroom 修图设置不能被覆盖掉")
        #expect(text.contains("xmp:CreatorTool"))
    }

    @Test("数据库读写与最近项目")
    func ratingStoreRoundTrip() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let paths = AppPaths(root: directory.appendingPathComponent("support", isDirectory: true))
        try paths.ensureDirectories()
        let store = try RatingStore(databaseURL: paths.databaseURL)
        let folder = directory.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try store.setRating(5, folder: folder, baseName: "IMG_1234", captureDate: Date(), primaryPath: nil, isVideo: false)
        #expect(try store.rating(folder: folder, baseName: "img_1234") == 5, "查找忽略大小写")
        #expect(try store.ratings(inFolder: folder).count == 1)

        try store.touchFolder(folder)
        #expect(try store.recentFolders().first?.path == folder.standardizedFileURL.path)

        try store.deleteAllRatings()
        #expect(try store.assetCount(inFolder: folder) == 0)
        #expect(try store.recentFolders().count == 1, "清空评分不影响最近项目列表")
    }

    @Test("删掉数据库后能从文件里恢复星级")
    func ratingsRecoverFromFiles() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let jpegURL = directory.appendingPathComponent("IMG_8000.JPG")
        try TestSupport.writeJPEG(to: jpegURL)
        let raw = try TestSupport.makeFile("IMG_8000.NEF", in: directory)
        let group = try #require(Pairing.group([FileRef(url: jpegURL), raw]).first)
        _ = RatingService.write(rating: 2, to: group)

        let rescanned = try FolderScanner.scan(folder: directory)
        let recovered = rescanned.groups.compactMap { RatingService.readRatingFromFiles(for: $0) }
        #expect(recovered == [2])
    }

    @Test("扩展名到媒体类型的映射")
    func mediaKindMapping() {
        #expect(MediaTypes.kind(forPathExtension: "NEF") == .proprietaryRAW)
        #expect(MediaTypes.kind(forPathExtension: "cr3") == .proprietaryRAW)
        #expect(MediaTypes.kind(forPathExtension: "jpg") == .jpeg)
        #expect(MediaTypes.kind(forPathExtension: "DNG") == .dng)
        #expect(MediaTypes.kind(forPathExtension: "heic") == .heic)
        #expect(MediaTypes.kind(forPathExtension: "MOV") == .video)
        #expect(MediaTypes.kind(forPathExtension: "txt") == .other)
        #expect(MediaTypes.isSidecar(pathExtension: "XMP"))
    }

    @Test("EXIF 读取与格式化")
    func exifReadingAndFormatting() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let jpegURL = directory.appendingPathComponent("IMG_9100.JPG")
        try TestSupport.writeJPEG(to: jpegURL, captureDate: "2024:05:06 07:08:09")
        let metadata = try ExifReader.read(url: jpegURL)

        #expect(MetadataFormatting.date(metadata.captureDate, dateFormat: "yyyy-MM-dd HH:mm:ss") == "2024-05-06 07:08:09")
        #expect(MetadataFormatting.aperture(2.8) == "f/2.8")
        #expect(MetadataFormatting.shutter(1.0 / 250) == "1/250 s")
        #expect(MetadataFormatting.iso(400) == "ISO 400")
        #expect(MetadataFormatting.focalLength(14) == "14 mm")
        #expect(MetadataFormatting.dimensions(metadata) == "64 × 48")
    }
}
