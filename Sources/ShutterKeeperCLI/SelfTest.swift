import CoreGraphics
import Foundation
import ImageIO
import ShutterKeeperCore
import UniformTypeIdentifiers

/// 端到端自检。
///
/// 在临时目录里造素材、跑完整个打分流，最后把目录删掉，不留痕迹。
/// 这条路径不依赖测试框架，任何一台装了 Command Line Tools 的 Mac 都能跑。
struct SelfTest {
    private var failures: [String] = []
    private var checkCount = 0

    private mutating func section(_ title: String) {
        print("\n\(title)")
    }

    private mutating func check(_ condition: Bool, _ label: String) {
        checkCount += 1
        print("  \(condition ? "✓" : "✗") \(label)")
        if !condition { failures.append(label) }
    }

    mutating func run() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skctl-selftest-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("无法创建临时目录：\(error.localizedDescription)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try mediaTypes()
            try xmpPackets(root: root)
            try jpegMetadata(root: root)
            try pairing(root: root)
            try ratingFlow(root: root)
            try database(root: root)
            try lightroomSync(root: root)
            try rename(root: root)
            try imageFormats(root: root)
            try importFlow(root: root)
            reviewSession()
            shortcuts()
        } catch {
            print("\n自检中断：\(error.localizedDescription)")
            return false
        }

