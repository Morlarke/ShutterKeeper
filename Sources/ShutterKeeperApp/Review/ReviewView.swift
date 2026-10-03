import AVKit
import ShutterKeeperCore
import SwiftUI

/// 审阅模块主界面：中央大图、底部胶片条、右侧 EXIF 面板。
struct ReviewView: View {
    @ObservedObject var review: ReviewState
    let theme: AppTheme

    @AppStorage(PrefKey.exifFields) private var exifFieldsRaw = ExifField.encode(Set(ExifField.defaultSelection))
    @AppStorage(PrefKey.background) private var backgroundRaw = AppBackground.neutralGray.rawValue

    @State private var resetToken = 0
    @State private var folderPanelWidth: CGFloat = 360
    @State private var dragStartWidth: CGFloat = 360

    private var exifFields: Set<ExifField> { ExifField.decode(exifFieldsRaw) }
    private var background: AppBackground { AppBackground(rawValue: backgroundRaw) ?? .neutralGray }

    var body: some View {
        HStack(spacing: 0) {
            if review.folderPanelVisible {
                FolderBrowserView(
                    currentFolder: review.folderURL,
                    knownSubfolders: review.subfoldersLoaded ? review.subfolders : nil,
                    theme: theme,
                    onOpen: { review.openFolder($0) },
                    onClose: { review.folderPanelVisible = false }
                )
                .frame(width: folderPanelWidth)
                resizeHandle
            }
            VStack(spacing: 0) {
                topBar
                separator
                HStack(spacing: 0) {
                    previewArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if review.exifPanelVisible, review.panelsVisible {
                        separator(vertical: true)
                        ExifPanelView(
                            group: review.current,
                            metadata: review.metadata,
                            rating: review.currentRating,
                            fields: exifFields,
                            theme: theme
                        )
                    }
                }
                if review.panelsVisible {
                    separator
                FilmstripView(
                    groups: review.visibleGroups,
                    selectedID: review.currentID,
                    selectedIDs: review.selection,
                    ratings: { review.rating(for: $0) },
                    thumbnailSize: review.thumbnailSize,
                    theme: theme,
                    cache: review.thumbnailCache,
                    onSelect: { id, extend, range in
                        review.select(id, extend: extend, range: range)
                    },
                    onContextMenuShown: { review.prepareContextAction(for: $0) },
                    onRotate: { review.rotate(clockwise: $0) },
                    onReveal: { review.revealSelection() },
                    onShowInfo: { review.showInfoForSelection() },
                    onDelete: { review.requestDelete() }
                )
                    .frame(height: review.thumbnailSize + 52)
                }
            }
        }
        .alert(
            review.pendingDelete.count > 1 ? "删除选中的 \(review.pendingDelete.count) 张？" : "删除这一张？",
            isPresented: Binding(
                get: { !review.pendingDelete.isEmpty },
                set: { if !$0 { review.cancelDelete() } }
            ),
            presenting: review.pendingDelete
        ) { _ in
            Button("移入废纸篓", role: .destructive) { review.confirmDelete() }
            Button("取消", role: .cancel) { review.cancelDelete() }
        } message: { groups in
            Text(deleteMessage(for: groups))
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { review.errorMessage != nil },
                set: { if !$0 { review.errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { review.errorMessage = nil }
        } message: {
            Text(review.errorMessage ?? "")
        }
    }

    private var separator: some View {
        Rectangle().fill(theme.separator).frame(height: 1)
    }

    private func deleteMessage(for groups: [AssetGroup]) -> String {
        let fileCount = groups.reduce(0) { $0 + $1.deletionTargets.count }
        var lines = ["将把这 \(groups.count) 张片子的 \(fileCount) 个文件移入废纸篓（配对成员和 .xmp 附属文件一起）。"]
        let names = groups.prefix(6).map(\.displayName)
        lines.append("")
        lines.append(names.joined(separator: "、"))
        if groups.count > names.count {
            lines.append("…等共 \(groups.count) 张")
        }
        return lines.joined(separator: "\n")
    }

    private func separator(vertical: Bool) -> some View {
        Rectangle().fill(theme.separator).frame(width: 1)
    }

    /// 文件夹面板的分隔条：拖动可以调宽度。
    private var resizeHandle: some View {
        Rectangle()
            .fill(theme.separator)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                // 用 set 而不是 push/pop，避免鼠标移出时把光标留在调整状态
                if hovering { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in
                        folderPanelWidth = min(760, max(190, dragStartWidth + value.translation.width))
                    }
                    .onEnded { _ in
                        dragStartWidth = folderPanelWidth
                    }
            )
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 14) {
            folderPanelToggle

            if let group = review.current {
                Text(group.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .leading)

                starControl(rating: review.currentRating, ratable: group.isRatable)

                Text(review.positionText)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.secondaryText)

                if let dateGroup = review.dateGroupText {
                    Text(dateGroup)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                if review.selectionCount > 1 {
                    Text("已选 \(review.selectionCount) 张")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                }
            } else {
                Text("没有可显示的片子")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            filterBar
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 文件夹面板开关：永远在顶部条最左边，收起后也一眼能看到。
    private var folderPanelToggle: some View {
        Button {
            review.folderPanelVisible.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 11, weight: .medium))
                Text("文件夹")
                    .font(.system(size: 11.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(review.folderPanelVisible ? Color.accentColor.opacity(0.85) : theme.panelBackground)
            )
            .foregroundStyle(review.folderPanelVisible ? Color.white : theme.primaryText)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(review.folderPanelVisible ? "收起文件夹面板（⌘⌥B）" : "展开文件夹面板（⌘⌥B）")
    }

    /// 星级来自 Lightroom 目录时的提示（文件里还没有这些分）。
    private var lightroomBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.circle")
                .font(.system(size: 11))
            Text("\(review.catalogOnlyCount) 张的星级来自 Lightroom 目录")
                .font(.system(size: 11))
                .lineLimit(1)
            Button("写入文件") {
                review.onRequestLightroomSync?()
            }
            .controlSize(.small)
            .help("把 Lightroom 目录里的星级写进文件（RAW 写 .xmp，JPG 写内部元数据），与在 LR 里按 ⌘S 效果一致")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .foregroundStyle(.white.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.65), lineWidth: 1)
        )
    }

