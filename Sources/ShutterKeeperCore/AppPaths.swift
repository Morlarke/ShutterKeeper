import Foundation

/// 应用的数据目录。
///
/// 评分数据库与缩略图缓存**分开存放**，两者都可以单独删除：
/// - 删缓存：下次重新生成，不丢数据
/// - 删数据库：软件自身记录丢失，文件里的星级仍在，可重新导入
public struct AppPaths: Sendable {
    public let root: URL
    public let displayName: String

    public init(root: URL, displayName: String = "快门闪选") {
        self.root = root
        self.displayName = displayName
    }

    /// `~/Library/Application Support/ShutterKeeper/`
    ///
    /// 目录名用 ASCII，避免第三方工具处理中文路径时出问题；界面上仍显示中文名。
    public static var `default`: AppPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return AppPaths(root: base.appendingPathComponent("ShutterKeeper", isDirectory: true))
    }

    public var databaseDirectory: URL { root.appendingPathComponent("db", isDirectory: true) }
    public var databaseURL: URL { databaseDirectory.appendingPathComponent("ratings.sqlite") }
    public var cacheDirectory: URL { root.appendingPathComponent("cache", isDirectory: true) }
    public var thumbnailDirectory: URL { cacheDirectory.appendingPathComponent("thumbs", isDirectory: true) }

    @discardableResult
    public func ensureDirectories() throws -> AppPaths {
        for directory in [root, databaseDirectory, cacheDirectory, thumbnailDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return self
    }
}
