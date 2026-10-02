import Foundation
import ShutterKeeperCore
import SwiftUI
import UniformTypeIdentifiers

enum AppTab: String, CaseIterable, Identifiable {
    case importTab
    case rename
    case review

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importTab: return "导入"
        case .rename: return "改名"
        case .review: return "审阅"
        }
    }

    var systemImage: String {
        switch self {
        case .importTab: return "square.and.arrow.down"
        case .rename: return "pencil"
        case .review: return "star"
        }
    }
}

/// 全局状态。三个模块互相独立，但共用数据目录、评分数据库与缩略图缓存。
@MainActor
final class AppState: ObservableObject {
    @Published var selectedTab: AppTab = .review
    @Published var recentFolders: [RecentFolder] = []
    @Published var currentFolder: URL?
    @Published var scanResult: FolderScanResult?
    /// 审阅模块的状态（打开文件夹后创建）。
    @Published private(set) var review: ReviewState?
    /// 批量改名模块的状态（全应用共用一份，撤销记录跟着 App 走）。
    @Published private(set) var rename = RenameState()
    /// 导入模块的状态。
    let importer = ImportState()
    /// 待确认的 Lightroom 星级同步。
    @Published var lightroomRequest: LightroomSyncRequest?
    @Published private(set) var isLightroomSyncing = false
    /// 正在使用的 Lightroom 目录文件路径（自动检测或手动选择）。
    @Published private(set) var lightroomCatalogPath: String?
    /// 最近一次导入的目标文件夹（导入模块完成后会写进来）。
    @Published private(set) var lastImportedFolder: URL?
    @Published var isScanning = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// 从文件元数据里读到的星级（RAW 的 .xmp、JPG 内部元数据），键是 `AssetGroup.id`。
    @Published var fileRatings: [String: Int] = [:]

    let paths: AppPaths
    private(set) var store: RatingStore?
    private(set) var thumbnailCache: ThumbnailCache?

    init(paths: AppPaths = .default) {
        self.paths = paths
        do {
            try paths.ensureDirectories()
            store = try RatingStore(databaseURL: paths.databaseURL)
        } catch {
            errorMessage = "评分数据库不可用：\(error.localizedDescription)"
        }
        thumbnailCache = try? ThumbnailCache(root: paths.thumbnailDirectory)
        if let saved = UserDefaults.standard.string(forKey: PrefKey.lastImportedFolder) {
            lastImportedFolder = URL(fileURLWithPath: saved)
        }
        // 改名完成后，让审阅模块默认进到刚改名的文件夹
        rename.onDidRename = { [weak self] folder in
            self?.open(folder: folder)
        }
        importer.onDidImport = { [weak self] folder in
            self?.noteImportedFolder(folder)
        }
        refreshRecentFolders()
        refreshLightroomCatalogPath()
    }

    func refreshLightroomCatalogPath() {
        Task {
            lightroomCatalogPath = await LightroomRatingProvider.shared.currentCatalogPath
        }
    }

    // MARK: - 模块之间的默认文件夹

    /// 改名模块默认进：最近导入的 → 当前打开的 → 最近用过的。
    var defaultRenameFolder: URL? {
        if let lastImportedFolder, FileManager.default.fileExists(atPath: lastImportedFolder.path) {
            return lastImportedFolder
        }
        return currentFolder ?? recentFolders.first?.url
    }

    /// 导入完成后调用（M4 会用到）：把目标文件夹记下来，改名模块默认进这里。
    func noteImportedFolder(_ url: URL) {
        lastImportedFolder = url
        UserDefaults.standard.set(url.path, forKey: PrefKey.lastImportedFolder)
        // 刚导入的项目就是接下来要改名的对象，直接把改名模块切过去
        rename.open(folder: url)
    }

    /// 审阅模块默认进入改名模块正在处理的那个文件夹。
    ///
    /// 只在两边文件夹不一致时才重新加载，避免每次切标签都重扫一遍。
    func syncReviewToRenameFolder() {
        guard let folder = rename.folder else { return }
        if currentFolder?.standardizedFileURL == folder.standardizedFileURL { return }
        open(folder: folder)
    }

    // MARK: - Lightroom 目录同步

    struct LightroomSyncRequest: Identifiable {
        let id = UUID()
        let catalogURL: URL
        let plan: LightroomSync.Plan
    }

