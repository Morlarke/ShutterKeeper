import CoreGraphics
import Foundation
import ImageIO
import ShutterKeeperCore
import UniformTypeIdentifiers

/// `skctl` —— 快门闪选的命令行诊断工具。
///
/// 界面还在施工期间，用它来验证元数据读写是否符合 Lightroom Classic 的预期。
@main
struct ShutterKeeperCLI {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else {
            printHelp()
            exit(2)
        }
        let rest = Array(arguments.dropFirst())

        do {
            switch command {
            case "help", "-h", "--help":
                printHelp()
            case "paths":
                try commandPaths()
            case "scan":
                try commandScan(rest)
            case "info":
                try commandInfo(rest)
            case "get":
                try commandGet(rest)
            case "rate":
                try commandRate(rest)
            case "check":
                try commandCheck(rest)
            case "preview":
                try commandPreview(rest)
            case "review":
                try commandReview(rest)
            case "lr":
                try commandLightroom(rest)
            case "rename":
                try commandRename(rest)
            case "mktiff":
                // 诊断用：造一个最小的 TIFF（带 XMP 段）出来，方便验证写入逻辑
                guard let path = rest.first else {
                    fail("用法：skctl mktiff <输出路径> [初始星级]")
                    exit(2)
                }
                let rating = rest.count > 1 ? Int(rest[1]) : nil
                try TestTIFF.write(to: URL(fileURLWithPath: path), rating: rating, padding: 512)
                print("已生成 \(path)")
            case "import":
                try commandImport(rest)
            case "rotate":
                try commandRotate(rest)
            case "selftest":
                runSelfTest()
            default:
                fail("未知命令：\(command)\n")
                printHelp()
                exit(2)
            }
        } catch {
            fail("错误：\(error.localizedDescription)")
            exit(1)
        }
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printHelp() {
        print(
            """
            skctl —— 快门闪选命令行诊断工具

            用法：
              skctl paths                     显示数据库与缓存目录
              skctl scan <文件夹>              扫描文件夹，列出「一张片子」分组
              skctl info <文件>...             显示文件元数据
              skctl get <文件>...              从文件里读取星级（含 ImageIO 交叉验证）
              skctl rate <0-5> <文件>...       写入星级（RAW 写 .xmp，JPG 写内部元数据）
              skctl check <jpg文件>...         查看 JPEG 段布局与像素数据位置
              skctl preview <文件> [最大边长]   验证大图加载（默认 3000）
              skctl review <文件夹>            用真实文件夹跑一遍审阅流程（不打分、不写盘）
              skctl lr <文件夹> [--apply] [--catalog <目录文件>]
                                              读取 Lightroom 目录里的星级；加 --apply 才写盘
              skctl rename <文件夹> --text 婚礼 [--apply] [--digits 3] [--date-format yyyymmdd]
                                              批量改名（默认只预览，加 --apply 才动手）
              skctl import <来源> --dest <父目录> --name 婚礼 [--apply] [--backup <目录>]
                              [--merge] [--delete-source] [--date yyyy-MM-dd]
                                              从 SD 卡/文件夹导入（默认只预览）
              skctl rotate <文件>... [--left]  旋转 90°（非破坏性，只改方向标记）
              skctl selftest                  跑完整自检（临时目录，不留痕迹）
            """
        )
    }

    // MARK: - 命令

    static func commandPaths() throws {
        let paths = AppPaths.default
        print("数据目录：\(paths.root.path)")
        print("评分数据库：\(paths.databaseURL.path)")
        print("缩略图缓存：\(paths.thumbnailDirectory.path)")
        let exists = FileManager.default.fileExists(atPath: paths.databaseURL.path)
        print("数据库是否已建立：\(exists ? "是" : "否")")
    }

