import Foundation

public struct RecentFolder: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let path: String
    public let displayName: String
    public let lastOpened: Date

    public var url: URL { URL(fileURLWithPath: path) }
}

/// 软件自己的评分数据库。
///
/// 这个文件可以被单独删除：删掉之后文件里的星级依然在，
/// 重新打开文件夹时可以从 `.xmp` 与 JPG 内部元数据恢复。
public final class RatingStore {
    private let db: SQLiteDatabase
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.db = try SQLiteDatabase(path: databaseURL.path)
        try createSchema()
    }

    public static func open(at paths: AppPaths = .default) throws -> RatingStore {
        try paths.ensureDirectories()
        return try RatingStore(databaseURL: paths.databaseURL)
    }

    private func createSchema() throws {
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS folders (
                id INTEGER PRIMARY KEY,
                path TEXT NOT NULL UNIQUE,
                display_name TEXT NOT NULL,
                last_opened REAL NOT NULL
            );
            """
        )
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS assets (
                id INTEGER PRIMARY KEY,
                folder_path TEXT NOT NULL,
                base_key TEXT NOT NULL,
                base_name TEXT NOT NULL,
                rating INTEGER NOT NULL DEFAULT 0,
                capture_date REAL,
                primary_path TEXT,
                is_video INTEGER NOT NULL DEFAULT 0,
                updated_at REAL NOT NULL,
                UNIQUE(folder_path, base_key)
            );
            """
        )
        try db.execute("CREATE INDEX IF NOT EXISTS idx_assets_folder ON assets(folder_path);")
        // 导入历史与改名记录分别属于「导入」「改名」模块，先建表，后续里程碑使用。
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
        try db.execute(
            """
            CREATE TABLE IF NOT EXISTS rename_history (
                id INTEGER PRIMARY KEY,
                session_id TEXT NOT NULL,
                old_path TEXT NOT NULL,
                new_path TEXT NOT NULL,
                created_at REAL NOT NULL
            );
            """
        )
    }

    // MARK: - 最近项目

    public func touchFolder(_ url: URL, displayName: String? = nil) throws {
        let path = url.standardizedFileURL.path
        let name = displayName ?? url.lastPathComponent
        try db.run(
            """
            INSERT INTO folders (path, display_name, last_opened) VALUES (?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET last_opened = excluded.last_opened,
                                            display_name = excluded.display_name;
            """,
            [.text(path), .text(name), .real(Date().timeIntervalSince1970)]
        )
    }

    public func recentFolders(limit: Int = 20) throws -> [RecentFolder] {
        let rows = try db.query(
            "SELECT id, path, display_name, last_opened FROM folders ORDER BY last_opened DESC LIMIT ?;",
            [.integer(Int64(limit))]
        )
        return rows.compactMap { row in
            guard let id = row["id"]?.intValue,
                  let path = row["path"]?.stringValue,
                  let name = row["display_name"]?.stringValue,
                  let opened = row["last_opened"]?.doubleValue else { return nil }
            return RecentFolder(id: Int64(id), path: path, displayName: name, lastOpened: Date(timeIntervalSince1970: opened))
        }
    }

    public func forgetFolder(atPath path: String) throws {
        try db.run("DELETE FROM folders WHERE path = ?;", [.text(path)])
        try db.run("DELETE FROM assets WHERE folder_path = ?;", [.text(path)])
    }

    public func clearRecentFolders() throws {
        try db.execute("DELETE FROM folders;")
    }

    // MARK: - 星级

    public func setRating(_ rating: Int, folder: URL, baseName: String, captureDate: Date?, primaryPath: String?, isVideo: Bool) throws {
        let clamped = max(0, min(5, rating))
        try db.run(
            """
            INSERT INTO assets (folder_path, base_key, base_name, rating, capture_date, primary_path, is_video, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(folder_path, base_key) DO UPDATE SET
                rating = excluded.rating,
                base_name = excluded.base_name,
                capture_date = excluded.capture_date,
                primary_path = excluded.primary_path,
                is_video = excluded.is_video,
                updated_at = excluded.updated_at;
            """,
            [
                .text(folder.standardizedFileURL.path),
                .text(baseName.lowercased()),
                .text(baseName),
                .integer(Int64(clamped)),
                captureDate.map { SQLValue.real($0.timeIntervalSince1970) } ?? .null,
                primaryPath.map { SQLValue.text($0) } ?? .null,
                .integer(isVideo ? 1 : 0),
                .real(Date().timeIntervalSince1970),
            ]
        )
    }

    public func rating(folder: URL, baseName: String) throws -> Int? {
        let row = try db.queryOne(
            "SELECT rating FROM assets WHERE folder_path = ? AND base_key = ?;",
            [.text(folder.standardizedFileURL.path), .text(baseName.lowercased())]
        )
        return row?["rating"]?.intValue
    }

    /// 某个文件夹的全部星级，键是主文件名（小写）。
    public func ratings(inFolder folder: URL) throws -> [String: Int] {
        let rows = try db.query(
            "SELECT base_key, rating FROM assets WHERE folder_path = ?;",
            [.text(folder.standardizedFileURL.path)]
        )
        var result: [String: Int] = [:]
        for row in rows {
            guard let key = row["base_key"]?.stringValue, let rating = row["rating"]?.intValue else { continue }
            result[key] = rating
        }
        return result
    }

    public func assetCount(inFolder folder: URL) throws -> Int {
        let row = try db.queryOne(
            "SELECT COUNT(*) AS count FROM assets WHERE folder_path = ?;",
            [.text(folder.standardizedFileURL.path)]
        )
        return row?["count"]?.intValue ?? 0
    }

    /// 「删除评分数据库」的效果：清空软件自己的记录，文件里的星级不受影响。
    public func deleteAllRatings() throws {
        try db.execute("DELETE FROM assets;")
    }

    public func deleteDatabaseFiles() throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
    }
}