        print("")
        if failures.isEmpty {
            print("自检全部通过：\(checkCount) 项检查 ✓")
            return true
        }
        print("自检失败 \(failures.count)/\(checkCount) 项：")
        for failure in failures { print("  - \(failure)") }
        return false
    }

    // MARK: - 类型判断

    private mutating func mediaTypes() throws {
        section("1. 文件类型识别")
        check(MediaTypes.kind(forPathExtension: "NEF") == .proprietaryRAW, "NEF 走侧车文件")
        check(MediaTypes.kind(forPathExtension: "CR3") == .proprietaryRAW, "CR3 走侧车文件")
        check(MediaTypes.kind(forPathExtension: "ARW") == .proprietaryRAW, "ARW 走侧车文件")
        check(MediaTypes.kind(forPathExtension: "jpg") == .jpeg, "JPG 写内部元数据")
        check(MediaTypes.kind(forPathExtension: "DNG") == .dng, "DNG 单独归类")
        check(MediaTypes.kind(forPathExtension: "heic") == .heic, "HEIC 单独归类")
        check(MediaTypes.kind(forPathExtension: "MOV") == .video, "MOV 是视频")
        check(MediaTypes.isSidecar(pathExtension: "XMP"), "XMP 附属文件被识别")
    }

    // MARK: - XMP

    private mutating func xmpPackets(root: URL) throws {
        section("2. XMP 数据包")
        let packet = XMPPacket.packet(rating: 4)
        check(XMPPacket.rating(in: packet) == 4, "生成的 XMP 能解析回 4 星")
        check(XMPPacket.rating(in: #"<rdf:Description xmp:Rating="2"/>"#) == 2, "解析属性写法（双引号）")
        check(XMPPacket.rating(in: #"<rdf:Description xmp:Rating='3'/>"#) == 3, "解析属性写法（单引号）")
        check(XMPPacket.rating(in: "<xmp:Rating>5</xmp:Rating>") == 5, "解析元素写法")
        check(XMPPacket.rating(in: XMPPacket.packet(rating: 9)) == 5, "超过 5 星收敛到 5")

        // 模拟 Lightroom 写过的侧车文件
        let lightroomSidecar = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmp:Rating="0"
            xmp:CreatorTool="Adobe Photoshop Lightroom Classic 13.0"
            crs:Exposure2012="+0.35"
            crs:Contrast2012="+12">
           <crs:ToneCurveName2012>Medium Contrast</crs:ToneCurveName2012>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
        let merged = XMPPacket.settingRating(5, in: lightroomSidecar)
        check(XMPPacket.rating(in: merged) == 5, "在 LR 侧车里改星级")
        check(merged.contains(#"crs:Exposure2012="+0.35""#), "LR 曝光设置原样保留")
        check(merged.contains("xmp:CreatorTool"), "LR 的 CreatorTool 原样保留")
        let expected = lightroomSidecar.replacingOccurrences(of: #"xmp:Rating="0""#, with: #"xmp:Rating="5""#)
        check(merged == expected, "除星级外逐字符一致")

        let withoutRating = lightroomSidecar.replacingOccurrences(of: "xmp:Rating=\"0\"\n", with: "")
        let inserted = XMPPacket.settingRating(2, in: withoutRating)
        check(XMPPacket.rating(in: inserted) == 2, "原文件没有星级字段时能插入")
        check(inserted.contains(#"crs:Exposure2012="+0.35""#), "插入后 LR 设置仍在")

        // 真实侧车文件读写
        let rawURL = root.appendingPathComponent("SELFTEST_RAW.NEF")
        try Data("fake-raw".utf8).write(to: rawURL)
        let raw = FileRef(url: rawURL)
        try XMPSidecar.writeRating(3, for: raw)
        check(try XMPSidecar.readRating(for: raw) == 3, "侧车文件写入并读回 3 星")
        check(FileManager.default.fileExists(atPath: raw.sidecarURL.path), "侧车文件名为同主名 .xmp")
    }

    // MARK: - JPG 内部元数据

    private mutating func jpegMetadata(root: URL) throws {
        section("3. JPG 内部元数据（这是与 Lightroom 协作的关键）")
        let url = root.appendingPathComponent("SELFTEST_JPG.JPG")
        try ShutterKeeperCLI.writeTestJPEG(to: url, captureDate: "2026:09:27 18:30:00")

        let pixelsBefore = try JPEGMetadataWriter.pixelDataFingerprint(of: url)
        let exifBefore = try ExifReader.read(url: url)
        let sizeBefore = try Data(contentsOf: url).count
        check(pixelsBefore != nil, "测试图生成成功（\(sizeBefore) 字节）")

        try JPEGMetadataWriter.writeRating(4, to: url)
        check(try JPEGMetadataWriter.readRating(from: url) == 4, "本程序读回 4 星")
        check(ExifReader.ratingFromImageMetadata(url: url) == 4, "ImageIO 独立解析也是 4 星")

        let pixelsAfter = try JPEGMetadataWriter.pixelDataFingerprint(of: url)
        check(pixelsBefore == pixelsAfter, "压缩像素数据逐字节未变")
        let exifAfter = try ExifReader.read(url: url)
        check(exifBefore.captureDate == exifAfter.captureDate, "拍摄日期未变")
        check(exifBefore.pixelWidth == exifAfter.pixelWidth, "图像尺寸未变")

        try JPEGMetadataWriter.writeRating(2, to: url)
        check(try JPEGMetadataWriter.readRating(from: url) == 2, "改成 2 星后读回正确")
        let description = try JPEGMetadataWriter.describe(url: url)
        let xmpMentions = description.components(separatedBy: "XMP 段：").count - 1
        check(xmpMentions == 1, "反复写入后文件里始终只有一个 XMP 段")

        let brokenURL = root.appendingPathComponent("SELFTEST_BROKEN.JPG")
        try Data("not a jpeg".utf8).write(to: brokenURL)
        var threwError = false
        do {
            try JPEGMetadataWriter.writeRating(3, to: brokenURL)
        } catch {
            threwError = true
        }
        check(threwError, "遇到损坏文件时报错而不是瞎写")
    }

    // MARK: - 配对

    private mutating func pairing(root: URL) throws {
        section("4. RAW + JPG 配对")
        let folder = root.appendingPathComponent("pairing", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 注意：macOS 默认大小写不敏感，所以主名只差大小写的两个文件要落在不同的文件名上
        try ShutterKeeperCLI.writeTestJPEG(to: folder.appendingPathComponent("IMG_1234.JPG"))
        try Data("raw".utf8).write(to: folder.appendingPathComponent("img_1234.CR3"))
        try Data("raw".utf8).write(to: folder.appendingPathComponent("DSC_5000.ARW"))
        try Data("heic".utf8).write(to: folder.appendingPathComponent("IMG_2000.HEIC"))
        try Data("video".utf8).write(to: folder.appendingPathComponent("IMG_2000.MOV"))
        try Data("sidecar".utf8).write(to: folder.appendingPathComponent("IMG_1234.xmp"))

        let scan = try FolderScanner.scan(folder: folder, readMetadata: false)
        check(scan.groups.count == 4, "4 组：配对组、单张 ARW、HEIC、MOV（实际 \(scan.groups.count)）")

        let pair = scan.groups.first { $0.files.count == 2 }
        check(pair?.files.count == 2, "大小写不同的 IMG_1234.JPG 与 img_1234.CR3 配成一对（实际 \(pair?.files.count ?? 0) 个文件）")
        check(pair?.isPaired == true, "标记为配对组")
        check(pair?.previewFile?.kind == .jpeg, "大图预览选 JPG")
        let rawOnly = scan.groups.first { $0.displayName == "DSC_5000.ARW" }
        check(rawOnly != nil, "只有 RAW 的也成一张")
        check(rawOnly?.previewFile?.kind == .proprietaryRAW, "单张 RAW 用自己做大图")
        check(scan.groups.filter { $0.baseName.uppercased() == "IMG_2000" }.count == 2, "同名 HEIC 与 MOV 各自成组")
        check(scan.groups.allSatisfy { group in group.files.allSatisfy { $0.fileExtension != "xmp" } }, "附属文件不出现在列表里")
    }

    // MARK: - 打分流

    private mutating func ratingFlow(root: URL) throws {
        section("5. 打分与写盘")
        let folder = root.appendingPathComponent("rating", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let jpegURL = folder.appendingPathComponent("IMG_7001.JPG")
        try ShutterKeeperCLI.writeTestJPEG(to: jpegURL)
        let raw = FileRef(url: folder.appendingPathComponent("IMG_7001.NEF"))
        try Data("raw".utf8).write(to: raw.url)

        let group = try XCTUnwrapLike(Pairing.group([FileRef(url: jpegURL), raw]).first)
        let outcome = RatingService.write(rating: 4, to: group)
        check(outcome.writtenFiles.count == 2, "配对打分同时写了 JPG 和 RAW 侧车")
        check(outcome.errors.isEmpty, "没有写入错误")
        check(try JPEGMetadataWriter.readRating(from: jpegURL) == 4, "JPG 读到 4 星")
        check(try XMPSidecar.readRating(for: raw) == 4, "NEF 的 .xmp 读到 4 星（Lightroom 读的就是它）")
        check(RatingService.readRatingFromFiles(for: group) == 4, "整组读回 4 星")

        let videoURL = folder.appendingPathComponent("MVI_0001.MP4")
        try Data("video".utf8).write(to: videoURL)
        let videoGroup = try XCTUnwrapLike(Pairing.group([FileRef(url: videoURL)]).first)
        let videoOutcome = RatingService.write(rating: 5, to: videoGroup)
        check(videoOutcome.skippedFiles.count == 1 && videoOutcome.writtenFiles.isEmpty, "视频不打分")

        let dngURL = folder.appendingPathComponent("IMG_7002.DNG")
        try Data("dng".utf8).write(to: dngURL)
        let dngGroup = try XCTUnwrapLike(Pairing.group([FileRef(url: dngURL)]).first)
        let dngOutcome = RatingService.write(rating: 2, to: dngGroup)
        check(dngOutcome.databaseOnlyFiles.count == 1, "DNG 首版只记在软件内（不写文件）")
    }

    // MARK: - 数据库

    private mutating func database(root: URL) throws {
        section("6. 评分数据库与恢复")
        let paths = AppPaths(root: root.appendingPathComponent("support", isDirectory: true))
        try paths.ensureDirectories()
        let store = try RatingStore(databaseURL: paths.databaseURL)
        let folder = root.appendingPathComponent("rating", isDirectory: true)

        try store.setRating(4, folder: folder, baseName: "IMG_7001", captureDate: nil, primaryPath: nil, isVideo: false)
        check(try store.rating(folder: folder, baseName: "IMG_7001") == 4, "数据库写入并读回 4 星")
        check(try store.rating(folder: folder, baseName: "img_7001") == 4, "查找忽略大小写")
        try store.touchFolder(folder)
        check(try store.recentFolders().first?.path == folder.standardizedFileURL.path, "最近项目已记录")

        try store.deleteAllRatings()
        check(try store.assetCount(inFolder: folder) == 0, "清空评分数据库")
        check(try store.recentFolders().count == 1, "清空评分不影响最近项目列表")

        let rescanned = try FolderScanner.scan(folder: folder)
        let recovered = rescanned.groups.compactMap { RatingService.readRatingFromFiles(for: $0) }
        check(recovered.contains(4), "删库后从文件里恢复出星级：\(recovered.sorted())")
    }

    // MARK: - 审阅模块逻辑

    /// 导入：项目文件夹命名、RAW+JPG 配对、附属文件、备份、历史、冲突、取消。
    private mutating func importFlow(root: URL) throws {
        section("14. 导入")
        let card = root.appendingPathComponent("FakeCard", isDirectory: true)
        let dcim = card.appendingPathComponent("DCIM/100CANON", isDirectory: true)
        let destination = root.appendingPathComponent("目标", isDirectory: true)
        let backup = root.appendingPathComponent("备份", isDirectory: true)
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)

        // 2 组 RAW+JPG、1 个侧车文件、1 个视频
        for base in ["A_0001", "A_0002"] {
            try ShutterKeeperCLI.writeTestJPEG(
                to: dcim.appendingPathComponent("\(base).JPG"),
                captureDate: "2026:09:27 10:00:00"
            )
            try Data("raw-\(base)".utf8).write(to: dcim.appendingPathComponent("\(base).NEF"))
        }
        try Data(XMPPacket.packet(rating: 3).utf8).write(to: dcim.appendingPathComponent("A_0001.xmp"))
        try Data("video".utf8).write(to: dcim.appendingPathComponent("MVI_0001.MOV"))

        let databaseURL = root.appendingPathComponent("import-history.sqlite")
        let history = try ImportHistoryStore(databaseURL: databaseURL)

        // 1. 扫描来源
        let mediaURLs = VolumeScanner.mediaFiles(in: card)
        check(mediaURLs.count == 6, "从卡里找到 6 个文件（实际 \(mediaURLs.count)）")
        let refs = mediaURLs.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey])
            return FileRef(url: url, fileSize: values?.fileSize.map(Int64.init), creationDate: values?.creationDate)
        }

        // 2. 计划
        let settings = ImportSettings(projectName: "婚礼", destinationRoot: destination)
        let plan = ImportPlanner.plan(
            sourceFiles: refs,
            settings: settings,
            volumeName: "FakeCard",
            sourceRoot: card,
            importedHistory: []
        )
        check(plan.projectFolderName == "20260927_婚礼", "项目文件夹名：20260927_婚礼（实际 \(plan.projectFolderName)）")
        check(plan.photoCount == 2 && plan.pairedCount == 2, "照片 2 张、其中配对 2 组")
        check(plan.videoCount == 1, "视频 1 个")
        check(plan.tasks.count == 6, "共 6 个文件要搬（实际 \(plan.tasks.count)）")
        check(plan.conflicts.isEmpty, "首次导入没有冲突")
        check(plan.hasEnoughSpace, "目标空间够用")

        // 3. 执行导入
        var options = ImportExecutor.Options()
        options.history = history
        options.volumeName = "FakeCard"
        options.sourceRoot = card
        let outcome = ImportExecutor.run(plan: plan, options: options)
        check(outcome.failures.isEmpty, "导入没有失败项")
        check(outcome.copied.count == 6, "复制了 6 个文件（实际 \(outcome.copied.count)）")

        let photos = plan.projectURL.appendingPathComponent("Photos")
        let videos = plan.projectURL.appendingPathComponent("Videos")
        check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("A_0001.NEF").path), "RAW 进了 Photos/")
        check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("A_0001.JPG").path), "JPG 进了 Photos/")
        check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("A_0001.xmp").path), "侧车文件跟着进了 Photos/")
        check(FileManager.default.fileExists(atPath: videos.appendingPathComponent("MVI_0001.MOV").path), "视频进了 Videos/")
        let sourceSize = (try? dcim.appendingPathComponent("A_0001.NEF").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let copiedSize = (try? photos.appendingPathComponent("A_0001.NEF").resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        check(sourceSize == copiedSize, "拷贝出来的文件大小与源一致")

        // 4. 导入历史
        let keys = try history.keys(forVolume: "FakeCard")
        check(keys.count == 6, "历史里记了 6 条（实际 \(keys.count)）")

        // 5. 再导入一次：应识别为「之前导入过」
        let secondPlan = ImportPlanner.plan(
            sourceFiles: refs,
            settings: settings,
            volumeName: "FakeCard",
            sourceRoot: card,
            importedHistory: keys
        )
        check(secondPlan.conflicts.count == 6, "第二次导入识别出 6 个冲突（实际 \(secondPlan.conflicts.count)）")
        check(secondPlan.conflicts.allSatisfy { $0.kind == .alreadyImported }, "冲突类型是「之前导入过」")
        let skipOutcome = ImportExecutor.run(plan: secondPlan)
        check(skipOutcome.copied.isEmpty && skipOutcome.skipped.count == 6, "冲突的文件全部跳过")

        // 6. 目标文件夹已存在 → 建一个带后缀的新文件夹
        let alternative = ImportPlanner.availableFolderName(base: plan.projectFolderName, in: destination)
        check(alternative == "20260927_婚礼-2", "目标重名时的新名字：20260927_婚礼-2（实际 \(alternative)）")

        // 7. 备份：结构与主导入一致
        var backupSettings = settings
        backupSettings.projectName = "备份测试"
        backupSettings.backupRoot = backup
        backupSettings.copyToBackup = true
        let backupPlan = ImportPlanner.plan(
            sourceFiles: refs,
            settings: backupSettings,
            volumeName: "FakeCard",
            sourceRoot: card,
            importedHistory: []
        )
        let backupOutcome = ImportExecutor.run(plan: backupPlan)
        check(backupOutcome.backupFailures.isEmpty, "备份没有失败项")
        let backupPhotos = backupPlan.projectURL.appendingPathComponent("Photos")
        let backupVideos = backupPlan.projectURL.appendingPathComponent("Videos")
        check(
            backupPlan.settings.backupRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("20260927_备份测试/Photos/A_0001.JPG").path) } == true,
            "备份目录结构与主导入完全一致"
        )
        check(
            backupPlan.settings.backupRoot.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("20260927_备份测试/Videos/MVI_0001.MOV").path) } == true,
            "备份里视频也在 Videos/"
        )
        _ = backupPhotos
        _ = backupVideos

        // 8. 取消：立刻取消不应该留下任何文件
        let cancelDestination = root.appendingPathComponent("取消目标", isDirectory: true)
        try FileManager.default.createDirectory(at: cancelDestination, withIntermediateDirectories: true)
        let cancelPlan = ImportPlanner.plan(
            sourceFiles: refs,
            settings: ImportSettings(projectName: "取消测试", destinationRoot: cancelDestination),
            volumeName: "FakeCard",
            sourceRoot: card,
            importedHistory: []
        )
        var cancelOptions = ImportExecutor.Options()
        cancelOptions.shouldCancel = { true }
        let cancelOutcome = ImportExecutor.run(plan: cancelPlan, options: cancelOptions)
        check(cancelOutcome.cancelled, "取消被正确标记")
        check(cancelOutcome.copied.isEmpty, "取消后没有拷贝成功的文件")
        let leftover = (try? FileManager.default.contentsOfDirectory(
            at: cancelPlan.projectURL.appendingPathComponent("Photos"),
            includingPropertiesForKeys: nil
        )) ?? []
        check(leftover.isEmpty, "取消后目标里没有残留文件（实际 \(leftover.count) 个）")
    }

    /// 图片格式覆盖：TIFF / PNG 的内部 XMP 原地写入，以及扩展名映射。
    private mutating func imageFormats(root: URL) throws {
        section("13. 图片格式：TIFF / PNG / 其它常见格式")

        // 合并后的 XMP 必须是合法 XML —— 自闭合标签写错过一次，Lightroom 会直接读不了
        let selfClosing = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"/></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        let mergedSelfClosing = XMPPacket.settingRating(4, in: selfClosing)
        check(XMPPacket.rating(in: mergedSelfClosing) == 4, "自闭合 rdf:Description 能写入星级")
        check(Self.isWellFormedXML(mergedSelfClosing), "自闭合写法合并后仍是合法 XML")
        check(mergedSelfClosing.contains("/>\n") || mergedSelfClosing.contains("\n    xmp:Rating=\"4\"/>") || mergedSelfClosing.contains("xmp:Rating=\"4\"/\u{3E}"), "自闭合标签没有被劈开")

        let mergedAttribute = XMPPacket.settingRating(2, in: #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="0"/></rdf:RDF></x:xmpmeta>"#)
        check(Self.isWellFormedXML(mergedAttribute), "属性写法合并后仍是合法 XML")
        let mergedElement = XMPPacket.settingRating(3, in: #"<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about=""><xmp:Rating>1</xmp:Rating></rdf:Description></rdf:RDF></x:xmpmeta>"#)
        check(Self.isWellFormedXML(mergedElement), "元素写法合并后仍是合法 XML")

        // 扩展名映射
        check(MediaTypes.kind(forPathExtension: "tif") == .tiff, "TIF 是图片（TIFF）")
        check(MediaTypes.kind(forPathExtension: "TIFF") == .tiff, "TIFF 是图片（忽略大小写）")
        check(MediaTypes.kind(forPathExtension: "png") == .png, "PNG 是图片")
        check(MediaTypes.kind(forPathExtension: "psd") == .psd, "PSD 归类为 Photoshop 文件")
        check(MediaTypes.kind(forPathExtension: "webp") == .otherImage, "WebP 等其它图片格式也能识别")
        check(MediaTypes.kind(forPathExtension: "gif") == .otherImage, "GIF 也能识别")
        check(MediaTypes.kind(forPathExtension: "heic") == .heic, "HEIC 分类不变")
        check(MediaTypes.kind(forPathExtension: "mov") == .video, "视频分类不变")

        // TIFF：文件内 XMP（tag 700）原地写入
        let tiffURL = root.appendingPathComponent("SELFTEST.TIF")
        try TestTIFF.write(to: tiffURL, rating: nil, padding: 512)
        let tiffOutsideBefore = try TestTIFF.bytesOutsideXMP(at: tiffURL)
        let tiffSizeBefore = try Data(contentsOf: tiffURL).count
        check(try TIFFXMPWriter.readRating(from: tiffURL) == nil, "TIFF 初始没有星级")
        check(try TIFFXMPWriter.xmpSegment(in: tiffURL) != nil, "TIFF 里能定位到 XMP 段")
        check(try TIFFXMPWriter.writeRating(4, to: tiffURL), "TIFF 写入 4 星")
        check(try TIFFXMPWriter.readRating(from: tiffURL) == 4, "TIFF 读回 4 星")
        check(ExifReader.ratingFromImageMetadata(url: tiffURL) == 4, "ImageIO 也能从 TIFF 读到 4 星")
        check(try Data(contentsOf: tiffURL).count == tiffSizeBefore, "TIFF 写入后文件大小不变")
        check(try TestTIFF.bytesOutsideXMP(at: tiffURL) == tiffOutsideBefore, "TIFF 除 XMP 段外一个字节都没动")
        check(try TIFFXMPWriter.writeRating(2, to: tiffURL), "TIFF 改成 2 星")
        check(try TIFFXMPWriter.readRating(from: tiffURL) == 2, "TIFF 读回 2 星")

        // 没有 XMP 段的 TIFF：应明确汇报「写不进去」而不是乱写
        let bareTIFF = root.appendingPathComponent("SELFTEST-NOXMP.TIF")
        try TestTIFF.write(to: bareTIFF, rating: nil, padding: 0, includeXMP: false)
        check(try TIFFXMPWriter.xmpSegment(in: bareTIFF) == nil, "没有 XMP 段的 TIFF 能被识别出来")
        check(try TIFFXMPWriter.writeRating(3, to: bareTIFF) == false, "没有 XMP 段时不写文件，返回 false")

        // PNG：文件内 XMP（iTXt 块）原地写入
        let pngURL = root.appendingPathComponent("SELFTEST.PNG")
        try TestPNG.write(to: pngURL, rating: 0, padding: 512)
        let pngOutsideBefore = try TestPNG.bytesOutsideXMP(at: pngURL)
        let pngSizeBefore = try Data(contentsOf: pngURL).count
        let pngCRCBefore = try TestPNG.chunkCRC(at: pngURL)
        check(try PNGXMPWriter.readRating(from: pngURL) == 0, "PNG 初始 0 星")
        check(try PNGXMPWriter.writeRating(5, to: pngURL), "PNG 写入 5 星")
        check(try PNGXMPWriter.readRating(from: pngURL) == 5, "PNG 读回 5 星")
        check(ExifReader.ratingFromImageMetadata(url: pngURL) == 5, "ImageIO 也能从 PNG 读到 5 星")
        check(try Data(contentsOf: pngURL).count == pngSizeBefore, "PNG 写入后文件大小不变")
        let pngCRCAfter = try TestPNG.chunkCRC(at: pngURL)
        check(
            pngCRCAfter == PNGCRC32.checksum(try TestPNG.chunkCRCInput(at: pngURL)),
            "PNG 的 CRC 已按新内容重算"
        )
        check(pngCRCAfter != pngCRCBefore, "PNG 的 CRC 确实变了（内容变了 CRC 必须变）")
        check(try TestPNG.bytesOutsideXMP(at: pngURL) == pngOutsideBefore, "PNG 除 XMP 块与 CRC 外一个字节都没动")

        // 走完整的打分链路：AssetGroup → RatingService
        let group = AssetGroup(
            folder: root,
            baseName: "SELFTEST",
            files: [FileRef(url: tiffURL), FileRef(url: pngURL)]
        )
        let outcome = RatingService.write(rating: 3, to: group)
        check(outcome.writtenFiles.count == 2, "TIF + PNG 都写进了文件（实际 \(outcome.writtenFiles.count)）")
        check(outcome.databaseOnlyFiles.isEmpty, "没有落到「只能存软件内」的")
        check(RatingService.readRatingFromFiles(for: group) == 3, "整组读回 3 星")
    }

    /// 批量改名：模板、分组序列号、配对联动、附属文件、冲突、撤销。
    private mutating func rename(root: URL) throws {
        section("12. 批量改名")
        let folder = root.appendingPathComponent("rename", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 第一天：2 组 RAW+JPG 配对；第二天：1 张单独 JPG；再加一个视频
        let day1 = "2026:09:27 10:00:00"
        let day2 = "2026:09:28 11:00:00"
        makePair(folder: folder, base: "DSC_0001", captureDate: day1)
        makePair(folder: folder, base: "DSC_0002", captureDate: day1)
        try ShutterKeeperCLI.writeTestJPEG(to: folder.appendingPathComponent("DSC_0003.JPG"), captureDate: day2)
        try Data("video".utf8).write(to: folder.appendingPathComponent("MVI_0001.MOV"))
        // 给第一对加一个 Lightroom 侧车文件
        try Data(XMPPacket.packet(rating: 3).utf8).write(to: folder.appendingPathComponent("DSC_0001.xmp"))

        let scan = try FolderScanner.scan(folder: folder)
        check(scan.groups.count == 4, "识别出 4 张片子（实际 \(scan.groups.count)）")

        let settings = RenameSettings()
        // 先空跑一次拿到分组 id，再按组填自定义文本
        let probe = RenamePlanner.plan(groups: scan.groups, settings: settings)
        var texts: [String: String] = [:]
        for bucket in probe.renameGroups {
            if bucket.isVideo {
                texts[bucket.id] = "花絮"
            } else if bucket.id.hasPrefix("2026-09-27") {
                texts[bucket.id] = "婚礼"
            } else if bucket.id.hasPrefix("2026-09-28") {
                texts[bucket.id] = "外景"
            }
        }
        let plan = RenamePlanner.plan(groups: scan.groups, texts: texts, settings: settings)

        check(plan.renameGroups.count == 3, "分成 3 组：27 日照片、28 日照片、视频（实际 \(plan.renameGroups.count)）")
        let photoDay1 = plan.renameGroups.first { $0.id == "2026-09-27#p" }
        check(photoDay1?.count == 2, "27 日照片组 2 张")
        check(photoDay1?.text == "婚礼", "27 日组的自定义文本是「婚礼」")
        check(plan.example == "20260927_婚礼_001.NEF", "模板示例：20260927_婚礼_001.NEF（实际 \(plan.example ?? "无")）")

        // 配对共用主名、扩展名各自保留
        let targets = plan.operations.map { $0.finalURL.lastPathComponent }
        check(targets.contains("20260927_婚礼_001.NEF"), "RAW 目标名 \(targets.first(where: { $0.hasSuffix(".NEF") }) ?? "无")")
        check(targets.contains("20260927_婚礼_001.JPG"), "JPG 与 RAW 共用主文件名")
        check(targets.contains("20260927_婚礼_001.xmp"), "侧车文件跟着改名为 20260927_婚礼_001.xmp")
        check(targets.contains("20260927_婚礼_002.NEF"), "同组第二张序列号递增为 002")
        check(targets.contains("20260928_外景_001.JPG"), "第二天序列号重新从 001 开始")
        let videoTarget = targets.first { $0.hasSuffix(".MOV") }
        check(videoTarget?.contains("_花絮_001.MOV") == true, "视频单独一套序列号（\(videoTarget ?? "无")）")

        // 文件清单预览：图标视图与分栏视图靠它显示「所有文件」
        let previewNames = plan.files.map(\.originalName)
        check(plan.files.count == 7, "文件清单列出全部 7 个文件（实际 \(plan.files.count)）")
        check(previewNames.contains("DSC_0001.NEF"), "清单里有 RAW")
        check(previewNames.contains("DSC_0001.JPG"), "清单里有 JPG")
        check(previewNames.contains("DSC_0001.xmp"), "清单里有侧车文件")
        let jpegPreview = plan.files.first { $0.originalName == "DSC_0001.JPG" }
        check(jpegPreview?.newName == "20260927_婚礼_001.JPG", "JPG 的新名字：\(jpegPreview?.newName ?? "无")")
        check(jpegPreview?.kind == .jpeg, "JPG 的类型标记正确")
        check(plan.files.first { $0.originalName == "DSC_0001.xmp" }?.isSidecar == true, "侧车文件被标记为附属文件")

        // 多段自定义文本：日期_文本1_文本2_序号
        let multiPlan = RenamePlanner.plan(
            groups: scan.groups,
            texts: ["2026-09-27#p": "婚礼_新娘"],
            settings: settings
        )
        check(multiPlan.example == "20260927_婚礼_新娘_001.NEF", "两段自定义文本：\(multiPlan.example ?? "无")")
        let threePlan = RenamePlanner.plan(
            groups: scan.groups,
            texts: ["2026-09-27#p": "婚礼_新娘_精修"],
            settings: settings
        )
        check(threePlan.example == "20260927_婚礼_新娘_精修_001.NEF", "三段自定义文本：\(threePlan.example ?? "无")")

        // 执行改名
        let outcome = RenameExecutor.apply(plan: plan)
        check(outcome.failures.isEmpty, "改名没有失败项")
        check(outcome.renamed.count == plan.operations.count, "全部文件都改了（\(outcome.renamed.count) 个）")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("20260927_婚礼_001.NEF").path), "新文件名已存在")
        check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC_0001.NEF").path), "旧文件名已消失")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("20260927_婚礼_001.xmp").path), "侧车文件跟着改了")

        // 撤销
        let undo = RenameExecutor.undo(outcome.renamed)
        check(undo.failures.isEmpty, "撤销没有失败项")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC_0001.NEF").path), "撤销后旧文件名回来了")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("DSC_0001.xmp").path), "撤销后侧车文件名也回来了")

        // 冲突检测：把目标名先占住
        try Data("occupied".utf8).write(to: folder.appendingPathComponent("20260927_婚礼_001.NEF"))
        let conflictPlan = RenamePlanner.plan(groups: scan.groups, texts: texts, settings: settings)
        check(conflictPlan.conflicts.count == 1, "检测到 1 个冲突（实际 \(conflictPlan.conflicts.count)）")
        let skipOutcome = RenameExecutor.apply(
            plan: conflictPlan,
            skipping: Set(conflictPlan.conflicts.map { $0.source.standardizedFileURL })
        )
        check(skipOutcome.failures.isEmpty, "选择跳过后其余文件正常改名")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("20260927_婚礼_002.NEF").path), "未冲突的照常改名")
    }

    /// 造一对同名的 RAW + JPG。
    private func makePair(folder: URL, base: String, captureDate: String) {
        try? ShutterKeeperCLI.writeTestJPEG(
            to: folder.appendingPathComponent("\(base).JPG"),
            captureDate: captureDate
        )
        try? Data("raw".utf8).write(to: folder.appendingPathComponent("\(base).NEF"))
    }

    /// 用一份自造的 Lightroom 目录验证「从 LR 目录同步星级」的完整链路。
    private mutating func lightroomSync(root: URL) throws {
        section("9. 从 Lightroom 目录同步星级")
        let folder = root.appendingPathComponent("lightroom", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // 造 3 张片子：两张 RAW 一张 JPG
        let rawA = folder.appendingPathComponent("IMG_A.NEF")
        let rawB = folder.appendingPathComponent("IMG_B.NEF")
        let jpegC = folder.appendingPathComponent("IMG_C.JPG")
        try Data("raw".utf8).write(to: rawA)
        try Data("raw".utf8).write(to: rawB)
        try ShutterKeeperCLI.writeTestJPEG(to: jpegC)

        // 造一份最小可用的 Lightroom 目录（结构取自真实 .lrcat）
        let catalogURL = root.appendingPathComponent("Fake.lrcat")
        let catalog = try SQLiteDatabase(path: catalogURL.path)
        try catalog.execute("CREATE TABLE AgLibraryRootFolder (id_local INTEGER PRIMARY KEY, absolutePath TEXT);")
        try catalog.execute("CREATE TABLE AgLibraryFolder (id_local INTEGER PRIMARY KEY, pathFromRoot TEXT, rootFolder INTEGER);")
        try catalog.execute("CREATE TABLE AgLibraryFile (id_local INTEGER PRIMARY KEY, baseName TEXT, extension TEXT, folder INTEGER);")
        try catalog.execute("CREATE TABLE Adobe_images (id_local INTEGER PRIMARY KEY, rating REAL, rootFile INTEGER);")
        try catalog.run(
            "INSERT INTO AgLibraryRootFolder (id_local, absolutePath) VALUES (?, ?);",
            [.integer(1), .text(folder.standardizedFileURL.path + "/")]
        )
        try catalog.run("INSERT INTO AgLibraryFolder (id_local, pathFromRoot, rootFolder) VALUES (1, '', 1);")
        try catalog.run("INSERT INTO AgLibraryFile (id_local, baseName, extension, folder) VALUES (10, 'IMG_A', 'NEF', 1), (11, 'IMG_B', 'NEF', 1), (12, 'IMG_C', 'JPG', 1);")
        // A 打了 3 星、B 没打分（0）、C 打了 5 星
        try catalog.run("INSERT INTO Adobe_images (id_local, rating, rootFile) VALUES (100, 3.0, 10), (101, 0.0, 11), (102, 5.0, 12);")

        let lrCatalog = LightroomCatalog(url: catalogURL)
        let ratings = try lrCatalog.ratings(under: folder)
        check(ratings.count == 2, "读目录：只有打了分的 2 张（实际 \(ratings.count)）")
        check(ratings[rawA.standardizedFileURL.path] == 3, "IMG_A.NEF 读到 3 星")
        check(ratings[jpegC.standardizedFileURL.path] == 5, "IMG_C.JPG 读到 5 星")

        let scan = try FolderScanner.scan(folder: folder, readMetadata: false)
        let plan = LightroomSync.plan(groups: scan.groups, catalogRatings: ratings)
        check(plan.total == 3, "文件夹里 3 张片子")
        check(plan.updates.count == 2, "需要写入 2 张（实际 \(plan.updates.count)）")
        check(plan.notInCatalog == 1, "目录里没打分的 1 张被跳过")

        let outcome = LightroomSync.apply(plan: plan)
        check(outcome.errors.isEmpty, "写入没有报错")
        let secondRead = try LightroomCatalog(url: catalogURL).ratings(under: folder)
        let afterPlan = LightroomSync.plan(groups: scan.groups, catalogRatings: secondRead)
        check(afterPlan.updates.isEmpty, "再次对比：已经没有需要写入的")
        check(afterPlan.alreadyMatching == 2, "2 张已与目录一致")

        // 验证真的写进了文件
        let rawRef = FileRef(url: rawA)
        check(try XMPSidecar.readRating(for: rawRef) == 3, "NEF 侧车文件里是 3 星")
        check(try JPEGMetadataWriter.readRating(from: jpegC) == 5, "JPG 内部元数据里是 5 星")
    }

    private mutating func reviewSession() {
        section("10. 审阅：选中、导航、筛选、日期分组")

        // 造 6 张片子：9 月 27 日 3 张、9 月 28 日 3 张
        let day1 = Date(timeIntervalSince1970: 1_790_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        let folder = URL(fileURLWithPath: "/tmp/selftest-review")
        var groups: [AssetGroup] = []
        for index in 0..<6 {
            let date = index < 3 ? day1.addingTimeInterval(Double(index) * 60) : day2.addingTimeInterval(Double(index - 3) * 60)
            let file = FileRef(url: folder.appendingPathComponent("IMG_\(1000 + index).JPG"))
            groups.append(AssetGroup(folder: folder, baseName: file.baseName, files: [file], captureDate: date))
        }
        var session = ReviewSession(groups: groups)

        check(session.visibleCount == 6, "初始显示 6 张")
        check(session.current?.baseName == "IMG_1000", "默认选中第一张")

        session.selectNext()
        session.selectNext()
        check(session.current?.baseName == "IMG_1002", "右方向键前进到第 3 张")
        session.selectPrevious()
        check(session.current?.baseName == "IMG_1001", "左方向键退回第 2 张")

        check(session.dateGroups.count == 2, "按拍摄日期分成 2 组（实际 \(session.dateGroups.count)）")
        check(session.dateGroups.first?.count == 3, "第一组 3 张")
        session.selectNextDateGroup()
        check(session.current?.baseName == "IMG_1003", "下方向键跳到第二天第一张")
        session.selectPreviousDateGroup()
        check(session.current?.baseName == "IMG_1000", "上方向键跳回第一天第一张")

        // 打分 + 筛选
        session.setRating(5, for: groups[0].id)
        session.setRating(3, for: groups[3].id)
        session.applyFilter(RatingFilter(isActive: true, comparison: .atLeast, stars: 4))
        check(session.visibleCount == 1, "筛选 ≥4 星后只剩 1 张（实际 \(session.visibleCount)）")
        check(session.current?.baseName == "IMG_1000", "当前这张没被筛掉就保持不变")

        session.applyFilter(RatingFilter(isActive: true, comparison: .exactly, stars: 3))
        check(session.visibleCount == 1, "筛选 =3 星只剩 1 张")
        check(session.current?.baseName == "IMG_1003", "当前被筛掉时自动跳到符合条件的那张")

        session.applyFilter(.inactive)
        check(session.visibleCount == 6, "清除筛选后恢复 6 张")

        // 删除后的落点
        session.select(id: groups[2].id)
        session.removeCurrent()
        check(session.current?.baseName == "IMG_1003", "删掉第 3 张后选中原位置的那一张")
        check(session.visibleCount == 5, "删除后总数减一")
    }

    // MARK: - 快捷键

    private mutating func shortcuts() {
        section("11. 快捷键：默认值、场景区分、冲突检测")
        let suiteName = "sk-selftest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let store = ShortcutStore(defaults: defaults)

        check(store.shortcut(for: .rate3).displayString == "3", "默认 3 星就是数字键 3")
        check(store.shortcut(for: .next).displayString == "→", "默认下一张是右方向键")
        check(store.shortcut(for: .filterAtLeast2).displayString == "⌥⌘2", "默认筛选 ≥2 星是 ⌘⌥2")

        let space = KeyShortcut(keyCode: 49)
        check(store.action(for: space, context: .photo) == .toggleFullScreen, "照片时按空格＝全屏")
        check(store.action(for: space, context: .video) == .videoPlayPause, "视频时按空格＝播放/暂停")
        check(store.action(for: KeyShortcut(keyCode: 126), context: .video) == .volumeUp, "视频时按 ↑＝音量 +")
        check(store.action(for: KeyShortcut(keyCode: 126), context: .photo) == .previousDateGroup, "照片时按 ↑＝上一组")

        var conflictDetected = false
        do {
            try store.set(KeyShortcut(keyCode: 124), for: .previous)
        } catch {
            conflictDetected = true
        }
        check(conflictDetected, "把「上一张」改成 → 会检测出与「下一张」冲突")

        var spaceConflict = false
        do {
            try store.set(space, for: .rate0)
        } catch {
            spaceConflict = true
        }
        check(spaceConflict, "把 0 星改成空格会与全屏/播放冲突")

        try? store.set(KeyShortcut(keyCode: 0, modifiers: [.command]), for: .deleteCurrent)
        check(store.shortcut(for: .deleteCurrent).displayString == "⌘A", "自定义快捷键已保存")
        check(store.isCustomized(.deleteCurrent), "标记为已自定义")
        store.reset(.deleteCurrent)
        check(store.shortcut(for: .deleteCurrent).displayString == "⌫", "恢复默认快捷键")
    }

    private func XCTUnwrapLike<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileNoSuchFile) }
        return value
    }

    /// 用系统 XML 解析器确认一段 XMP 是合法 XML。
    static func isWellFormedXML(_ text: String) -> Bool {
        let parser = XMLParser(data: Data(text.utf8))
        return parser.parse()
    }
}
