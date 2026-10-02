import AVFoundation
import AppKit
import ShutterKeeperCore
import SwiftUI

/// 审阅模块的状态与行为。
///
/// 界面只负责显示，所有决定（选中哪张、怎么筛选、写哪个文件、删除哪几个文件）
/// 都收敛在这里，核心算法在 `ShutterKeeperCore` 里，可以单独验证。
@MainActor
final class ReviewState: ObservableObject {
    @Published private(set) var session: ReviewSession
    @Published private(set) var preview: PreviewLoader.Preview?
    @Published private(set) var metadata: PhotoMetadata?
    @Published private(set) var isLoadingPreview = false
    @Published private(set) var isLoadingFullResolution = false
    @Published private(set) var player: AVPlayer?
    @Published var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var deleteTarget: AssetGroup?
    /// 0…1，1 表示已放大到 1:1 像素。
    @Published private(set) var zoomProgress: CGFloat = 0
    @Published var exifPanelVisible = true
    @Published var panelsVisible = true
    @Published var folderPanelVisible: Bool = {
        (UserDefaults.standard.object(forKey: PrefKey.folderPanelVisible) as? Bool) ?? true
    }() {
        didSet { UserDefaults.standard.set(folderPanelVisible, forKey: PrefKey.folderPanelVisible) }
    }
    @Published var thumbnailSize: CGFloat = 104
    /// 当前文件夹的子文件夹（空文件夹时用来提示往下走）。
    @Published private(set) var subfolders: [URL] = []
    /// 子文件夹是否已经读出来过（区分「还没读」和「真的没有」）。
    @Published private(set) var subfoldersLoaded = false
    /// 有多少张的星级是从 Lightroom 目录里读到的（文件里还没写）。
    @Published private(set) var catalogOnlyCount = 0
    /// 读到的 Lightroom 目录名，用于界面提示。
    @Published private(set) var lightroomCatalogName: String?
    /// 当前这次的缩放指令（⌘0 等）。
    @Published private(set) var zoomCommand: ZoomCommand?

    /// 打开另一个文件夹（文件夹面板用）。
    var onOpenFolder: ((URL) -> Void)?
    /// 请求把 Lightroom 目录里的星级写进文件。
    var onRequestLightroomSync: (() -> Void)?

    let store: RatingStore?
    let thumbnailCache: ThumbnailCache?
    let folderURL: URL

    /// 文件里读到的星级，用来和 Lightroom 目录做对比。
    private var fileRatings: [String: Int] = [:]
    private var catalogTask: Task<Void, Never>?

    private let loader = PreviewLoader()
    private var previewTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var fullResolutionTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var fullResolutionGroupID: String?
    private var targetPreviewPixel = 3000

    init(
        groups: [AssetGroup],
        ratings: [String: Int],
        store: RatingStore?,
        thumbnailCache: ThumbnailCache?,
        folderURL: URL,
        filter: RatingFilter = .inactive
    ) {
        self.session = ReviewSession(groups: groups, ratings: ratings, filter: filter)
        self.fileRatings = ratings
        self.store = store
        self.thumbnailCache = thumbnailCache
        self.folderURL = folderURL
        self.exifPanelVisible = (UserDefaults.standard.object(forKey: PrefKey.exifPanelVisible) as? Bool) ?? true
        syncCurrent()
        loadLightroomRatings()
    }

    deinit {
        previewTask?.cancel()
        metadataTask?.cancel()
        fullResolutionTask?.cancel()
        statusTask?.cancel()
        catalogTask?.cancel()
    }

    // MARK: - 列表信息

    var visibleGroups: [AssetGroup] { session.visibleGroups }
    var current: AssetGroup? { session.current }
    var currentID: String? { session.current?.id }
    var totalCount: Int { session.visibleCount }
    var isEmpty: Bool { session.visibleCount == 0 }

