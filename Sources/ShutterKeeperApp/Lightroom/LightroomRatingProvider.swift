import Foundation
import ShutterKeeperCore

/// 把 Lightroom 目录里的星级提供给审阅界面。
///
/// Lightroom 默认不把星级写进文件，所以「文件里没有星级」不代表「没打过分」。
/// 这里只在内存里缓存一次整库的「路径 → 星级」，之后按文件夹取子集，开销很小。
/// 全程只读，不会修改 Lightroom 的目录。
actor LightroomRatingProvider {
    static let shared = LightroomRatingProvider()

    struct Snapshot: Sendable {
        let catalogName: String
        /// 文件路径 → 星级（只包含大于 0 的）
        let ratings: [String: Int]
    }

    private var catalogURL: URL?
    private var allRatings: [String: Int]?
    private var lookupFailed = false

    /// 用户设置：是否自动读取 Lightroom 目录（默认开）。
    var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: PrefKey.readLightroomRatings) == nil { return true }
        return UserDefaults.standard.bool(forKey: PrefKey.readLightroomRatings)
    }

    var currentCatalogPath: String? {
        resolveCatalogURL()?.path
    }

    func setCatalog(_ url: URL?) {
        catalogURL = url
        allRatings = nil
        lookupFailed = false
        if let url {
            UserDefaults.standard.set(url.path, forKey: PrefKey.lightroomCatalogPath)
        } else {
            UserDefaults.standard.removeObject(forKey: PrefKey.lightroomCatalogPath)
        }
    }

    func invalidateCache() {
        allRatings = nil
        lookupFailed = false
    }

    /// 取某个文件夹（含子文件夹）里、Lightroom 目录中已评分的照片。
    func snapshot(for folder: URL) -> Snapshot? {
        guard isEnabled else { return nil }
        guard let catalogURL = resolveCatalogURL(), let all = loadAll(from: catalogURL) else { return nil }
        let prefix = folder.standardizedFileURL.path
        var result: [String: Int] = [:]
        for (path, rating) in all where rating > 0 {
            guard path.hasPrefix(prefix) else { continue }
            result[path] = rating
        }
        return Snapshot(catalogName: catalogURL.deletingPathExtension().lastPathComponent, ratings: result)
    }

    // MARK: - 内部

    private func resolveCatalogURL() -> URL? {
        if let catalogURL, FileManager.default.fileExists(atPath: catalogURL.path) {
            return catalogURL
        }
        if let saved = UserDefaults.standard.string(forKey: PrefKey.lightroomCatalogPath),
           FileManager.default.fileExists(atPath: saved) {
            catalogURL = URL(fileURLWithPath: saved)
            return catalogURL
        }
        guard let discovered = LightroomCatalog.discover().first else { return nil }
        catalogURL = discovered
        UserDefaults.standard.set(discovered.path, forKey: PrefKey.lightroomCatalogPath)
        return discovered
    }

    private func loadAll(from url: URL) -> [String: Int]? {
        if let allRatings { return allRatings }
        guard !lookupFailed else { return nil }
        do {
            let ratings = try LightroomCatalog(url: url).allRatings()
            allRatings = ratings
            return ratings
        } catch {
            // Lightroom 正在运行、目录打不开等等：静默放弃，不影响正常审阅
            lookupFailed = true
            return nil
        }
    }
}
