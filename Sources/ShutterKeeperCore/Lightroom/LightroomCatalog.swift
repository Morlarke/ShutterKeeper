import Foundation

/// 只读访问 Lightroom Classic 的目录数据库（`.lrcat`）。
///
/// 用途：Lightroom 默认**不会**把星级写进文件（「自动将更改写入 XMP」默认关闭），
/// 这时星级只存在目录数据库里。快门闪选直接读这份数据库，就能看到你在 LR 里打的分。
///
/// 全程只读：不修改 LR 的目录，也不动它的预览缓存。
public struct LightroomCatalog {
    public enum CatalogError: Error, LocalizedError {
        case openFailed(URL, String)
        case queryFailed(String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let url, let message):
                return "无法打开 Lightroom 目录：\(url.lastPathComponent)（\(message)）。如果 Lightroom 正在运行，请先退出再试。"
            case .queryFailed(let message):
                return "读取 Lightroom 目录失败：\(message)"
            }
        }
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 在常见位置里找 Lightroom 目录文件。
    ///
    /// 会跳过备份目录里的旧目录（`Backups`、`Old Lightroom Catalogs` 之类），
    /// 结果按修改时间从新到旧排序，所以第一个通常就是当前在用的目录。
    public static func discover(in directories: [URL]? = nil, maxDepth: Int = 2) -> [URL] {
        let searchRoots = directories ?? [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents", isDirectory: true),
        ]
        var found: [URL] = []
        for root in searchRoots {
            found.append(contentsOf: search(root: root, maxDepth: maxDepth))
        }
        // 去重（同一个目录可能被多个搜索根覆盖）
        var seen = Set<String>()
        found = found.filter { seen.insert($0.standardizedFileURL.path).inserted }
        return found.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }

    /// 逐层向下找，最多 maxDepth 层。只做浅层搜索，避免遍历整个照片库。
    private static func search(root: URL, maxDepth: Int) -> [URL] {
        let fileManager = FileManager.default
        let excludedMarkers = ["backups", "backup", "old lightroom", "previews", "helper", "cache", "preview"]
        var results: [URL] = []
        var frontier: [(url: URL, depth: Int)] = [(root, 0)]

        while !frontier.isEmpty {
            let (directory, depth) = frontier.removeFirst()
            guard depth <= maxDepth else { continue }
            let contents = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in contents {
                let ext = item.pathExtension.lowercased()
                if ext == "lrcat" {
                    let lowercasedPath = item.path.lowercased()
                    if excludedMarkers.contains(where: { lowercasedPath.contains($0) }) { continue }
                    results.append(item)
                    continue
                }
                guard depth < maxDepth else { continue }
                guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                      values.isDirectory == true,
                      values.isPackage != true else { continue }
                // 跳过备份、预览缓存这类目录
                let name = item.lastPathComponent.lowercased()
                if excludedMarkers.contains(where: { name.contains($0) }) { continue }
                frontier.append((item, depth + 1))
            }
        }
        return results
    }

    /// 读取指定文件夹（含子文件夹）里所有照片的星级。只返回大于 0 的。
    ///
    /// 返回值的键是标准化之后的绝对路径。
    public func ratings(under folder: URL) throws -> [String: Int] {
        let all = try allRatings()
        let prefix = folder.standardizedFileURL.path
        var result: [String: Int] = [:]
        for (path, rating) in all where rating > 0 {
            guard path.hasPrefix(prefix) else { continue }
            result[path] = rating
        }
        return result
    }

    /// 读取整份目录的「文件路径 → 星级」。
    public func allRatings() throws -> [String: Int] {
        do {
            let database = try SQLiteDatabase(path: url.path, readOnly: true)
            return try queryRatings(in: database)
        } catch {
            // WAL 模式 + 只读连接在某些情况下会打不开（SQLite 需要 -shm 的写权限）。
            // 退回 immutable 方式再试一次：仍然只读，不写 LR 的任何文件。
            do {
                let database = try SQLiteDatabase(path: url.path, readOnly: true, immutable: true)
                return try queryRatings(in: database)
            } catch let fallbackError {
                throw CatalogError.openFailed(url, fallbackError.localizedDescription)
            }
        }
    }

    private func queryRatings(in database: SQLiteDatabase) throws -> [String: Int] {
        let sql = """
        SELECT (root.absolutePath || folder.pathFromRoot || file.baseName || '.' || file.extension) AS filepath,
               image.rating AS rating
        FROM Adobe_images AS image
        JOIN AgLibraryFile AS file ON file.id_local = image.rootFile
        JOIN AgLibraryFolder AS folder ON folder.id_local = file.folder
        JOIN AgLibraryRootFolder AS root ON root.id_local = folder.rootFolder;
        """

        let rows: [[String: SQLValue]]
        do {
            rows = try database.query(sql)
        } catch {
            throw CatalogError.queryFailed(error.localizedDescription)
        }

        var result: [String: Int] = [:]
        result.reserveCapacity(rows.count)
        for row in rows {
            guard let path = row["filepath"]?.stringValue,
                  let rating = row["rating"]?.doubleValue else { continue }
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            result[normalized] = Int(rating.rounded())
        }
        return result
    }

    /// 统计目录里的星级分布，用于界面上快速确认目录是否可用。
    public func ratingHistogram() throws -> [Int: Int] {
        var histogram: [Int: Int] = [:]
        for (_, rating) in try allRatings() {
            histogram[rating, default: 0] += 1
        }
        return histogram
    }
}