    /// 读取 Lightroom 目录，算出这个文件夹里有哪些星级需要写进文件。
    func prepareLightroomSync(catalog explicitCatalog: URL? = nil) {
        guard let folder = currentFolder else {
            errorMessage = "先打开一个文件夹"
            return
        }
        let catalogURL: URL?
        if let explicitCatalog {
            catalogURL = explicitCatalog
        } else {
            catalogURL = LightroomCatalog.discover().first
        }
        guard let catalogURL else {
            errorMessage = "没有找到 Lightroom 目录文件（.lrcat）。可以用「选择 Lightroom 目录…」手动指定。"
            return
        }
        statusMessage = "正在读取 Lightroom 目录…"
        Task.detached(priority: .userInitiated) {
            do {
                let ratings = try LightroomCatalog(url: catalogURL).ratings(under: folder)
                let scan = try FolderScanner.scan(folder: folder, readMetadata: false)
                let plan = LightroomSync.plan(groups: scan.groups, catalogRatings: ratings)
                await MainActor.run {
                    self.statusMessage = nil
                    self.lightroomRequest = LightroomSyncRequest(catalogURL: catalogURL, plan: plan)
                }
            } catch {
                await MainActor.run {
                    self.statusMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func chooseLightroomCatalog() {
        let panel = NSOpenPanel()
        panel.message = "选择 Lightroom 目录文件（.lrcat）"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "lrcat") ?? .data]
        panel.directoryURL = LightroomCatalog.discover().first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await LightroomRatingProvider.shared.setCatalog(url) }
        lightroomCatalogPath = url.path
        prepareLightroomSync(catalog: url)
    }

    func cancelLightroomSync() {
        lightroomRequest = nil
    }

    /// 按计划把星级写进文件（RAW 写 .xmp，JPG 写文件内部元数据）。
    func confirmLightroomSync() {
        guard let request = lightroomRequest else { return }
        lightroomRequest = nil
        let updates = request.plan.updates
        guard !updates.isEmpty else {
            statusMessage = "文件里的星级已经和 Lightroom 一致，无需写入"
            return
        }
        isLightroomSyncing = true
        statusMessage = "正在写入 \(updates.count) 张的星级…"
        Task.detached(priority: .userInitiated) {
            let outcome = LightroomSync.apply(plan: request.plan)
            await MainActor.run {
                self.isLightroomSyncing = false
                if let error = outcome.errors.first {
                    self.errorMessage = error
                } else {
                    for update in updates {
                        try? self.store?.setRating(
                            update.rating,
                            folder: update.group.folder,
                            baseName: update.group.baseName,
                            captureDate: update.group.captureDate,
                            primaryPath: update.group.previewFile?.url.path,
                            isVideo: update.group.isVideo
                        )
                    }
                    let databaseOnly = outcome.databaseOnlyFiles.count
                    var message = "已写入 \(outcome.writtenFiles.count) 个文件"
                    if databaseOnly > 0 {
                        message += "；\(databaseOnly) 个 DNG/HEIC 只记在软件内"
                    }
                    self.statusMessage = message
                    self.review?.refreshRatingsFromFiles()
                    Task { await LightroomRatingProvider.shared.invalidateCache() }
                }
            }
        }
    }

    // MARK: - 最近项目

    func refreshRecentFolders() {
        do {
            recentFolders = try store?.recentFolders() ?? []
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 模块切换（⌘\ 与 ⌘⇧\）

    func selectNextModule() {
        let tabs = AppTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab) else { return }
        selectedTab = tabs[(index + 1) % tabs.count]
    }

    func selectPreviousModule() {
        let tabs = AppTab.allCases
        guard let index = tabs.firstIndex(of: selectedTab) else { return }
        selectedTab = tabs[(index - 1 + tabs.count) % tabs.count]
    }

    // MARK: - 改名（供菜单调用）

    var canUndoRename: Bool { rename.canUndo }

    func undoLastRename() {
        rename.undoLastRename()
    }

    func open(folder: URL) {
        currentFolder = folder
        // 改名模块还没选过文件夹时，默认跟着走到刚打开的文件夹
        rename.openDefaultFolderIfNeeded(lastUsed: folder)
        try? store?.touchFolder(folder)
        refreshRecentFolders()
        rescan()
    }

    func forget(folder: RecentFolder) {
        try? store?.forgetFolder(atPath: folder.path)
        refreshRecentFolders()
    }

    func chooseFolder() {
        guard let url = FolderPicker.chooseFolder(message: "选择要审阅的文件夹") else { return }
        open(folder: url)
    }

    // MARK: - 扫描

    func rescan() {
        guard let folder = currentFolder else { return }
        isScanning = true
        statusMessage = "正在扫描…"
        let url = folder
        Task.detached(priority: .userInitiated) {
            do {
                let result = try FolderScanner.scan(folder: url)
                let ratings = await Self.readFileRatings(for: result.groups)
                let subfolders = FolderScanner.subfolders(of: url)
                await MainActor.run {
                    self.scanResult = result
                    self.fileRatings = ratings
                    self.isScanning = false
                    self.statusMessage = "共 \(result.groups.count) 张片子"
                    if let existing = self.review, existing.folderURL.standardizedFileURL == url.standardizedFileURL {
                        existing.reload(groups: result.groups, ratings: ratings)
                        existing.updateSubfolders(subfolders)
                    } else {
                        let review = ReviewState(
                            groups: result.groups,
                            ratings: ratings,
                            store: self.store,
                            thumbnailCache: self.thumbnailCache,
                            folderURL: url
                        )
                        review.onOpenFolder = { [weak self] folder in
                            self?.open(folder: folder)
                        }
                        review.onRequestLightroomSync = { [weak self] in
                            self?.prepareLightroomSync()
                        }
                        review.updateSubfolders(subfolders)
                        self.review = review
                    }
                }
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.statusMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    nonisolated static func readFileRatings(for groups: [AssetGroup]) async -> [String: Int] {
        var result: [String: Int] = [:]
        for group in groups {
            if let rating = RatingService.readRatingFromFiles(for: group) {
                result[group.id] = rating
            }
        }
        return result
    }

    /// 数据库里记录的星级（用于和文件里的元数据对照）。
    func storedRating(for group: AssetGroup) -> Int? {
        try? store?.rating(folder: group.folder, baseName: group.baseName)
    }

    func saveRating(_ rating: Int, for group: AssetGroup) {
        try? store?.setRating(
            rating,
            folder: group.folder,
            baseName: group.baseName,
            captureDate: group.captureDate,
            primaryPath: group.previewFile?.url.path,
            isVideo: group.isVideo
        )
    }

    // MARK: - 缓存与数据库维护

    func clearThumbnailCache() {
        Task {
            try? await thumbnailCache?.removeAll()
            statusMessage = "缩略图缓存已清空"
        }
    }

    func clearRatingDatabase() {
        do {
            try store?.deleteAllRatings()
            statusMessage = "评分数据库已清空（文件里的星级仍在）"
            refreshRecentFolders()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