    private func starControl(rating: Int?, ratable: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    review.setRating(star)
                } label: {
                    Image(systemName: (rating ?? 0) >= star ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(
                            (rating ?? 0) >= star ? Color.yellow : theme.secondaryText.opacity(ratable ? 0.6 : 0.25)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!ratable)
                .help("打 \(star) 星（数字键 \(star)）")
            }
            if !ratable {
                Text("视频不打分")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Toggle("筛选", isOn: Binding(
                get: { review.session.filter.isActive },
                set: { isOn in
                    var filter = review.session.filter
                    filter.isActive = isOn
                    review.setFilter(filter)
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            Picker("", selection: Binding(
                get: { review.session.filter.comparison },
                set: { comparison in
                    var filter = review.session.filter
                    filter.comparison = comparison
                    review.setFilter(filter)
                }
            )) {
                ForEach(RatingFilter.Comparison.allCases) { comparison in
                    Text(comparison.displayName).tag(comparison)
                }
            }
            .labelsHidden()
            .frame(width: 108)
            .disabled(!review.session.filter.isActive)

            Picker("", selection: Binding(
                get: { review.session.filter.stars },
                set: { stars in
                    var filter = review.session.filter
                    filter.stars = stars
                    review.setFilter(filter)
                }
            )) {
                ForEach(0...5, id: \.self) { star in
                    Text("\(star) 星").tag(star)
                }
            }
            .labelsHidden()
            .frame(width: 76)
            .disabled(!review.session.filter.isActive)

            Text("\(review.totalCount) 张")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.panelBackground)
        )
    }

    // MARK: - 预览区

    private var previewArea: some View {
        GeometryReader { proxy in
            ZStack {
                background.color
                if let group = review.current {
                    if group.isVideo, let player = review.player {
                        VideoPlayerView(player: player) {
                            FullScreenController.toggle()
                        }
                    } else if let preview = review.preview {
                        ZoomableImageView(
                            preview: preview,
                            resetToken: resetToken,
                            command: review.zoomCommand,
                            background: background,
                            onSelectBackground: { option in
                                backgroundRaw = option.rawValue
                            },
                            onZoomChanged: { review.updateZoomProgress($0) }
                        )
                    } else if review.isLoadingPreview {
                        ProgressView().controlSize(.small)
                    } else {
                        emptyPreview
                    }
                } else {
                    emptyPreview
                }

                topOverlays

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            if review.isLoadingFullResolution {
                                badge("正在加载原始分辨率…")
                            }
                            if let status = review.statusMessage {
                                badge(status)
                            }
                        }
                        .padding(12)
                    }
                }
            }
            .clipped()
            .onAppear {
                review.setViewportPixelWidth(proxy.size.width * 2)
            }
            .onChange(of: proxy.size.width) { _, newValue in
                review.setViewportPixelWidth(newValue * 2)
            }
        }
        .id(review.currentID ?? "none")
        .onChange(of: review.currentID) { _, _ in
            resetToken += 1
        }
    }

    /// 预览区上沿的浮层：左边是「星级来自 Lightroom 目录」提示，右边是缩放指示。
    private var topOverlays: some View {
        VStack {
            HStack(alignment: .top, spacing: 10) {
                if review.catalogOnlyCount > 0 {
                    lightroomBadge
                }
                Spacer()
                zoomIndicator
                    .allowsHitTesting(false)
            }
            .padding(10)
            Spacer()
        }
    }

    /// 右上角的缩放指示：放大到 1:1 时明确显示，方便判断是否到了像素级。
    private var zoomIndicator: some View {
        Group {
            if review.zoomProgress >= 0.995 {
                Text("1:1 像素")
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("\(Int((review.zoomProgress * 100).rounded()))%")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .font(.system(size: 11, weight: .medium, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.black.opacity(0.5))
        )
    }

    private var emptyPreview: some View {
        VStack(spacing: 10) {
            Image(systemName: review.session.filter.isActive ? "line.3.horizontal.decrease.circle" : "photo.on.rectangle")
                .font(.system(size: 28))
                .foregroundStyle(theme.secondaryText)
            Text(review.session.filter.isActive ? "没有符合筛选条件的片子" : "这个文件夹里没有可审阅的照片或视频")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            if review.session.filter.isActive {
                Button("清除筛选") { review.setFilter(.inactive) }
                    .controlSize(.small)
            } else if !review.subfolders.isEmpty {
                VStack(spacing: 4) {
                    Text("它有 \(review.subfolders.count) 个子文件夹，点一个进去：")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    ForEach(review.subfolders.prefix(8), id: \.self) { folder in
                        Button {
                            review.openFolder(folder)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                Text(folder.lastPathComponent)
                                    .font(.system(size: 11.5))
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.primaryText)
                    }
                    if review.subfolders.count > 8 {
                        Text("…其余 \(review.subfolders.count - 8) 个见左侧文件夹面板")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
            }
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.55))
            )
            .foregroundStyle(.white.opacity(0.92))
    }
}
