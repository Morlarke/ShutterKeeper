import AppKit
import ShutterKeeperCore
import SwiftUI

/// 一个按拍摄日期分好的来源分组（界面上按天展示）。
struct ImportDayGroup: Identifiable {
    var id: String
    var title: String
    var assets: [AssetGroup]
    /// 因为预览上限而没显示的张数。
    var hiddenCount = 0

    var fileCount: Int {
        assets.reduce(0) { $0 + $1.files.count + $1.sidecars.count }
    }
}

/// 扫描进度。
struct ImportScanState: Equatable {
    enum Phase: Equatable { case listing, readingDates }

    var phase: Phase
    var folders = 0
    var files = 0
    var datesDone = 0
    var datesTotal = 0

    var statusText: String {
        switch phase {
        case .listing:
            return folders == 0 ? "正在扫描来源…" : "正在扫描：已找到 \(files) 个文件（\(folders) 个文件夹）"
        case .readingDates:
            return "正在读取拍摄时间 \(datesDone)/\(datesTotal)"
        }
    }

    var fraction: Double? {
        guard phase == .readingDates, datesTotal > 0 else { return nil }
        return Double(datesDone) / Double(datesTotal)
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

    @Published var dateText = ""
    @Published var destinationRoot: URL?
    @Published var backupRoot: URL?
    @Published var copyToBackup = false

    @Published private(set) var plan: ImportPlan?
    @Published private(set) var isScanning = false
    @Published private(set) var scanState: ImportScanState?
    @Published private(set) var scanWarning: String?
    @Published private(set) var isImporting = false
    @Published var progress: ImportProgress?
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    /// 目标文件夹已存在，等用户决定。
    @Published var projectFolderConflict = false
    /// 文件级冲突，等用户决定。
    @Published var pendingConflicts: [ImportConflict] = []
    /// 导入完成后询问是否清理卡内原文件。
    @Published var askToTrashSources = false
    @Published private(set) var lastOutcome: ImportOutcome?
    @Published private(set) var lastProjectURL: URL?

    private let cancelFlag = CancellationFlag()
    private let scanCancelFlag = CancellationFlag()
    private var scanTask: Task<Void, Never>?
    private var history: ImportHistoryStore?
    /// 目标已存在时用户选择「新建带后缀」后的后缀（例如 `-2`）。
    private var folderSuffixOverride = ""

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
        // 默认来源：只自动选有 DCIM 的相机卡，避免误扫整块普通硬盘
        if let preferred = volumes.preferredSource {
            selectSource(preferred.url, label: preferred.name)
        } else {
            scanWarning = volumes.isEmpty ? "没有检测到 SD 卡 / U 盘，请插入后点刷新" : "没有找到相机卡（没有 DCIM 目录），请手动选择来源"
        }
    }

    // MARK: - 来源

    func refreshVolumes() {
        volumes = VolumeScanner.mountedVolumes()
    }

    func selectSource(_ url: URL, label: String? = nil) {
        scanCancelFlag.set()
        scanTask?.cancel()
        scanCancelFlag.reset()
        source = url
        sourceLabel = label ?? url.lastPathComponent
        folderSuffixOverride = ""
        assets = []
        dayGroups = []
        plan = nil
        sourceFileCount = 0
        sourceBytes = 0
        // 选到普通硬盘时明确提示：只扫顶层，不递归整块盘
        let isVolumeRoot = url.deletingLastPathComponent().standardizedFileURL.path == "/Volumes"
        let hasDCIM = !VolumeScanner.dcimFolders(in: url).isEmpty
        scanWarning = (isVolumeRoot && !hasDCIM) ? "这个卷没有 DCIM 目录，只扫描顶层文件夹（不会递归整块盘）" : nil
        scanSource()
    }

    func chooseSourceFolder() {
        guard let url = FolderPicker.chooseFolder(message: "选择要导入的文件夹或 SD 卡目录") else { return }
        selectSource(url)
    }

