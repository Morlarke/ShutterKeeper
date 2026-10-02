import Foundation

/// 把一个来源（SD 卡目录或任意文件夹）规划成一次导入。
///
/// 目录结构（需求文档 5.2）：
/// ```
/// <父目录>/<日期_项目名>/
/// ├── Photos/    RAW、JPG、TIFF 等照片（以及配套的 .xmp 附属文件）
/// └── Videos/    视频
/// ```
public enum ImportPlanner {
    public static func plan(
        sourceFiles: [FileRef],
        settings: ImportSettings,
        volumeName: String? = nil,
        sourceRoot: URL? = nil,
        importedHistory: Set<String> = [],
        projectFolderSuffix: String? = nil,
        folderNameOverride: String? = nil
    ) -> ImportPlan {
        var groups = Pairing.group(sourceFiles)
        // 分组之后补齐拍摄日期（照片读 EXIF，视频退到文件创建日期），
        // 项目文件夹名里的日期就是从这里来的
        for index in groups.indices {
            FolderScanner.enrich(&groups[index])
        }
        return plan(
            assets: groups,
            settings: settings,
            volumeName: volumeName,
            sourceRoot: sourceRoot,
            importedHistory: importedHistory,
            projectFolderSuffix: projectFolderSuffix,
            folderNameOverride: folderNameOverride
        )
    }

    /// 用已经扫好、已经补齐拍摄日期的分组来规划（界面走这条路径，避免重复读 EXIF）。
    public static func plan(
        assets groups: [AssetGroup],
        settings: ImportSettings,
        volumeName: String? = nil,
        sourceRoot: URL? = nil,
        importedHistory: Set<String> = [],
        projectFolderSuffix: String? = nil,
        folderNameOverride: String? = nil
    ) -> ImportPlan {
        let captureDates = groups.compactMap(\.captureDate)
        let date = settings.explicitDate ?? captureDates.min()
        let folderName = folderNameOverride
            ?? projectFolderName(settings: settings, date: date, suffix: projectFolderSuffix)
        let projectURL = settings.destinationRoot.appendingPathComponent(folderName, isDirectory: true)
        let photosURL = projectURL.appendingPathComponent("Photos", isDirectory: true)
        let videosURL = projectURL.appendingPathComponent("Videos", isDirectory: true)
        let backupProjectURL = settings.copyToBackup
            ? settings.backupRoot?.appendingPathComponent(folderName, isDirectory: true)
            : nil

        var tasks: [ImportTask] = []
        var conflicts: [ImportConflict] = []
        var totalBytes: Int64 = 0
        var photoCount = 0
        var videoCount = 0
        var pairedCount = 0

        for group in groups {
            if group.isVideo {
                videoCount += 1
            } else {
                photoCount += 1
                if group.isPaired { pairedCount += 1 }
            }

            // 主文件：照片进 Photos，视频进 Videos
            for file in group.files {
                let folder = group.isVideo ? videosURL : photosURL
                let destination = folder.appendingPathComponent(file.fileName)
                let backup = backupProjectURL?
                    .appendingPathComponent(group.isVideo ? "Videos" : "Photos", isDirectory: true)
                    .appendingPathComponent(file.fileName)
                let task = ImportTask(
                    source: file.url,
                    destination: destination,
                    backupDestination: backup,
                    fileSize: file.fileSize ?? 0,
                    isSidecar: false,
                    assetID: group.id,
                    isVideo: group.isVideo
                )
                tasks.append(task)
                totalBytes += task.fileSize
                if let conflict = conflict(
                    for: task,
                    volumeName: volumeName,
                    sourceRoot: sourceRoot,
                    history: importedHistory
                ) {
                    conflicts.append(conflict)
                }
            }

            // 附属文件（.xmp 等）跟着主文件走
            for sidecar in group.sidecars {
                let folder = group.isVideo ? videosURL : photosURL
                let destination = folder.appendingPathComponent(sidecar.fileName)
                let backup = backupProjectURL?
                    .appendingPathComponent(group.isVideo ? "Videos" : "Photos", isDirectory: true)
                    .appendingPathComponent(sidecar.fileName)
                let size = (try? sidecar.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let task = ImportTask(
                    source: sidecar.url,
                    destination: destination,
                    backupDestination: backup,
                    fileSize: size,
                    isSidecar: true,
                    assetID: group.id,
                    isVideo: group.isVideo
                )
                tasks.append(task)
                totalBytes += task.fileSize
                if let conflict = conflict(
                    for: task,
                    volumeName: volumeName,
                    sourceRoot: sourceRoot,
                    history: importedHistory
                ) {
                    conflicts.append(conflict)
                }
            }
        }

        return ImportPlan(
            settings: settings,
            projectFolderName: folderName,
            projectURL: projectURL,
            assets: groups,
            tasks: tasks,
            conflicts: conflicts,
            totalBytes: totalBytes,
            photoCount: photoCount,
            videoCount: videoCount,
            pairedCount: pairedCount,
            destinationFreeSpace: VolumeScanner.freeSpace(of: settings.destinationRoot),
            backupFreeSpace: settings.backupRoot.flatMap { VolumeScanner.freeSpace(of: $0) }
        )
    }

    static func conflict(
        for task: ImportTask,
        volumeName: String?,
        sourceRoot: URL?,
        history: Set<String>
    ) -> ImportConflict? {
        if let volumeName {
            let root = sourceRoot ?? task.source.deletingLastPathComponent()
            let key = ImportHistoryEntry.key(
                volume: volumeName,
                relativePath: VolumeScanner.relativePath(of: task.source, from: root),
                fileName: task.source.lastPathComponent,
                fileSize: task.fileSize
            )
            if history.contains(key) {
                return ImportConflict(task: task, kind: .alreadyImported)
            }
        }
        if FileManager.default.fileExists(atPath: task.destination.path) {
            return ImportConflict(task: task, kind: .destinationExists)
        }
        return nil
    }

    /// 项目文件夹名：`日期_项目名`，两段都可以为空。
    public static func projectFolderName(settings: ImportSettings, date: Date?, suffix: String? = nil) -> String {
        let dateText = date.map { dateString(for: $0, format: settings.dateFormat) } ?? ""
        let name = sanitize(settings.projectName)
        var components = [dateText, name].filter { !$0.isEmpty }
        if let suffix, !suffix.isEmpty { components.append(suffix) }
        let base = components.joined(separator: "_")
        return base.isEmpty ? "未命名导入" : base
    }

    static func dateString(for date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        // 与批量改名保持一致：把用户习惯写的 yyyymmdd 里的小写 m 当月份
        formatter.dateFormat = String(format.map { $0 == "m" ? "M" : $0 })
        return formatter.string(from: date)
    }

    static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return trimmed.components(separatedBy: invalid).joined()
    }

    /// 目标文件夹已存在时，找一个带后缀的新名字：`婚礼-2`、`婚礼-3`…
    public static func availableFolderName(base: String, in root: URL) -> String {
        let fileManager = FileManager.default
        var index = 2
        var candidate = "\(base)-\(index)"
        while fileManager.fileExists(atPath: root.appendingPathComponent(candidate).path) {
            index += 1
            candidate = "\(base)-\(index)"
            if index > 999 { break }
        }
        return candidate
    }
}
