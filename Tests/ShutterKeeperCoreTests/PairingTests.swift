import Foundation
import Testing
@testable import ShutterKeeperCore

@Suite("RAW + JPG 配对")
struct PairingTests {
    @Test("同名 RAW 与 JPG 配成一张")
    func rawAndJpegPairUp() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = try TestSupport.makeFile("IMG_1234.CR3", in: directory)
        let jpeg = try TestSupport.makeFile("IMG_1234.JPG", in: directory)
        let groups = Pairing.group([raw, jpeg])

        #expect(groups.count == 1)
        #expect(groups[0].files.count == 2)
        #expect(groups[0].isPaired)
        #expect(groups[0].displayName == "IMG_1234.CR3", "配对后展示 RAW 名")
        #expect(groups[0].previewFile?.kind == .jpeg, "大图预览用 JPG")
    }

    @Test("主文件名匹配忽略大小写")
    func baseNameIsCaseInsensitive() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = try TestSupport.makeFile("img_0007.nef", in: directory)
        let jpeg = try TestSupport.makeFile("IMG_0007.jpg", in: directory)
        #expect(Pairing.group([raw, jpeg]).count == 1)
    }

    @Test("只有 RAW 也自成一张")
    func rawOnlyStillShows() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = try TestSupport.makeFile("DSC_5000.ARW", in: directory)
        let groups = Pairing.group([raw])
        #expect(groups.count == 1)
        #expect(!groups[0].isPaired)
        #expect(groups[0].previewFile?.kind == .proprietaryRAW)
        #expect(groups[0].isRatable)
    }

    @Test("同名视频不与照片合并")
    func videoDoesNotMergeWithPhoto() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let photo = try TestSupport.makeFile("IMG_2000.HEIC", in: directory)
        let video = try TestSupport.makeFile("IMG_2000.MOV", in: directory)
        #expect(Pairing.group([photo, video]).count == 2, "照片与视频各自成组")
    }

    @Test("扫描时忽略 .xmp 等附属文件")
    func sidecarsAreIgnored() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = try TestSupport.makeFile("IMG_3000.NEF", in: directory)
        try TestSupport.makeFile("IMG_3000.xmp", in: directory)
        try TestSupport.makeFile(".DS_Store", in: directory)
        let scan = try FolderScanner.scan(folder: directory, readMetadata: false)

        #expect(scan.groups.count == 1)
        #expect(scan.groups[0].files.count == 1)
        #expect(scan.groups[0].files[0].baseName == raw.baseName)
    }

    @Test("按拍摄日期排序，而不是文件名")
    func groupsSortByCaptureDate() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try TestSupport.writeJPEG(to: directory.appendingPathComponent("B.JPG"), captureDate: "2026:09:27 10:00:00")
        try TestSupport.writeJPEG(to: directory.appendingPathComponent("A.JPG"), captureDate: "2026:09:26 10:00:00")
        let scan = try FolderScanner.scan(folder: directory)

        #expect(scan.groups.map(\.displayName) == ["A.JPG", "B.JPG"])
    }

    @Test("删除配对时连侧车文件一起处理")
    func deletionTargetsIncludeSidecar() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = try TestSupport.makeFile("IMG_4000.NEF", in: directory)
        try XMPSidecar.writeRating(3, for: raw)
        let groups = Pairing.group([raw])
        #expect(groups[0].deletionTargets.map(\.fileName).sorted() == ["IMG_4000.NEF", "IMG_4000.xmp"])
    }
}