    /// 形如 12 / 345 的序号。
    var positionText: String {
        guard let index = session.currentVisibleIndex else { return "— / \(totalCount)" }
        return "\(index + 1) / \(totalCount)"
    }

    var currentRating: Int? { session.currentRating }

    var currentIsVideo: Bool { session.current?.isVideo ?? false }

    var dateGroupText: String? {
        guard let position = session.currentDateGroupPosition else { return nil }
        return "第 \(position) / \(session.dateGroups.count) 组"
    }

    func rating(for group: AssetGroup) -> Int? {
        session.rating(for: group)
    }

    // MARK: - 载入文件夹

    func reload(groups: [AssetGroup], ratings: [String: Int]) {
        fileRatings = ratings
        session.reload(groups: groups, ratings: ratings)
        fullResolutionGroupID = nil
        syncCurrent()
        loadLightroomRatings()
    }

    /// 打开另一个文件夹（左侧文件夹面板）。
    func openFolder(_ url: URL) {
        onOpenFolder?(url)
    }

    func updateSubfolders(_ folders: [URL]) {
        subfolders = folders
        subfoldersLoaded = true
    }

    /// 重新从文件里读一遍星级（Lightroom 目录同步之后调用）。
    func refreshRatingsFromFiles() {
        var updated: [String: Int] = [:]
        for group in session.groups {
            if let rating = RatingService.readRatingFromFiles(for: group) {
                updated[group.id] = rating
            }
        }
        fileRatings = updated
        session.reload(groups: session.groups, ratings: updated)
        syncCurrent()
        loadLightroomRatings()
    }