    static func commandScan(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            fail("用法：skctl scan <文件夹>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: path)
        let result = try FolderScanner.scan(folder: folder)
        print("文件夹：\(folder.path)")
        print("分组数量：\(result.groups.count)，忽略文件：\(result.ignoredFiles.count)")
        print("")
        for (index, group) in result.groups.enumerated() {
            let kinds = group.files.map { $0.kind.rawValue }.joined(separator: "+")
            let date = MetadataFormatting.date(group.captureDate, dateFormat: "yyyy-MM-dd HH:mm:ss") ?? "无拍摄时间"
            let order = String(format: "%4d.", index + 1)
            print("\(order) \(group.displayName)  [\(kinds)]  \(date)")
        }
    }

    static func commandInfo(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            fail("用法：skctl info <文件>...")
            exit(2)
        }
        for path in arguments {
            let url = URL(fileURLWithPath: path)
            let metadata = try ExifReader.read(url: url)
            print("文件：\(url.lastPathComponent)")
            print("  相机：\([metadata.cameraMake, metadata.cameraModel].compactMap { $0 }.joined(separator: " "))")
            print("  镜头：\(metadata.lensModel ?? "—")")
            print("  拍摄时间：\(MetadataFormatting.date(metadata.captureDate) ?? "—")")
            let exposure = [
                MetadataFormatting.shutter(metadata.exposureTime),
                MetadataFormatting.aperture(metadata.fNumber),
                MetadataFormatting.iso(metadata.iso),
                MetadataFormatting.focalLength(metadata.focalLength),
            ].compactMap { $0 }.joined(separator: "  ")
            print("  曝光：\(exposure)")
            print("  尺寸：\(MetadataFormatting.dimensions(metadata) ?? "—")")
            let imageIORating = ExifReader.ratingFromImageMetadata(url: url).map { String($0) } ?? "无"
            print("  文件内星级（ImageIO 解析 XMP）：\(imageIORating)")
            print("")
        }
    }

