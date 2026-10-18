import Foundation

/// 导入设置。
public struct ImportSettings: Sendable {
    /// 日期格式，默认与偏好设置一致。
    public var dateFormat: String
    /// 目标文件夹名里的日期用哪一天；nil 表示用源文件里最早的拍摄日期。
    public var explicitDate: Date?
    /// 目标父目录：`日期Photos` / `日期Videos` 直接建在它下面。
    public var destinationRoot: URL
    /// 备份位置；`copyToBackup` 为真时使用。
    public var backupRoot: URL?
    public var copyToBackup: Bool

    public init(
        dateFormat: String = "yyyymmdd",
        explicitDate: Date? = nil,
        destinationRoot: URL,
        backupRoot: URL? = nil,
        copyToBackup: Bool = false
    ) {
        self.dateFormat = dateFormat
        self.explicitDate = explicitDate
        self.destinationRoot = destinationRoot
        self.backupRoot = backupRoot
        self.copyToBackup = copyToBackup
    }
}

/// 导入时一个文件的搬运任务。
public struct ImportTask: Identifiable, Sendable, Hashable {
    public var id: String { source.standardizedFileURL.path }
    public let source: URL
    public let destination: URL
    public let backupDestination: URL?
    public let fileSize: Int64
    public let isSidecar: Bool
    public let assetID: String
    public let isVideo: Bool

    public init(
        source: URL,
        destination: URL,
        backupDestination: URL?,
        fileSize: Int64,
        isSidecar: Bool,
        assetID: String,
        isVideo: Bool
    ) {
        self.source = source
        self.destination = destination
        self.backupDestination = backupDestination
        self.fileSize = fileSize
        self.isSidecar = isSidecar
        self.assetID = assetID
        self.isVideo = isVideo
    }
}

/// 冲突类型。
public enum ImportConflictKind: String, Sendable {
    /// 目标位置已经有同名文件。
    case destinationExists
    /// 这张卡里的这个文件之前已经导入过（同名同大小）。
    case alreadyImported
}

public struct ImportConflict: Sendable, Identifiable {
    public var id: String { task.id }
    public let task: ImportTask
    public let kind: ImportConflictKind
}

/// 用户对冲突的处理决定。
public enum ImportDecision: String, Sendable {
    /// 跳过这个文件
    case skip
    /// 覆盖（已存在的目标文件先移入废纸篓）
    case overwrite
}

/// 目标文件夹已存在时怎么办。
public enum ProjectFolderDecision: String, Sendable {
    /// 合并进已有文件夹
    case merge
    /// 新建一个带后缀的文件夹（`日期Photos-2` / `日期Videos-2`）
    case newFolder
    /// 取消导入
    case cancel
}

/// 导入计划。
public struct ImportPlan: Sendable {
    public var settings: ImportSettings
    /// 日期部分，例如 `20260917`，用来拼两个目标文件夹名。
    public let dateKey: String
    /// 照片目标文件夹：`<日期>Photos`
    public let photosFolderURL: URL
    /// 视频目标文件夹：`<日期>Videos`
    public let videosFolderURL: URL
    public let assets: [AssetGroup]
    public let tasks: [ImportTask]
    public let conflicts: [ImportConflict]
    public let totalBytes: Int64
    public let photoCount: Int
    public let videoCount: Int
    public let pairedCount: Int
    public let hasPhotoTasks: Bool
    public let hasVideoTasks: Bool
    /// 目标卷剩余空间（字节）；取不到就是 nil。
    public let destinationFreeSpace: Int64?
    /// 备份卷剩余空间。
    public let backupFreeSpace: Int64?

    public var destinationExists: Bool {
        FileManager.default.fileExists(atPath: photosFolderURL.path)
            || FileManager.default.fileExists(atPath: videosFolderURL.path)
    }

    /// 这次会创建的文件夹（只列有内容的）。
    public var targetFolders: [URL] {
        var result: [URL] = []
        if hasPhotoTasks { result.append(photosFolderURL) }
        if hasVideoTasks { result.append(videosFolderURL) }
        return result
    }

    /// 展示用，例如「20260917Photos + 20260917Videos」。
    public var folderSummary: String {
        targetFolders.map { $0.lastPathComponent }.joined(separator: " + ")
    }

    /// 主文件夹（用于「在访达中显示」与导入历史）。
    public var primaryFolderURL: URL {
        hasPhotoTasks ? photosFolderURL : videosFolderURL
    }

    public var hasEnoughSpace: Bool {
        guard let destinationFreeSpace else { return true }
        return destinationFreeSpace >= totalBytes
    }

    public var backupHasEnoughSpace: Bool {
        guard settings.copyToBackup, let backupRoot = settings.backupRoot else { return true }
        _ = backupRoot
        guard let backupFreeSpace else { return true }
        return backupFreeSpace >= totalBytes
    }
}

/// 导入进度。
public struct ImportProgress: Sendable {
    public enum Phase: String, Sendable {
        case preparing
        case copying
        case backingUp
        case finishing
    }

    public var phase: Phase
    public var currentFileName: String
    public var filesCompleted: Int
    public var filesTotal: Int
    public var bytesCompleted: Int64
    public var bytesTotal: Int64
    public var estimatedRemaining: TimeInterval?

    public var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesCompleted) / Double(bytesTotal))
    }

    public var statusText: String {
        switch phase {
        case .preparing: return "正在准备…"
        case .copying: return "正在导入 \(currentFileName)"
        case .backingUp: return "正在备份 \(currentFileName)"
        case .finishing: return "正在收尾…"
        }
    }
}

/// 导入结果。
public struct ImportOutcome: Sendable {
    public var copied: [ImportTask] = []
    public var skipped: [ImportTask] = []
    public var failures: [(url: URL, message: String)] = []
    /// 备份失败的（主导入已经完成，只是备份没成）。
    public var backupFailures: [(url: URL, message: String)] = []
    public var cancelled = false

    public var succeededCount: Int { copied.count }
    public var copiedSourceURLs: [URL] { copied.map(\.source) }
    public var hasFailures: Bool { !failures.isEmpty || !backupFailures.isEmpty }
}
