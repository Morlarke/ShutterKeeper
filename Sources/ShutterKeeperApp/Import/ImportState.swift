import AppKit
import ShutterKeeperCore
import SwiftUI

/// 一个按拍摄日期分好的来源分组（界面上按天展示）。
struct ImportDayGroup: Identifiable {
    var id: String
    var title: String
    var assets: [AssetGroup]

    var fileCount: Int {
        assets.reduce(0) { $0 + $1.files.count + $1.sidecars.count }
    }
}

/// 线程安全的取消标记（后台拷贝线程要读它）。
final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        value = false
        lock.unlock()
    }
}

/// 导入模块的状态。
@MainActor
final class ImportState: ObservableObject {
    @Published private(set) var volumes: [SourceVolume] = []
    @Published private(set) var source: URL?
    @Published private(set) var sourceLabel: String = ""
    @Published private(set) var assets: [AssetGroup] = []
    @Published private(set) var dayGroups: [ImportDayGroup] = []
    @Published private(set) var sourceBytes: Int64 = 0
    @Published private(set) var sourceFileCount = 0

    @Published var projectName = ""
    @Published var dateText = ""
    @Published var destinationRoot: URL?
    @Published var backupRoot: URL?
    @Published var copyToBackup = false

    @Published private(set) var plan: ImportPlan?
    @Published private(set) var isScanning = false
    @Published private(set) var isImporting = false
    @Published var progress: ImportProgress?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// 目标项目文件夹已存在，等用户决定。
    @Published var projectFolderConflict = false
    /// 文件级冲突，等用户决定。
    @Published var pendingConflicts: [ImportConflict] = []
    /// 导入完成后询问是否清理卡内原文件。
    @Published var askToTrashSources = false
    @Published private(set) var lastOutcome: ImportOutcome?
    @Published private(set) var lastProjectURL: URL?

    private let cancelFlag = CancellationFlag()
    private var history: ImportHistoryStore?
    /// 目标已存在时用户选择「新建带后缀」后的名字。
    private var folderNameOverride: String?

    /// 导入成功后回调，通知主状态「刚导入的文件夹是这里」。
    var onDidImport: ((URL) -> Void)?

    let paths: AppPaths

    init(paths: AppPaths = .default) {
        self.paths = paths
        history = try? ImportHistoryStore(databaseURL: paths.databaseURL)
        if let saved = UserDefaults.standard.string(forKey: PrefKey.importDestinationRoot) {
            destinationRoot = URL(fileURLWithPath: saved)
        }
        if destinationRoot == nil {
            destinationRoot = defaultDestination
        }
        if let saved = UserDefaults.standard.string(forKey: PrefKey.backupPath), !saved.isEmpty {
            backupRoot = URL(fileURLWithPath: saved)
        }
        copyToBackup = UserDefaults.standard.bool(forKey: PrefKey.copyToBackup)
        refreshVolumes()
        // 默认来源：插着的外接设备（有 DCIM 的优先，其次可推出的外接盘）
        if let preferred = volumes.preferredSource {
            selectSource(preferred.url, label: preferred.name)
        }
    }

    // MARK: - 来源

    func refreshVolumes() {
        volumes = VolumeScanner.mountedVolumes()
    }

    func selectSource(_ url: URL, label: String? = nil) {
        source = url
        sourceLabel = label ?? url.lastPathComponent
        folderNameOverride = nil
        scanSource()
    }

    func chooseSourceFolder() {
        guard let url = FolderPicker.chooseFolder(message: "选择要导入的文件夹或 SD 卡目录") else { return }
        selectSource(url)
    }