    static func commandGet(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            fail("用法：skctl get <文件>...")
            exit(2)
        }
        for path in arguments {
            let url = URL(fileURLWithPath: path)
            let file = FileRef(url: url)
            let own = RatingService.readRating(from: file)
            let viaImageIO = ExifReader.ratingFromImageMetadata(url: url)
            print(url.lastPathComponent)
            print("  本程序读取：\(own.map { String($0) } ?? "无")")
            print("  ImageIO 交叉验证：\(viaImageIO.map { String($0) } ?? "无")")
            if file.kind == .proprietaryRAW {
                let sidecar = file.sidecarURL
                let exists = FileManager.default.fileExists(atPath: sidecar.path)
                print("  XMP 附属文件：\(exists ? sidecar.lastPathComponent : "不存在")")
            }
        }
    }

    static func commandRate(_ arguments: [String]) throws {
        guard arguments.count >= 2, let stars = Int(arguments[0]), (0...5).contains(stars) else {
            fail("用法：skctl rate <0-5> <文件>...")
            exit(2)
        }
        for path in arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            guard let group = try groupContaining(file: url) else {
                print("跳过（不在支持范围）：\(url.lastPathComponent)")
                continue
            }
            let outcome = RatingService.write(rating: stars, to: group)
            print("\(group.displayName) → \(stars) 星")
            for written in outcome.writtenFiles {
                print("  已写入：\(written.lastPathComponent)")
            }
            for file in outcome.databaseOnlyFiles {
                print("  仅软件内记录（首版不支持写入）：\(file.lastPathComponent)")
            }
            for file in outcome.skippedFiles {
                print("  跳过（视频不打分）：\(file.lastPathComponent)")
            }
            for error in outcome.errors {
                print("  失败：\(error)")
            }
        }
    }

    static func commandCheck(_ arguments: [String]) throws {
        guard !arguments.isEmpty else {
            fail("用法：skctl check <jpg文件>...")
            exit(2)
        }
        for path in arguments {
            let url = URL(fileURLWithPath: path)
            print("文件：\(url.lastPathComponent)")
            let description = try JPEGMetadataWriter.describe(url: url)
            for line in description.split(separator: "\n") {
                print("  \(line)")
            }
            print("")
        }
    }

    static func runSelfTest() {
        var test = SelfTest()
        if !test.run() { exit(1) }
    }

    /// 非破坏性旋转：只改文件内部的方向标记（RAW 改写侧车）。
    static func commandRotate(_ arguments: [String]) throws {
        let clockwise = !arguments.contains("--left")
        let paths = arguments.filter { !$0.hasPrefix("--") }
        guard !paths.isEmpty else {
            fail("用法：skctl rotate <文件>... [--left]")
            exit(2)
        }
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let group = AssetGroup(
                folder: url.deletingLastPathComponent(),
                baseName: url.deletingPathExtension().lastPathComponent,
                files: [FileRef(url: url)]
            )
            let before = RotateService.orientation(of: group)
            let outcome = RotateService.rotate(group, clockwise: clockwise)
            let after = RotateService.orientation(of: group)
            print("\(url.lastPathComponent)：\(EXIFOrientation.describe(before ?? 1)) → \(EXIFOrientation.describe(after ?? 1))")
            for file in outcome.updatedFiles { print("  已写入方向标记：\(file.lastPathComponent)") }
            for file in outcome.updatedSidecars { print("  已写入侧车：\(file.lastPathComponent)") }
            for skipped in outcome.skipped { print("  跳过：\(skipped.url.lastPathComponent)（\(skipped.reason)）") }
            for error in outcome.errors { print("  失败：\(error)") }
        }
    }

    /// 从 SD 卡或文件夹导入（与界面同一套计划与执行逻辑）。
    static func commandImport(_ arguments: [String]) throws {
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }
        let positional = arguments.filter { !$0.hasPrefix("--") }
        guard let sourcePath = positional.first, let destinationPath = value(for: "--dest") else {
            fail("用法：skctl import <来源> --dest <父目录> [--name 婚礼] [--apply] [--backup <目录>] [--merge] [--delete-source]")
            exit(2)
        }
        let apply = arguments.contains("--apply")
        let merge = arguments.contains("--merge")
        let deleteSource = arguments.contains("--delete-source")
        let source = URL(fileURLWithPath: sourcePath)
        let destinationRoot = URL(fileURLWithPath: destinationPath)
        let backupRoot = value(for: "--backup").map { URL(fileURLWithPath: $0) }

        var settings = ImportSettings(
            projectName: value(for: "--name") ?? "",
            destinationRoot: destinationRoot,
            backupRoot: backupRoot,
            copyToBackup: backupRoot != nil
        )
        if let dateText = value(for: "--date") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            settings.explicitDate = formatter.date(from: dateText)
            if settings.explicitDate == nil {
                fail("--date 需要 yyyy-MM-dd 格式")
                exit(2)
            }
        }

        let identity = VolumeScanner.volumeIdentity(for: source)
        let volumeName = identity.name
        let sourceRoot = identity.root
        let fileURLs = VolumeScanner.mediaFiles(in: source)
        guard !fileURLs.isEmpty else {
            print("来源里没有找到素材：\(source.path)")
            return
        }
        let fileRefs = fileURLs.map { url -> FileRef in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
            return FileRef(
                url: url,
                fileSize: values?.fileSize.map(Int64.init),
                modificationDate: values?.contentModificationDate,
                creationDate: values?.creationDate
            )
        }

        var history: ImportHistoryStore?
        var historyKeys = Set<String>()
        let databaseURL = value(for: "--db").map { URL(fileURLWithPath: $0) } ?? AppPaths.default.databaseURL
        do {
            let store = try ImportHistoryStore(databaseURL: databaseURL)
            history = store
            historyKeys = (try? store.keys(forVolume: volumeName)) ?? []
        } catch {
            print("提示：打不开导入历史数据库（\(error.localizedDescription)），这次不会记录/判断「已导入过」。")
        }

        var plan = ImportPlanner.plan(
            sourceFiles: fileRefs,
            settings: settings,
            volumeName: volumeName,
            sourceRoot: sourceRoot,
            importedHistory: historyKeys
        )
        if plan.destinationExists && !merge {
            let base = plan.projectFolderName
            let alternative = ImportPlanner.availableFolderName(base: base, in: destinationRoot)
            print("目标文件夹已存在：\(plan.projectURL.path)")
            print("将新建带后缀的文件夹：\(alternative)（想合并进已有文件夹就加 --merge）")
            plan = ImportPlanner.plan(
                sourceFiles: fileRefs,
                settings: settings,
                volumeName: volumeName,
                sourceRoot: sourceRoot,
                importedHistory: historyKeys,
                folderNameOverride: alternative
            )
        }

        print("来源：\(source.path)")
        print("目标项目：\(plan.projectURL.path)")
        print("照片 \(plan.photoCount) 张（其中配对 \(plan.pairedCount) 组）、视频 \(plan.videoCount) 个、共 \(plan.tasks.count) 个文件")
        print("总大小：\(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
        if let free = plan.destinationFreeSpace {
            print("目标剩余空间：\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))（\(plan.hasEnoughSpace ? "够用" : "不够！")）")
        }
        if settings.copyToBackup, let backupRoot {
            print("备份到：\(backupRoot.path)（\(plan.backupHasEnoughSpace ? "空间够用" : "空间不够！")）")
        }
        if !plan.conflicts.isEmpty {
            let overwrite = arguments.contains("--overwrite")
            print("冲突 \(plan.conflicts.count) 个（\(overwrite ? "将覆盖" : "将跳过")）：")
            for conflict in plan.conflicts.prefix(5) {
                let reason = conflict.kind == .alreadyImported ? "之前导入过" : "目标已存在"
                print("  \(conflict.task.source.lastPathComponent)（\(reason)）")
            }
        }

        guard apply else {
            print("")
            print("以上为预览，没有复制任何文件。要真正导入加 --apply。")
            return
        }

        var options = ImportExecutor.Options()
        options.progress = { progress in
            let percent = Int(progress.fraction * 100)
            let remaining = progress.estimatedRemaining.map { String(format: "%.0f 秒", $0) } ?? "—"
            FileHandle.standardError.write(
                Data("\r  \(progress.statusText)  \(percent)%  剩余 \(remaining)".utf8)
            )
        }
        options.history = history
        options.volumeName = volumeName
        options.sourceRoot = sourceRoot
        let overwrite = arguments.contains("--overwrite")
        for conflict in plan.conflicts {
            options.decisions[conflict.task.source.path] = overwrite ? .overwrite : .skip
        }

        let outcome = ImportExecutor.run(plan: plan, options: options)
        FileHandle.standardError.write(Data("\n".utf8))
        print("")
        print("导入完成：成功 \(outcome.copied.count) 个，跳过 \(outcome.skipped.count) 个\(outcome.cancelled ? "，已取消" : "")")
        if !outcome.failures.isEmpty {
            print("失败 \(outcome.failures.count) 个：")
            for failure in outcome.failures.prefix(5) {
                print("  \(failure.url.lastPathComponent)：\(failure.message)")
            }
        }
        if !outcome.backupFailures.isEmpty {
            print("备份失败 \(outcome.backupFailures.count) 个：")
            for failure in outcome.backupFailures.prefix(5) {
                print("  \(failure.url.lastPathComponent)：\(failure.message)")
            }
        }
        if deleteSource, !outcome.copied.isEmpty {
            let trash = TrashService.moveToTrash(outcome.copiedSourceURLs)
            print("已把 \(trash.trashed.count) 个卡内原文件移入废纸篓。")
        }
    }


    /// 批量改名（与界面用的是同一套计划与执行逻辑）。
    static func commandRename(_ arguments: [String]) throws {
        let positional = arguments.filter { !$0.hasPrefix("--") }
        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }
        let shouldApply = arguments.contains("--apply")
        guard let folderPath = positional.first else {
            fail("用法：skctl rename <文件夹> --text 婚礼 [--apply] [--digits 3]")
            exit(2)
        }
        let folder = URL(fileURLWithPath: folderPath)
        let text = value(for: "--text") ?? ""
        let videoText = value(for: "--video-text") ?? text
        var settings = RenameSettings()
        if let format = value(for: "--date-format") { settings.dateFormat = format }
        if let digits = value(for: "--digits").flatMap(Int.init) { settings.sequenceDigits = digits }

        let scan = try FolderScanner.scan(folder: folder)
        let probe = RenamePlanner.plan(groups: scan.groups, settings: settings)
        var texts: [String: String] = [:]
        for bucket in probe.renameGroups {
            texts[bucket.id] = bucket.isVideo ? videoText : text
        }
        let plan = RenamePlanner.plan(groups: scan.groups, texts: texts, settings: settings)

        print("文件夹：\(folder.path)")
        print("片子：\(scan.groups.count) 张，分成 \(plan.renameGroups.count) 组")
        for bucket in plan.renameGroups {
            let sample = RenamePlanner.plan(
                groups: bucket.groups,
                texts: [bucket.id: bucket.text],
                settings: settings
            ).example ?? ""
            print("  \(bucket.title)：\(bucket.count) 张  → \(sample)")
        }
        print("")
        print("模板示例：\(plan.example ?? "—")")
        print("要改名的文件：\(plan.fileCount) 个（含 .xmp 等附属文件），名字不变的：\(plan.unchangedCount) 个")
        if !plan.conflicts.isEmpty {
            print("目标重名：\(plan.conflicts.count) 个")
            for conflict in plan.conflicts.prefix(5) {
                print("  \(conflict.source.lastPathComponent) → \(conflict.target.lastPathComponent)（已存在）")
            }
        }

        guard shouldApply else {
            print("")
            print("以上为预览，没有改动任何文件。要真正改名加 --apply。")
            return
        }
        guard plan.fileCount > 0 else {
            print("没有需要改名的文件。")
            return
        }
        let skipping = Set(plan.conflicts.map { $0.source.standardizedFileURL })
        if !skipping.isEmpty {
            print("冲突项将跳过（界面里可以选择覆盖）。")
        }
        let outcome = RenameExecutor.apply(plan: plan, skipping: skipping)
        print("已改名 \(outcome.renamed.count) 个文件。")
        if !outcome.failures.isEmpty {
            print("失败 \(outcome.failures.count) 个：")
            for failure in outcome.failures.prefix(10) {
                print("  \(failure.url.lastPathComponent)：\(failure.message)")
            }
            exit(1)
        }
        let undo = RenameExecutor.undo(outcome.renamed)
        if undo.failures.isEmpty {
            print("（命令行不保留会话，已自动撤销，文件恢复原名。）")
        } else {
            print("自动撤销有 \(undo.failures.count) 个失败项。")
        }
    }

    /// 读取 Lightroom Classic 目录里的星级，按需写回文件。
    static func commandLightroom(_ arguments: [String]) throws {
        let positional = arguments.filter { !$0.hasPrefix("--") }
        let shouldApply = arguments.contains("--apply")
        var catalogPath: String?
        if let index = arguments.firstIndex(of: "--catalog"), arguments.count > index + 1 {
            catalogPath = arguments[index + 1]
        }
        guard let folderPath = positional.first else {
            fail("用法：skctl lr <文件夹> [--apply] [--catalog <Lightroom 目录文件>]")
            exit(2)
        }
        let folder = URL(fileURLWithPath: folderPath)

        let catalogURL: URL
        if let catalogPath {
            catalogURL = URL(fileURLWithPath: catalogPath)
        } else {
            let found = LightroomCatalog.discover()
            guard let first = found.first else {
                fail("没有找到 Lightroom 目录文件（.lrcat）。可以用 --catalog 指定路径。")
                exit(1)
            }
            catalogURL = first
            if found.count > 1 {
                print("发现 \(found.count) 个目录文件，使用：\(first.path)")
            }
        }

        print("Lightroom 目录：\(catalogURL.path)")
        let catalog = LightroomCatalog(url: catalogURL)
        let ratings = try catalog.ratings(under: folder)
        print("该文件夹在目录里有星级的照片：\(ratings.count) 张")

        let scan = try FolderScanner.scan(folder: folder, readMetadata: false)
        print("文件夹里识别出：\(scan.groups.count) 张片子")
        let plan = LightroomSync.plan(groups: scan.groups, catalogRatings: ratings)
        print("  已一致：\(plan.alreadyMatching)")
        print("  目录里没有：\(plan.notInCatalog)")
        print("  需要写入：\(plan.updates.count)")
        for update in plan.updates.prefix(10) {
            let current = update.currentRating.map { "\($0) 星" } ?? "无"
            print("    \(update.group.displayName)：\(current) → \(update.rating) 星")
        }
        if plan.updates.count > 10 {
            print("    …其余 \(plan.updates.count - 10) 张")
        }

        guard shouldApply else {
            print("")
            print("以上为预览。要真正写进文件（RAW 写 .xmp，JPG 写文件内部元数据），加 --apply。")
            return
        }
        guard plan.hasChanges else {
            print("没有需要写入的内容。")
            return
        }
        print("")
        print("开始写入…")
        let outcome = LightroomSync.apply(plan: plan) { done, total in
            if done % 20 == 0 || done == total {
                FileHandle.standardError.write(Data("\r  进度 \(done)/\(total)".utf8))
            }
        }
        FileHandle.standardError.write(Data("\n".utf8))
        print("已写入文件：\(outcome.writtenFiles.count) 个")
        if !outcome.errors.isEmpty {
            print("失败 \(outcome.errors.count) 项：")
            for error in outcome.errors.prefix(10) { print("  \(error)") }
            exit(1)
        }
    }

    /// 验证大图加载路径：屏幕预览与 1:1 原始分辨率。
    static func commandPreview(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            fail("用法：skctl preview <文件> [最大边长]")
            exit(2)
        }
        let maxPixel = arguments.count > 1 ? (Int(arguments[1]) ?? 3000) : 3000
        let url = URL(fileURLWithPath: path)
        let file = FileRef(url: url)
        guard file.kind != .video else {
            fail("这是视频文件；视频走 AVKit 播放与封面缩略图，不走图像解码路径。")
            exit(1)
        }
        let group = AssetGroup(
            folder: url.deletingLastPathComponent(),
            baseName: file.baseName,
            files: [file]
        )
        print("文件：\(file.fileName)（\(file.kind.rawValue)）")
        if let size = PreviewLoader.orientedPixelSize(of: url) {
            let megapixels = size.width * size.height / 1_000_000
            print("  原始像素尺寸：\(Int(size.width)) × \(Int(size.height))（\(String(format: "%.1f", megapixels)) MP）")
        }

        let loader = PreviewLoader()
        var screenPreview: PreviewLoader.Preview?
        var screenPreviewCached: PreviewLoader.Preview?
        var fullPreview: PreviewLoader.Preview?
        let coldStart = Date()
        let done = DispatchSemaphore(value: 0)
        Task {
            screenPreview = await loader.preview(for: group, maxPixel: maxPixel)
            done.signal()
        }
        done.wait()
        let coldSeconds = Date().timeIntervalSince(coldStart)

        let warmStart = Date()
        let warmDone = DispatchSemaphore(value: 0)
        Task {
            screenPreviewCached = await loader.preview(for: group, maxPixel: maxPixel)
            warmDone.signal()
        }
        warmDone.wait()
        let warmSeconds = Date().timeIntervalSince(warmStart)

        let fullStart = Date()
        let fullDone = DispatchSemaphore(value: 0)
        Task {
            fullPreview = await loader.fullResolution(for: group)
            fullDone.signal()
        }
        fullDone.wait()
        let fullSeconds = Date().timeIntervalSince(fullStart)

        if let screenPreview {
            let size = screenPreview.decodedPixelSize
            print("  屏幕预览：\(Int(size.width)) × \(Int(size.height))，缩放系数 \(String(format: "%.2f", screenPreview.downsampleFactor))，首次 \(String(format: "%.0f", coldSeconds * 1000)) ms")
        } else {
            print("  屏幕预览：加载失败")
        }
        if screenPreviewCached != nil {
            print("  再次读取（内存缓存命中）：\(String(format: "%.1f", warmSeconds * 1000)) ms")
        }
        if let fullPreview {
            let size = fullPreview.decodedPixelSize
            print("  1:1 原始分辨率：\(Int(size.width)) × \(Int(size.height))，耗时 \(String(format: "%.0f", fullSeconds * 1000)) ms")
        } else {
            print("  1:1 原始分辨率：加载失败")
        }
    }

    /// 用真实文件夹跑一遍审阅流程：只读，不打分、不写盘、不删除。
    static func commandReview(_ arguments: [String]) throws {
        guard let path = arguments.first else {
            fail("用法：skctl review <文件夹>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: path)
        let scan = try FolderScanner.scan(folder: folder)
        var ratings: [String: Int] = [:]
        for group in scan.groups {
            if let rating = RatingService.readRatingFromFiles(for: group) {
                ratings[group.id] = rating
            }
        }

        print("文件夹：\(folder.path)")
        print("片子总数：\(scan.groups.count)（配对组 \(scan.groups.filter(\.isPaired).count)，视频 \(scan.groups.filter(\.isVideo).count)，忽略文件 \(scan.ignoredFiles.count)）")
        let databaseOnly = scan.groups.filter { !$0.databaseOnlyTargets.isEmpty }.count
        if databaseOnly > 0 {
            print("其中 \(databaseOnly) 张含 DNG / HEIC，首版星级只记在软件内")
        }
        let rated = ratings.count
        print("文件里已有星级的：\(rated) 张")

        // 顺带看一下 Lightroom 目录能补上多少（这就是界面显示时用的逻辑）
        if let catalogURL = LightroomCatalog.discover().first,
           let catalogRatings = try? LightroomCatalog(url: catalogURL).ratings(under: folder) {
            let plan = LightroomSync.plan(groups: scan.groups, catalogRatings: catalogRatings)
            print("Lightroom 目录（\(catalogURL.lastPathComponent)）：可补 \(plan.updates.count) 张的星级，已一致 \(plan.alreadyMatching) 张")
            if plan.updates.count > 0 {
                print("  例如：", terminator: "")
                let sample = plan.updates.prefix(3).map { "\($0.group.displayName)=\($0.rating)★" }.joined(separator: "，")
                print(sample)
            }
        }

        var session = ReviewSession(groups: scan.groups, ratings: ratings)
        print("")
        print("日期分组：\(session.dateGroups.count) 组")
        for dateGroup in session.dateGroups.prefix(5) {
            print("  \(dateGroup.title)：\(dateGroup.count) 张")
        }
        if session.dateGroups.count > 5 {
            print("  …其余 \(session.dateGroups.count - 5) 组")
        }

        print("")
        print("模拟操作：")
        print("  初始选中：\(session.current?.displayName ?? "无")（序号 \(session.currentVisibleIndex.map { $0 + 1 } ?? 0) / \(session.visibleCount)）")
        for _ in 0..<3 { session.selectNext() }
        print("  按 3 次 →：\(session.current?.displayName ?? "无")")
        session.selectPrevious()
        print("  按 1 次 ←：\(session.current?.displayName ?? "无")")
        session.selectNextDateGroup()
        print("  按 1 次 ↓（跳日期组）：\(session.current?.displayName ?? "无")")
        session.selectPreviousDateGroup()
        print("  按 1 次 ↑（跳日期组）：\(session.current?.displayName ?? "无")")

        session.applyFilter(RatingFilter(isActive: true, comparison: .atLeast, stars: 3))
        print("  筛选 ≥3 星：剩 \(session.visibleCount) 张，当前 \(session.current?.displayName ?? "无")")
        session.applyFilter(RatingFilter(isActive: true, comparison: .exactly, stars: 0))
        print("  筛选 =0 星（未打分）：剩 \(session.visibleCount) 张")
        session.applyFilter(.inactive)
        print("  清除筛选：恢复 \(session.visibleCount) 张")
    }

    // MARK: - 辅助

    /// 生成一张带 EXIF 的 JPEG，供自检使用。
    static func writeTestJPEG(to url: URL, captureDate: String = "2026:09:27 18:30:00") throws {
        let width = 240
        let height = 160
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
                    blue: 0.4,
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
                kCGImageDestinationLossyCompressionQuality: 0.8,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: captureDate,
                    kCGImagePropertyExifFNumber: 2.8,
                    kCGImagePropertyExifISOSpeedRatings: [400],
                    kCGImagePropertyExifFocalLength: 50,
                    kCGImagePropertyExifExposureTime: 1.0 / 250.0,
                    kCGImagePropertyExifLensModel: "SK selftest lens",
                ],
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "ShutterKeeper",
                    kCGImagePropertyTIFFModel: "Selftest Camera",
                ],
                // 让生成的文件带方向标记，自检才能验证非破坏性旋转
                kCGImagePropertyOrientation: 1,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// 找到某个文件所属的配对组（扫描它所在文件夹，走和界面完全一样的逻辑）。
    static func groupContaining(file url: URL) throws -> AssetGroup? {
        let folder = url.deletingLastPathComponent()
        let result = try FolderScanner.scan(folder: folder, readMetadata: false)
        let target = url.standardizedFileURL
        return result.groups.first { group in
            group.files.contains { $0.url.standardizedFileURL == target }
        }
    }
}
