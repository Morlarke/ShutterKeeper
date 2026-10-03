import Foundation

/// 改名参数。
public struct RenameSettings: Sendable, Equatable {
    /// 日期格式，默认与偏好设置里的默认格式一致。
    public var dateFormat: String
    /// 序列号位数（1–6），默认 3。
    public var sequenceDigits: Int
    /// 各段之间的连接符。
    public var separator: String

    public init(dateFormat: String = "yyyymmdd", sequenceDigits: Int = 3, separator: String = "_") {
        self.dateFormat = dateFormat
        self.sequenceDigits = max(1, min(6, sequenceDigits))
        self.separator = separator
    }
}

/// 一个「日期 + 类型」分组（照片按天一组、视频按天单独一组）。
public struct RenameGroupPlan: Identifiable, Sendable {
    public let id: String
    /// 分组依据的日期（照片是 EXIF 拍摄日期，视频是文件创建日期）。
    public let date: Date?
    /// 显示用标题，例如「2026年9月27日 星期六」。
    public let title: String
    public let isVideo: Bool
    /// 该组里的片子（已按拍摄时间排序）。
    public let groups: [AssetGroup]
    /// 用户在界面里为这一组填的自定义文本。
    public var text: String

    public var count: Int { groups.count }
    public var familyLabel: String { isVideo ? "视频" : "照片" }
}

/// 一个文件的改名动作。
public struct RenameOperation: Sendable, Hashable {
    public let originalURL: URL
    public let finalURL: URL
    /// 这个文件属于哪一张片子（配对组 id），用于「只改选中的」。
    public let assetID: String

    public init(originalURL: URL, finalURL: URL, assetID: String = "") {
        self.originalURL = originalURL
        self.finalURL = finalURL
        self.assetID = assetID
    }

    public var isNoop: Bool {
        originalURL.standardizedFileURL == finalURL.standardizedFileURL
    }
}

/// 目标文件名已被别的文件占用。
public struct RenameConflict: Sendable {
    public let source: URL
    public let target: URL
}

/// 文件列表预览用的一条：某个文件现在叫什么、改完叫什么。
public struct RenameFilePreview: Identifiable, Hashable, Sendable {
    public let originalURL: URL
    public let newName: String
    public let kind: MediaKind
    public let isSidecar: Bool
    /// 这个文件属于哪一张片子（配对组 id），多选与删除都按「张」算。
    public let assetID: String

    public var id: String { originalURL.path }
    public var originalName: String { originalURL.lastPathComponent }
    public var willChange: Bool { newName != originalName }

    public init(originalURL: URL, newName: String, kind: MediaKind, isSidecar: Bool, assetID: String) {
        self.originalURL = originalURL
        self.newName = newName
        self.kind = kind
        self.isSidecar = isSidecar
        self.assetID = assetID
    }
}

/// 一次改名的完整计划。
public struct RenamePlan: Sendable {
    public var settings: RenameSettings
    public var renameGroups: [RenameGroupPlan]
    public var operations: [RenameOperation]
    public var conflicts: [RenameConflict]
    /// 每组一条示例，例如 `20260927_婚礼_001.CR3`。
    public var examples: [String]
    /// 因为「新名字和旧名字一样」而跳过的文件数。
    public var unchangedCount: Int
    /// 每张片子的新文件名（键是 `AssetGroup.id`），供界面直接显示。
    public var newNames: [String: String]
    /// 文件夹里每个文件的新名字（含 JPG、附属文件；名字不变的也在里面）。
    public var files: [RenameFilePreview]

    public init(
        settings: RenameSettings,
        renameGroups: [RenameGroupPlan],
        operations: [RenameOperation],
        conflicts: [RenameConflict],
        examples: [String],
        unchangedCount: Int,
        newNames: [String: String] = [:],
        files: [RenameFilePreview] = []
    ) {
        self.settings = settings
        self.renameGroups = renameGroups
        self.operations = operations
        self.conflicts = conflicts
        self.examples = examples
        self.unchangedCount = unchangedCount
        self.newNames = newNames
        self.files = files
    }

    public var fileCount: Int { operations.count }

    /// 示例文本：需求里只要求显示一个模板示例。
    public var example: String? {
        examples.first
    }
}
