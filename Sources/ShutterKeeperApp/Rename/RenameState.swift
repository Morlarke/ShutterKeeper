import AppKit
import ShutterKeeperCore
import SwiftUI

/// 改名模块里内容区的显示方式（跟访达一致：⌘1 图标、⌘2 分栏）。
enum RenameViewMode: String, CaseIterable, Identifiable {
    case icons
    case columns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: return "图标视图"
        case .columns: return "分栏视图"
        }
    }

    var systemImage: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .columns: return "rectangle.split.3x1"
        }
    }
}

/// 分栏视图里的一行：文件夹或素材文件。
enum RenameBrowserRow: Hashable {
    case folder(URL)
    case file(RenameFilePreview)
}

/// 批量改名模块的状态。
@MainActor
final class RenameState: ObservableObject {
    @Published private(set) var folder: URL?
    @Published private(set) var groups: [AssetGroup] = []
    @Published private(set) var buckets: [RenameGroupPlan] = []
    /// 每个分组（按 id）的自定义文本。
    @Published private(set) var textSegments: [String: [String]] = [:]
    /// 自定义文本的段数（1–4 段），模板变成「日期_文本1_文本2_…_序列号」。
    @Published private(set) var segmentCount = 1
    /// 统一填写用的文本（每个文本段一个输入框）。
    @Published var bulkSegments: [String] = [""]
    @Published var settings = RenameSettings()
    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage: String?
    @Published var errorMessage: String?
    /// 上一次改名的结果，用于撤销（只保留本次运行期间）。
    @Published private(set) var lastOperations: [RenameOperation] = []
    @Published private(set) var lastFolderLabel: String?
    /// 待用户决定的冲突。
    @Published var pendingConflicts: [RenameConflict] = []
    @Published var viewMode: RenameViewMode = .columns

    /// 改名（或撤销）完成后回调，用来让其它模块跟上这个文件夹。
    var onDidRename: ((URL) -> Void)?

    // MARK: - 分栏浏览状态（访达式，支持键盘操作）

    /// 当前路径链，最后一列是正在看的文件夹。
    @Published private(set) var columns: [URL] = []
    /// 每列读到的子文件夹。
    @Published private(set) var columnChildren: [String: [URL]] = [:]
    /// 键盘高亮所在的行（当前列）。
    @Published var highlightedIndex = 0
    private var pendingHighlightName: String?

    private var plan = RenamePlan(
        settings: RenameSettings(),
        renameGroups: [],
        operations: [],
        conflicts: [],
        examples: [],
        unchangedCount: 0
    )

    var currentPlan: RenamePlan { plan }
    var canApply: Bool { folder != nil && !plan.operations.isEmpty && !isWorking }
    var canUndo: Bool { !lastOperations.isEmpty && !isWorking }
    var example: String? { plan.example }
    var conflictCount: Int { plan.conflicts.count }

    // MARK: - 扫描

    /// 没选过文件夹时，默认进入最近用过的那个（通常是刚导入的目录）。
    func openDefaultFolderIfNeeded(lastUsed: URL?) {
        guard folder == nil, let lastUsed else { return }
        open(folder: lastUsed)
    }

    func open(folder: URL) {
        open(folder: folder, highlightRowNamed: nil)
    }

