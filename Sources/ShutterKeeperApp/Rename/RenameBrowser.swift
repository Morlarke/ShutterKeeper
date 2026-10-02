import AppKit
import ShutterKeeperCore
import SwiftUI

/// 改名模块的浏览区，两种视图都直接作用在「当前文件夹」上。
///
/// * ⌘2 分栏视图（默认）：访达列视图，↑↓ 在当前列移动、→ 进入文件夹、← 回到上一级
/// * ⌘1 图标视图：文件夹 + 所有素材（RAW / JPG / HEIC / 视频 / .xmp）的缩略图网格
struct RenameBrowserView: View {
    @ObservedObject var rename: RenameState
    let cache: ThumbnailCache?
    let theme: AppTheme

    var body: some View {
        switch rename.viewMode {
        case .icons:
            RenameIconBrowser(rename: rename, cache: cache, theme: theme)
        case .columns:
            RenameColumnBrowser(rename: rename, theme: theme)
        }
    }
}

// MARK: - 图标视图

private struct RenameIconBrowser: View {
    @ObservedObject var rename: RenameState
    let cache: ThumbnailCache?
    let theme: AppTheme

    @State private var subfolders: [URL] = []

    private let columns = [GridItem(.adaptive(minimum: 128, maximum: 176), spacing: 14)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(subfolders, id: \.self) { folder in
                    RenameFolderCell(url: folder, theme: theme) {
                        rename.open(folder: folder)
                    }
                }
                ForEach(rename.currentPlan.files) { file in
                    RenameFileCell(file: file, cache: cache, theme: theme)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: rename.folder) {
            guard let folder = rename.folder else {
                subfolders = []
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                FolderScanner.subfolders(of: folder)
            }.value
            subfolders = loaded
        }
    }
}

private struct RenameFolderCell: View {
    let url: URL
    let theme: AppTheme
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                    .frame(height: 108)
                Text(url.lastPathComponent)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(theme.primaryText)
            }
        }
        .buttonStyle(.plain)
        .help("进入 \(url.lastPathComponent)")
    }
}

private struct RenameFileCell: View {
    let file: RenameFilePreview
    let cache: ThumbnailCache?
    let theme: AppTheme

    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.25))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: fallbackSymbol)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .frame(height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1)
            )

            Text(file.originalName)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.primaryText)

            if file.willChange {
                Text(file.newName)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("名字不变")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText.opacity(0.8))
            }
        }
        .help(file.willChange ? "\(file.originalName) → \(file.newName)" : file.originalName)
        .task(id: file.id) {
            guard image == nil, !file.isSidecar, file.kind != .video, let cache else { return }
            let ref = FileRef(url: file.originalURL, kind: file.kind)
            image = await cache.thumbnail(for: ref, maxPixel: 300)
        }
    }

    private var fallbackSymbol: String {
        if file.isSidecar { return "doc.text" }
        switch file.kind {
        case .video: return "film"
        case .proprietaryRAW, .dng: return "camera.aperture"
        default: return "photo"
        }
    }
}

// MARK: - 分栏视图

private struct RenameColumnBrowser: View {
    @ObservedObject var rename: RenameState
    let theme: AppTheme

    private let columnWidth: CGFloat = 200

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(rename.columns, id: \.self) { directory in
                        column(for: directory)
                        Rectangle().fill(theme.separator).frame(width: 1)
                    }
                }
            }
            .onChange(of: rename.columns.last) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .trailing)
                }
            }
            .onChange(of: rename.highlightedIndex) { _, newValue in
                guard let folder = rename.folder else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("\(folder.path)#\(newValue)", anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func column(for directory: URL) -> some View {
        let isCurrent = directory.standardizedFileURL == rename.folder?.standardizedFileURL
        RenameColumn(
            directory: directory,
            rows: rename.rows(for: directory),
            loaded: rename.isColumnLoaded(directory),
            isCurrent: isCurrent,
            highlightedIndex: isCurrent ? rename.highlightedIndex : nil,
            selectedFolderURL: nextPathElement(after: directory),
            theme: theme,
            width: columnWidth,
            onSelectFolder: { url, index in
                rename.selectFolder(url, rowIndex: index, isCurrentColumn: isCurrent)
            },
            onSelectFile: { index in
                rename.highlightedIndex = index
            }
        )
        .id(directory)
        .task(id: directory.path) {
            await rename.loadColumn(directory)
        }
    }

    private func nextPathElement(after directory: URL) -> URL? {
        guard let index = rename.columns.firstIndex(where: {
            $0.standardizedFileURL == directory.standardizedFileURL
        }), index + 1 < rename.columns.count else { return nil }
        return rename.columns[index + 1]
    }
}

private struct RenameColumn: View {
    let directory: URL
    let rows: [RenameBrowserRow]
    let loaded: Bool
    let isCurrent: Bool
    let highlightedIndex: Int?
    let selectedFolderURL: URL?
    let theme: AppTheme
    let width: CGFloat
    let onSelectFolder: (URL, Int) -> Void
    let onSelectFile: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if !loaded {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("读取中…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                } else if rows.isEmpty {
                    Text("没有子文件夹")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        rowView(row, index: index)
                            .id("\(directory.path)#\(index)")
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .background(isCurrent ? theme.panelBackground.opacity(0.3) : Color.clear)
    }

    @ViewBuilder
    private func rowView(_ row: RenameBrowserRow, index: Int) -> some View {
        switch row {
        case .folder(let url):
            folderRow(url, index: index)
        case .file(let file):
            fileRow(file, index: index)
        }
    }

    private func folderRow(_ folder: URL, index: Int) -> some View {
        let selected = isCurrent
            ? highlightedIndex == index
            : folder.standardizedFileURL == selectedFolderURL?.standardizedFileURL
        return HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.white : Color.accentColor.opacity(0.9))
            Text(folder.lastPathComponent)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(selected ? Color.white.opacity(0.8) : theme.secondaryText.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(selected ? Color.white : theme.primaryText)
        .contentShape(Rectangle())
        .onTapGesture { onSelectFolder(folder, index) }
    }

    private func fileRow(_ file: RenameFilePreview, index: Int) -> some View {
        let selected = highlightedIndex == index
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Image(systemName: symbol(for: file))
                    .font(.system(size: 10))
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : theme.secondaryText)
                Text(file.originalName)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if file.willChange {
                Text(file.newName)
                    .font(.system(size: 9.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(selected ? Color.white.opacity(0.9) : Color.accentColor)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.7) : Color.clear)
        )
        .foregroundStyle(selected ? Color.white : theme.primaryText)
        .contentShape(Rectangle())
        .onTapGesture { onSelectFile(index) }
    }

    private func symbol(for file: RenameFilePreview) -> String {
        if file.isSidecar { return "doc.text" }
        switch file.kind {
        case .video: return "film"
        case .proprietaryRAW, .dng: return "camera.aperture"
        case .heic, .jpeg, .tiff, .png, .otherImage: return "photo"
        case .psd: return "doc.richtext"
        default: return "doc"
        }
    }
}
