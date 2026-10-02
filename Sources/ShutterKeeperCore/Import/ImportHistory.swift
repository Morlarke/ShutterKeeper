import Foundation

/// 导入历史里的一条：用来判断「卡里这个文件是不是已经导入过了」。
public struct ImportHistoryEntry: Sendable, Hashable {
    public let volume: String
    public let relativePath: String
    public let fileName: String
    public let fileSize: Int64
    public let projectPath: String?
    public let importedAt: Date

    public init(
        volume: String,
        relativePath: String,
        fileName: String,
        fileSize: Int64,
        projectPath: String?,
        importedAt: Date = Date()
    ) {
        self.volume = volume
        self.relativePath = relativePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.projectPath = projectPath
        self.importedAt = importedAt
    }

    /// 与数据库唯一约束一致的键（同名同大小的判断依据）。
    public static func key(volume: String, relativePath: String, fileName: String, fileSize: Int64) -> String {
        "\(volume)|\(relativePath)|\(fileName)|\(fileSize)"
    }

    public var key: String {
        Self.key(volume: volume, relativePath: relativePath, fileName: fileName, fileSize: fileSize)
    }
}

/// 导入历史的读写。存放在软件自己的评分数据库里。
public final class ImportHistoryStore {
    private let db: SQLiteDatabase

    public init(databaseURL: URL) throws {
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.db = try SQLiteDatabase(path: databaseURL.path)
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS import_history (
                id INTEGER PRIMARY KEY,
                volume_name TEXT,
                relative_path TEXT NOT NULL,
                file_name TEXT NOT NULL,
                file_size INTEGER,
                project_path TEXT,
                imported_at REAL NOT NULL,
                UNIQUE(volume_name, relative_path, file_name, file_size)
            );
            """
        )
    }

    /// 用已有的数据库连接（评分数据库）构造，避免两个连接写同一个文件。
    public init(database: SQLiteDatabase) throws {
        self.db = database
    }

    public func record(_ entries: [ImportHistoryEntry]) throws {
        guard !entries.isEmpty else { return }
        try db.transaction {
            for entry in entries {
                try db.run(
                    """
                    INSERT OR REPLACE INTO import_history
                    (volume_name, relative_path, file_name, file_size, project_path, imported_at)
                    VALUES (?, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(entry.volume),
                        .text(entry.relativePath),
                        .text(entry.fileName),
                        .integer(entry.fileSize),
                        entry.projectPath.map { SQLValue.text($0) } ?? .null,
                        .real(entry.importedAt.timeIntervalSince1970),
                    ]
                )
            }
        }
    }

    /// 某个卷的导入历史键集合。
    public func keys(forVolume volume: String) throws -> Set<String> {
        let rows = try db.query(
            "SELECT relative_path, file_name, file_size FROM import_history WHERE volume_name = ?;",
            [.text(volume)]
        )
        var result = Set<String>()
        for row in rows {
            guard let relativePath = row["relative_path"]?.stringValue,
                  let fileName = row["file_name"]?.stringValue,
                  let size = row["file_size"]?.intValue else { continue }
            result.insert(
                ImportHistoryEntry.key(
                    volume: volume,
                    relativePath: relativePath,
                    fileName: fileName,
                    fileSize: Int64(size)
                )
            )
        }
        return result
    }

    public func count(forVolume volume: String) throws -> Int {
        let row = try db.queryOne(
            "SELECT COUNT(*) AS count FROM import_history WHERE volume_name = ?;",
            [.text(volume)]
        )
        return row?["count"]?.intValue ?? 0
    }

    public func clearAll() throws {
        try db.execute("DELETE FROM import_history;")
    }
}