    private func scanSource() {
        guard let source else { return }
        isScanning = true
        statusMessage = "正在读取来源…"
        Task.detached(priority: .userInitiated) {
            let urls = VolumeScanner.mediaFiles(in: source)
            let refs = urls.map { url -> FileRef in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                return FileRef(
                    url: url,
                    fileSize: values?.fileSize.map(Int64.init),
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate
                )
            }
            var groups = Pairing.group(refs)
            for index in groups.indices { FolderScanner.enrich(&groups[index]) }
            groups.sort { $0.sortKey < $1.sortKey }
            let scannedGroups = groups
            let bytes = refs.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
            let fileCount = refs.count

            await MainActor.run {
                self.assets = scannedGroups
                self.sourceBytes = bytes
                self.sourceFileCount = fileCount
                self.dayGroups = Self.makeDayGroups(scannedGroups)
                self.isScanning = false
                self.statusMessage = fileCount == 0 ? "这个来源里没有找到素材" : "来源里有 \(fileCount) 个文件"
                self.rebuildPlan()
            }
        }
    }

    static func makeDayGroups(_ assets: [AssetGroup]) -> [ImportDayGroup] {
        var order: [String] = []
        var contents: [String: [AssetGroup]] = [:]
        for asset in assets {
            let day = asset.captureDate.map { ReviewSession.dayIdentifier(for: $0) } ?? "unknown"
            if contents[day] == nil {
                contents[day] = []
                order.append(day)
            }
            contents[day]?.append(asset)
        }
        return order.map { day in
            let title: String
            if day == "unknown" {
                title = "没有拍摄时间"
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "zh_CN")
                formatter.dateFormat = "yyyy年M月d日 EEEE"
                title = contents[day]?.first?.captureDate.map { formatter.string(from: $0) } ?? day
            }
            return ImportDayGroup(id: day, title: title, assets: contents[day] ?? [])
        }
    }

    // MARK: - 计划

    var parsedExplicitDate: Date? {
        let text = dateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd", "yyyymmdd", "yyyy/MM/dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    var earliestCaptureDate: Date? {
        assets.compactMap(\.captureDate).min()
    }

    var settings: ImportSettings {
        ImportSettings(
            projectName: projectName,
            dateFormat: UserDefaults.standard.string(forKey: PrefKey.dateFormat) ?? "yyyymmdd",
            explicitDate: parsedExplicitDate,
            destinationRoot: destinationRoot ?? defaultDestination,
            backupRoot: backupRoot,
            copyToBackup: copyToBackup
        )
    }

    var defaultDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
    }

    func rebuildPlan() {
        guard !assets.isEmpty else {
            plan = nil
            return
        }
        let identity = source.map { VolumeScanner.volumeIdentity(for: $0) }
        let historyKeys = (identity.flatMap { try? history?.keys(forVolume: $0.name) }) ?? []
        plan = ImportPlanner.plan(
            assets: assets,
            settings: settings,
            volumeName: identity?.name,
            sourceRoot: identity?.root,
            importedHistory: historyKeys,
            folderNameOverride: folderNameOverride
        )
    }

    func chooseDestination() {
        guard let url = FolderPicker.chooseFolder(message: "选择导入的目标位置（项目文件夹建在这里）") else { return }
        destinationRoot = url
        UserDefaults.standard.set(url.path, forKey: PrefKey.importDestinationRoot)
        rebuildPlan()
    }

    func chooseBackup() {
        guard let url = FolderPicker.chooseFolder(message: "选择备份位置") else { return }
        backupRoot = url
        UserDefaults.standard.set(url.path, forKey: PrefKey.backupPath)
        copyToBackup = true
        UserDefaults.standard.set(true, forKey: PrefKey.copyToBackup)
        rebuildPlan()
    }

    func setCopyToBackup(_ value: Bool) {
        copyToBackup = value
        UserDefaults.standard.set(value, forKey: PrefKey.copyToBackup)
        rebuildPlan()
    }

    // MARK: - 执行

    var canStart: Bool {
        guard let plan, !plan.tasks.isEmpty, destinationRoot != nil else { return false }
        return !isImporting && !isScanning
    }

    func start() {
        guard let plan else { return }
        if plan.destinationExists {
            projectFolderConflict = true
            return
        }
        if !plan.conflicts.isEmpty {
            pendingConflicts = plan.conflicts
            return
        }
        run(plan: plan, decisions: [:])
    }

    /// 目标文件夹已存在：合并进已有文件夹。
    func resolveFolderConflictMerge() {
        projectFolderConflict = false
        guard let plan else { return }
        if !plan.conflicts.isEmpty {
            pendingConflicts = plan.conflicts
        } else {
            run(plan: plan, decisions: [:])
        }
    }

    /// 目标文件夹已存在：新建带后缀的文件夹。
    func resolveFolderConflictNewFolder() {
        projectFolderConflict = false
        guard let plan, let destinationRoot = settings.destinationRoot as URL? else { return }
        folderNameOverride = ImportPlanner.availableFolderName(base: plan.projectFolderName, in: destinationRoot)
        rebuildPlan()
        guard let newPlan = self.plan else { return }
        if !newPlan.conflicts.isEmpty {
            pendingConflicts = newPlan.conflicts
        } else {
            run(plan: newPlan, decisions: [:])
        }
    }

    func cancelFolderConflict() {
        projectFolderConflict = false
    }

    func resolveConflicts(_ decision: ImportDecision) {
        let conflicts = pendingConflicts
        pendingConflicts = []
        guard let plan else { return }
        var decisions: [String: ImportDecision] = [:]
        for conflict in conflicts {
            decisions[conflict.task.source.path] = decision
        }
        run(plan: plan, decisions: decisions)
    }

    func cancelConflicts() {
        pendingConflicts = []
    }

    func cancelImport() {
        cancelFlag.set()
        statusMessage = "正在取消…"
    }

    private func run(plan: ImportPlan, decisions: [String: ImportDecision]) {
        isImporting = true
        cancelFlag.reset()
        progress = nil
        statusMessage = nil
        let identity = source.map { VolumeScanner.volumeIdentity(for: $0) }
        let historyStore = history

        Task.detached(priority: .userInitiated) {
            var options = ImportExecutor.Options()
            options.decisions = decisions
            options.history = historyStore
            options.volumeName = identity?.name
            options.sourceRoot = identity?.root
            let flag = self.cancelFlag
            options.shouldCancel = { flag.isSet }
            options.progress = { progress in
                Task { @MainActor in self.progress = progress }
            }
            let outcome = ImportExecutor.run(plan: plan, options: options)
            await MainActor.run {
                self.isImporting = false
                self.progress = nil
                self.lastOutcome = outcome
                self.lastProjectURL = plan.projectURL
                if !outcome.failures.isEmpty {
                    self.errorMessage = outcome.failures
                        .prefix(6)
                        .map { "\($0.url.lastPathComponent)：\($0.message)" }
                        .joined(separator: "\n")
                }
                var summary = outcome.cancelled ? "已取消，成功导入 \(outcome.copied.count) 个文件" : "导入完成：\(outcome.copied.count) 个文件"
                if !outcome.skipped.isEmpty { summary += "，跳过 \(outcome.skipped.count) 个" }
                if !outcome.backupFailures.isEmpty { summary += "，备份失败 \(outcome.backupFailures.count) 个" }
                self.statusMessage = summary
                if !outcome.copied.isEmpty {
                    self.askToTrashSources = true
                    self.onDidImport?(plan.projectURL)
                }
            }
        }
    }

    // MARK: - 收尾

    /// 把已确认导入的卡内原文件移入废纸篓。
    func trashSourceFiles() {
        askToTrashSources = false
        guard let outcome = lastOutcome, !outcome.copied.isEmpty else { return }
        let result = TrashService.moveToTrash(outcome.copiedSourceURLs)
        if result.failures.isEmpty {
            statusMessage = "已把 \(result.trashed.count) 个卡内原文件移入废纸篓"
        } else {
            errorMessage = result.failures
                .prefix(6)
                .map { "\($0.url.lastPathComponent)：\($0.message)" }
                .joined(separator: "\n")
        }
        rescanAfterCleanup()
    }

    func keepSourceFiles() {
        askToTrashSources = false
    }

    private func rescanAfterCleanup() {
        guard source != nil else { return }
        scanSource()
    }

    /// 在访达里显示刚导入的项目文件夹。
    func revealProject() {
        guard let url = lastProjectURL else { return }
        FolderPicker.reveal(url)
    }
}