    /// 从 Lightroom 目录补齐「文件里没有、但 LR 里打过分」的星级。
    ///
    /// 只用于显示与筛选，不会改动任何文件；要让文件也带上星级，
    /// 用界面上的「写入文件」按钮（或审阅菜单里的同步命令）。
    private func loadLightroomRatings() {
        catalogTask?.cancel()
        let folder = folderURL
        let groups = session.groups
        catalogTask = Task {
            let snapshot = await LightroomRatingProvider.shared.snapshot(for: folder)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.applyLightroomSnapshot(snapshot, groups: groups)
            }
        }
    }

    private func applyLightroomSnapshot(_ snapshot: LightroomRatingProvider.Snapshot?, groups: [AssetGroup]) {
        guard let snapshot else {
            catalogOnlyCount = 0
            lightroomCatalogName = nil
            // 关掉「读取 Lightroom 目录」时回到文件里的星级
            session.reload(groups: groups, ratings: fileRatings)
            if session.filter.isActive {
                session.applyFilter(session.filter)
            }
            return
        }
        lightroomCatalogName = snapshot.catalogName
        var merged = fileRatings
        var catalogOnly = 0
        for group in groups {
            var catalogRating: Int?
            for file in group.files {
                if let value = snapshot.ratings[file.url.standardizedFileURL.path] {
                    catalogRating = value
                    break
                }
            }
            guard let catalogRating else { continue }
            if (fileRatings[group.id] ?? 0) == 0 {
                merged[group.id] = catalogRating
                catalogOnly += 1
            }
        }
        catalogOnlyCount = catalogOnly
        session.reload(groups: groups, ratings: merged)
        if session.filter.isActive {
            session.applyFilter(session.filter)
        }
    }

    // MARK: - 导航

    func select(id: String) {
        guard id != currentID else { return }
        session.select(id: id)
        syncCurrent()
    }

    func next() {
        session.selectNext()
        syncCurrent()
    }

    func previous() {
        session.selectPrevious()
        syncCurrent()
    }

    func nextDateGroup() {
        session.selectNextDateGroup()
        syncCurrent()
    }

    func previousDateGroup() {
        session.selectPreviousDateGroup()
        syncCurrent()
    }

    // MARK: - 筛选

    func setFilter(_ filter: RatingFilter) {
        session.applyFilter(filter)
        syncCurrent()
    }

    func applyFilterShortcut(_ action: ShortcutAction) {
        if action == .filterClear {
            setFilter(.inactive)
            showStatus("显示全部")
            return
        }
        guard let stars = action.filterStars else { return }
        setFilter(RatingFilter(isActive: true, comparison: .atLeast, stars: stars))
        showStatus("筛选：\(stars) 星及以上")
    }

    // MARK: - 打分

    func setRating(_ value: Int) {
        guard let group = session.current else { return }
        guard group.isRatable else {
            showStatus("视频不打分")
            return
        }
        session.setRating(value, for: group.id)
        try? store?.setRating(
            value,
            folder: group.folder,
            baseName: group.baseName,
            captureDate: group.captureDate,
            primaryPath: group.previewFile?.url.path,
            isVideo: group.isVideo
        )
        showStatus("\(group.displayName) → \(value) 星")

        // 筛选实时生效：打完之后如果这张不满足了，自动跳到下一张
        if session.filter.isActive {
            session.applyFilter(session.filter)
            syncCurrent()
        }

        Task.detached(priority: .userInitiated) {
            let outcome = RatingService.write(rating: value, to: group)
            await MainActor.run {
                if let message = outcome.errors.first {
                    self.errorMessage = message
                } else if !outcome.databaseOnlyFiles.isEmpty {
                    let names = outcome.databaseOnlyFiles.map(\.lastPathComponent).joined(separator: "、")
                    self.showStatus("\(names)：首版只记录在软件内，未写入文件")
                }
            }
        }
    }

    // MARK: - 删除

    func requestDelete() {
        guard let group = session.current else { return }
        deleteTarget = group
    }

    func confirmDelete() {
        guard let group = deleteTarget else { return }
        deleteTarget = nil
        let outcome = TrashService.moveToTrash(group: group)
        if outcome.allSucceeded {
            session.removeCurrent()
            syncCurrent()
            showStatus("已移入废纸篓：\(group.displayName)")
        } else {
            let detail = outcome.failures.map { "\($0.url.lastPathComponent)：\($0.message)" }.joined(separator: "\n")
            errorMessage = "删除未完成\n\(detail)"
        }
    }

    // MARK: - 视频

    func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
        }
    }

    func adjustVolume(_ delta: Float) {
        let value = min(1, max(0, volume + delta))
        volume = value
        showStatus("音量 \(Int((value * 100).rounded()))%")
    }

    // MARK: - 缩放

    func setViewportPixelWidth(_ width: CGFloat) {
        let target = Int(min(max(width * 1.5, 1200), 6000))
        guard abs(target - targetPreviewPixel) > 240 else { return }
        targetPreviewPixel = target
        loadPreview()
    }

    func updateZoomProgress(_ progress: CGFloat) {
        zoomProgress = progress
        // 放大接近 1:1 时换成原始分辨率，否则看到的还是缩略图放大后的虚像
        if progress >= 0.9, fullResolutionGroupID != currentID {
            loadFullResolution()
        }
    }

    /// 菜单 / 快捷键触发的缩放。
    func applyZoom(_ kind: ZoomCommand.Kind) {
        zoomCommand = ZoomCommand(kind: kind)
    }

    // MARK: - 快捷键分发

    /// 返回 true 表示这个操作被处理了。
    func handle(_ action: ShortcutAction) -> Bool {
        switch action {
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5:
            setRating(action.ratingValue ?? 0)
        case .next:
            next()
        case .previous:
            previous()
        case .nextDateGroup:
            nextDateGroup()
        case .previousDateGroup:
            previousDateGroup()
        case .volumeUp:
            adjustVolume(0.1)
        case .volumeDown:
            adjustVolume(-0.1)
        case .videoPlayPause:
            togglePlayback()
        case .toggleExifPanel:
            exifPanelVisible.toggle()
        case .togglePanels:
            panelsVisible.toggle()
        case .deleteCurrent:
            requestDelete()
        case .filterClear, .filterAtLeast1, .filterAtLeast2, .filterAtLeast3, .filterAtLeast4, .filterAtLeast5:
            applyFilterShortcut(action)
        case .thumbnailSizeUp:
            thumbnailSize = min(260, thumbnailSize + 24)
        case .thumbnailSizeDown:
            thumbnailSize = max(64, thumbnailSize - 24)
        case .toggleFullScreen:
            FullScreenController.toggle()
        case .zoomIn:
            applyZoom(.zoomIn)
        case .zoomOut:
            applyZoom(.zoomOut)
        case .zoomToFit:
            applyZoom(.fit)
        case .zoomToActualSize:
            applyZoom(.actualSize)
        case .parentFolder:
            guard let parent = FolderBrowserView.parent(of: folderURL) else {
                showStatus("已经是最上级文件夹")
                return true
            }
            onOpenFolder?(parent)
        case .toggleFolderPanel:
            folderPanelVisible.toggle()
        case .undo, .iconView, .columnView:
            // 这几个是改名模块的快捷键
            return false
        }
        return true
    }

    // MARK: - 选中项变化后的同步

    private func syncCurrent() {
        guard let group = session.current else {
            preview = nil
            metadata = nil
            player = nil
            return
        }

        // 视频：准备播放器；照片：准备图像与 EXIF
        if group.isVideo, let video = group.video {
            player?.pause()
            let newPlayer = AVPlayer(url: video.url)
            newPlayer.volume = volume
            player = newPlayer
            preview = nil
        } else {
            player?.pause()
            player = nil
            loadPreview()
        }
        loadMetadata(for: group)
        prefetchNeighbours()
    }

    private func loadPreview() {
        guard let group = session.current, !group.isVideo else { return }
        previewTask?.cancel()
        fullResolutionGroupID = nil
        isLoadingPreview = true
        let maxPixel = targetPreviewPixel
        previewTask = Task { [loader] in
            let result = await loader.preview(for: group, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.session.current?.id == group.id else { return }
                self.preview = result
                self.isLoadingPreview = false
            }
        }
    }

    private func loadFullResolution() {
        guard let group = session.current, !group.isVideo else { return }
        fullResolutionTask?.cancel()
        fullResolutionGroupID = group.id
        isLoadingFullResolution = true
        fullResolutionTask = Task { [loader] in
            let result = await loader.fullResolution(for: group)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.session.current?.id == group.id, let result else {
                    self.isLoadingFullResolution = false
                    return
                }
                self.preview = result
                self.isLoadingFullResolution = false
            }
        }
    }

    private func loadMetadata(for group: AssetGroup) {
        metadataTask?.cancel()
        metadata = nil
        guard let file = group.previewFile else { return }
        if file.kind == .video {
            metadataTask = Task {
                let result = await ExifReader.videoMetadata(url: file.url)
                await MainActor.run {
                    guard self.session.current?.id == group.id else { return }
                    self.metadata = result
                }
            }
            return
        }
        metadataTask = Task {
            let result = try? ExifReader.read(url: file.url)
            await MainActor.run {
                guard self.session.current?.id == group.id else { return }
                self.metadata = result
            }
        }
    }

    private func prefetchNeighbours() {
        let visible = session.visibleGroups
        guard let index = session.currentVisibleIndex else { return }
        let range = (index - 2)...(index + 2)
        let neighbours = range.compactMap { visible.indices.contains($0) ? visible[$0] : nil }
        let maxPixel = targetPreviewPixel
        Task { [loader] in
            await loader.prefetch(groups: neighbours, maxPixel: maxPixel)
        }
    }

    // MARK: - 提示

    private func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}

/// 窗口全屏切换。
enum FullScreenController {
    static var isFullScreen: Bool {
        NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
    }

    static func toggle() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    static func exit() {
        guard isFullScreen else { return }
        NSApp.keyWindow?.toggleFullScreen(nil)
    }
}