    private func open(folder: URL, highlightRowNamed name: String?) {
        pendingHighlightName = name
        self.folder = folder
        highlightedIndex = 0
        // 换文件夹时先清空，免得旧目录的文件还挂在新目录的列里
        groups = []
        buckets = []
        plan = RenamePlan(
            settings: settings,
            renameGroups: [],
            operations: [],
            conflicts: [],
            examples: [],
            unchangedCount: 0
        )
        syncColumns()
        isScanning = true
        statusMessage = "正在读取文件夹…"
        Task.detached(priority: .userInitiated) {
            do {
                let result = try FolderScanner.scan(folder: folder)
                await MainActor.run {
                    self.groups = result.groups
                    self.rebuildPlan()
                    self.isScanning = false
                    self.statusMessage = "共 \(result.groups.count) 张片子"
                }
                await self.loadColumns()
            } catch {
                await MainActor.run {
                    self.isScanning = false
                    self.statusMessage = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 分栏导航

    /// 某一列要显示的行：当前列在文件夹后面接上素材文件。
    func rows(for directory: URL) -> [RenameBrowserRow] {
        let folders = (columnChildren[directory.standardizedFileURL.path] ?? []).map { RenameBrowserRow.folder($0) }
        if directory.standardizedFileURL == folder?.standardizedFileURL {
            return folders + currentPlan.files.map { RenameBrowserRow.file($0) }
        }
        return folders
    }

    /// 当前列（正在看的文件夹）的行。
    var currentColumnRows: [RenameBrowserRow] {
        guard let folder else { return [] }
        return rows(for: folder)
    }

    func isColumnLoaded(_ directory: URL) -> Bool {
        columnChildren[directory.standardizedFileURL.path] != nil
    }

    /// 键盘上/下：在当前列里移动高亮。
    func moveHighlight(by delta: Int) {
        let rows = currentColumnRows
        guard !rows.isEmpty else { return }
        highlightedIndex = min(max(0, highlightedIndex + delta), rows.count - 1)
    }

    /// 键盘右：进入高亮行的文件夹。
    func enterHighlighted() {
        let rows = currentColumnRows
        guard rows.indices.contains(highlightedIndex) else { return }
        if case .folder(let url) = rows[highlightedIndex] {
            open(folder: url)
        }
    }

    /// 键盘左：回到上一级，并把高亮落在刚才那个文件夹上。
    func leaveToParent() {
        guard let current = folder, let parent = FolderBrowserView.parent(of: current) else { return }
        open(folder: parent, highlightRowNamed: current.lastPathComponent)
    }

    /// 鼠标点某一列里的文件夹。
    func selectFolder(_ url: URL, rowIndex: Int, isCurrentColumn: Bool) {
        if isCurrentColumn { highlightedIndex = rowIndex }
        open(folder: url)
    }

    /// 把 「键盘左」 之后要恢复的高亮落到正确行上。
    private func applyPendingHighlight() {
        guard let name = pendingHighlightName, let folder else { return }
        let folders = columnChildren[folder.standardizedFileURL.path] ?? []
        if let index = folders.firstIndex(where: { $0.lastPathComponent == name }) {
            highlightedIndex = index
        }
        pendingHighlightName = nil
    }

    private func syncColumns() {
        guard let folder else {
            columns = []
            return
        }
        let target = folder.standardizedFileURL
        if columns.last?.standardizedFileURL == target { return }
        if let index = columns.firstIndex(where: { $0.standardizedFileURL == target }) {
            columns = Array(columns.prefix(index + 1))
        } else {
            columns = FolderBrowserView.ancestorChain(of: folder, limit: 3)
        }
    }

    /// 读每一列的子文件夹（视图里用 .task 调用）。
    func loadColumn(_ directory: URL) async {
        let key = directory.standardizedFileURL.path
        if columnChildren[key] != nil { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            FolderScanner.subfolders(of: directory)
        }.value
        columnChildren[key] = loaded
        if directory.standardizedFileURL == folder?.standardizedFileURL {
            applyPendingHighlight()
        }
    }

    private func loadColumns() async {
        for directory in columns {
            await loadColumn(directory)
        }
    }

    func chooseFolder() {
        guard let url = FolderPicker.chooseFolder(message: "选择要批量改名的文件夹") else { return }
        open(folder: url)
    }

    // MARK: - 计划

    func rebuildPlan() {
        // 先用空文本跑一次，拿到「日期 + 照片/视频」的分组 id
        let probe = RenamePlanner.plan(groups: groups, settings: settings)
        var texts: [String: String] = [:]
        for bucket in probe.renameGroups {
            if textSegments[bucket.id] == nil {
                textSegments[bucket.id] = Array(repeating: "", count: segmentCount)
            }
            texts[bucket.id] = joinedText(for: bucket.id)
        }
        let plan = RenamePlanner.plan(groups: groups, texts: texts, settings: settings)
        buckets = plan.renameGroups
        self.plan = plan
    }

    /// 某一组当前的分段文本（不足的按段数补齐）。
    func segments(for bucketID: String) -> [String] {
        var result = textSegments[bucketID] ?? []
        while result.count < segmentCount {
            result.append("")
        }
        if result.count > segmentCount {
            result = Array(result.prefix(segmentCount))
        }
        return result
    }

    func setSegment(_ index: Int, value: String, for bucketID: String) {
        var current = segments(for: bucketID)
        guard current.indices.contains(index) else { return }
        current[index] = value
        textSegments[bucketID] = current
        rebuildPlan()
    }

    /// 增加一个自定义文本段。
    func addSegment() {
        guard segmentCount < 4 else { return }
        segmentCount += 1
        while bulkSegments.count < segmentCount {
            bulkSegments.append("")
        }
        rebuildPlan()
    }

    /// 删掉最后一段。
    func removeSegment() {
        guard segmentCount > 1 else { return }
        segmentCount -= 1
        if bulkSegments.count > segmentCount {
            bulkSegments = Array(bulkSegments.prefix(segmentCount))
        }
        rebuildPlan()
    }

    /// 把统一填写的文本套用到所有分组。
    func applyBulkSegments() {
        let values = Array(bulkSegments.prefix(segmentCount))
        for bucket in buckets {
            var current = segments(for: bucket.id)
            for index in 0..<min(values.count, current.count) {
                current[index] = values[index]
            }
            textSegments[bucket.id] = current
        }
        rebuildPlan()
    }

    /// 把某组的分段文本拼成模板里的「自定义文本」部分。
    private func joinedText(for bucketID: String) -> String {
        segments(for: bucketID)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: settings.separator)
    }

    func updateSettings(_ update: (inout RenameSettings) -> Void) {
        var newSettings = settings
        update(&newSettings)
        settings = newSettings
        rebuildPlan()
    }

    // MARK: - 快捷键

    func handle(_ action: ShortcutAction) -> Bool {
        switch action {
        case .undo:
            guard canUndo else { return false }
            undoLastRename()
        case .iconView:
            viewMode = .icons
        case .columnView:
            viewMode = .columns
        case .next:
            guard viewMode == .columns else { return false }
            enterHighlighted()
        case .previous:
            guard viewMode == .columns else { return false }
            leaveToParent()
        case .nextDateGroup:
            guard viewMode == .columns else { return false }
            moveHighlight(by: 1)
        case .previousDateGroup:
            guard viewMode == .columns else { return false }
            moveHighlight(by: -1)
        case .toggleFolderPanel:
            // 改名模块没有独立的文件夹栏
            return false
        case .parentFolder:
            guard let parent = FolderBrowserView.parent(of: folder) else { return false }
            open(folder: parent)
        default:
            return false
        }
        return true
    }

    // MARK: - 执行

    func apply() {
        guard let folder else { return }
        guard !plan.operations.isEmpty else {
            statusMessage = "没有需要改名的文件"
            return
        }
        if !plan.conflicts.isEmpty {
            pendingConflicts = plan.conflicts
            return
        }
        run(plan: plan, skipping: [], replacing: [])
    }

    /// 冲突对话框：跳过冲突项，其余照常改。
    func applySkippingConflicts() {
        pendingConflicts = []
        let skipping = Set(plan.conflicts.map { $0.source.standardizedFileURL })
        run(plan: plan, skipping: skipping, replacing: [])
    }

    /// 冲突对话框：把已存在的目标文件移进废纸篓后覆盖。
    func applyReplacingConflicts() {
        pendingConflicts = []
        let replacing = Set(plan.conflicts.map { $0.target.standardizedFileURL })
        run(plan: plan, skipping: [], replacing: replacing)
    }

    func cancelConflicts() {
        pendingConflicts = []
    }

    private func run(plan: RenamePlan, skipping: Set<URL>, replacing: Set<URL>) {
        isWorking = true
        statusMessage = "正在改名…"
        Task.detached(priority: .userInitiated) {
            let outcome = RenameExecutor.apply(plan: plan, skipping: skipping, replacingTargets: replacing)
            await MainActor.run {
                self.isWorking = false
                if !outcome.renamed.isEmpty {
                    self.lastOperations = outcome.renamed
                    self.lastFolderLabel = self.folder?.lastPathComponent
                }
                if outcome.failures.isEmpty {
                    self.statusMessage = "已改名 \(outcome.renamed.count) 个文件"
                } else {
                    self.statusMessage = "已改名 \(outcome.renamed.count) 个，失败 \(outcome.failures.count) 个"
                    self.errorMessage = outcome.failures
                        .prefix(8)
                        .map { "\($0.url.lastPathComponent)：\($0.message)" }
                        .joined(separator: "\n")
                }
                // 改完重新扫描，界面上的名字才是最新的
                if let folder = self.folder {
                    self.refresh(folder: folder)
                    if !outcome.renamed.isEmpty { self.onDidRename?(folder) }
                }
            }
        }
    }

    func undoLastRename() {
        guard !lastOperations.isEmpty else { return }
        isWorking = true
        statusMessage = "正在撤销…"
        let operations = lastOperations
        Task.detached(priority: .userInitiated) {
            let outcome = RenameExecutor.undo(operations)
            await MainActor.run {
                self.isWorking = false
                self.lastOperations = []
                self.lastFolderLabel = nil
                if outcome.failures.isEmpty {
                    self.statusMessage = "已撤销 \(outcome.renamed.count) 个文件的改名"
                } else {
                    self.statusMessage = "撤销了 \(outcome.renamed.count) 个，\(outcome.failures.count) 个没能还原"
                    self.errorMessage = outcome.failures
                        .prefix(8)
                        .map { "\($0.url.lastPathComponent)：\($0.message)" }
                        .joined(separator: "\n")
                }
                if let folder = self.folder {
                    self.refresh(folder: folder)
                    if !outcome.renamed.isEmpty { self.onDidRename?(folder) }
                }
            }
        }
    }

    /// 只重新扫描（不清空用户填的文本）。
    func refresh(folder: URL? = nil) {
        guard let target = folder ?? self.folder else { return }
        Task.detached(priority: .userInitiated) {
            let result = try? FolderScanner.scan(folder: target)
            await MainActor.run {
                guard let result else { return }
                self.groups = result.groups
                self.rebuildPlan()
            }
        }
    }
}