    private func scanSource() {
        guard let source else { return }
        scanTask?.cancel()
        scanCancelFlag.reset()
        isScanning = true
        statusMessage = nil
        scanState = ImportScanState(phase: .listing)
        let flag = scanCancelFlag

        scanTask = Task.detached(priority: .userInitiated) {
            // 1) 列出文件（边扫边报进度，可取消）
            let urls = VolumeScanner.mediaFiles(
                in: source,
                isCancelled: { flag.isSet },
                onProgress: { progress in
                    Task { @MainActor in self.applyScanProgress(progress) }
                }
            )
            if flag.isSet {
                await MainActor.run { self.finishScan(cancelled: true) }
                return
            }

            // 2) 先发布文件列表（拍摄时间稍后补），界面立刻能看到文件
            let refs = urls.map { url -> FileRef in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey])
                return FileRef(
                    url: url,
                    fileSize: values?.fileSize.map(Int64.init),
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate
                )
            }
            let baseGroups = Pairing.attachSidecars(Pairing.group(refs), allFiles: refs)
            let bytes = refs.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
            let fileCount = refs.count
            await MainActor.run {
                self.assets = baseGroups
                self.sourceBytes = bytes
                self.sourceFileCount = fileCount
                self.dayGroups = Self.makeDayGroups(baseGroups)
                self.scanState = ImportScanState(
                    phase: .readingDates,
                    folders: self.scanState?.folders ?? 0,
                    files: fileCount,
                    datesDone: 0,
                    datesTotal: baseGroups.count
                )
                self.rebuildPlan()
            }

            // 3) 逐组补拍摄时间，每 20 组刷新一次界面
            var groups = baseGroups
            for index in groups.indices {
                if flag.isSet || Task.isCancelled { break }
                FolderScanner.enrich(&groups[index])
                let done = index + 1
                if done % 20 == 0 || done == groups.count {
                    groups.sort { $0.sortKey < $1.sortKey }
                    let snapshot = groups
                    await MainActor.run {
                        self.assets = snapshot
                        self.dayGroups = Self.makeDayGroups(snapshot)
                        self.scanState?.datesDone = done
                        self.rebuildPlan()
                    }
                }
            }
            await MainActor.run { self.finishScan(cancelled: flag.isSet) }
        }
    }

    private func applyScanProgress(_ progress: VolumeScanner.ScanProgress) {
        guard isScanning, var state = scanState, state.phase == .listing else { return }
        state.folders = progress.foldersScanned
        state.files = progress.filesFound
        scanState = state
        if progress.limitReached {
            scanWarning = "文件太多，只扫描了前 \(progress.filesFound) 个"
        }
    }

    private func finishScan(cancelled: Bool) {
        isScanning = false
        scanState = nil
        if cancelled {
            statusMessage = "已取消扫描"
            return
        }
        statusMessage = sourceFileCount == 0 ? "这个来源里没有找到素材" : "来源里有 \(sourceFileCount) 个文件"
        rebuildPlan()
    }

    /// 用户点「取消扫描」。
    func cancelScan() {
        scanCancelFlag.set()
        scanTask?.cancel()
        isScanning = false
        scanState = nil
        statusMessage = "已取消扫描"
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
            folderSuffix: folderSuffixOverride
        )
    }

    func chooseDestination() {
        guard let url = FolderPicker.chooseFolder(message: "选择导入的目标位置（日期Photos / 日期Videos 建在这里）") else { return }
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
        folderSuffixOverride = ImportPlanner.availableFolderSuffix(dateKey: plan.dateKey, in: destinationRoot)
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
                self.lastProjectURL = plan.primaryFolderURL
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
                    self.onDidImport?(plan.primaryFolderURL)
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

    /// 在访达里显示刚导入的文件夹。
    func revealProject() {
        guard let url = lastProjectURL else { return }
        FolderPicker.reveal(url)
    }
}
