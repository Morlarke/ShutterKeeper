import AppKit
import ShutterKeeperCore
import SwiftUI

/// 左侧文件夹浏览器，操作方式参照访达的分栏视图（Finder column view）。
///
/// 每一列显示「上一列选中文件夹」里的子文件夹；点中某项就在右边展开它的内容，
/// 同时把那个文件夹打开到审阅区。最左边一列最多往回追溯 3 级，再往上用「上一级」按钮。
struct FolderBrowserView: View {
    let currentFolder: URL?
    /// 当前文件夹的子文件夹（已经扫描过就直接用，避免先闪一下空列）。
    let knownSubfolders: [URL]?
    let theme: AppTheme
    let onOpen: (URL) -> Void
    let onClose: () -> Void

    @State private var columns: [URL] = []
    @State private var childrenCache: [String: [URL]] = [:]
    @State private var loading: Set<String> = []
    private let columnWidth: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            divider
            columnsView
        }
        .background(theme.panelBackground.opacity(0.35))
        .onAppear {
            syncColumns(with: currentFolder, force: true)
            seedKnownSubfolders()
        }
        .onChange(of: currentFolder) { _, newValue in
            syncColumns(with: newValue, force: false)
            seedKnownSubfolders()
        }
        .onChange(of: knownSubfolders) { _, _ in
            seedKnownSubfolders()
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.separator).frame(height: 1)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                if let parent = Self.parent(of: currentFolder) {
                    onOpen(parent)
                }
            } label: {
                Image(systemName: "arrow.up")
            }
            .controlSize(.small)
            .help("上一级（⌘⌥↑）")
            .disabled(Self.parent(of: currentFolder) == nil)

            Button {
                if let url = FolderPicker.chooseFolder(message: "选择要审阅的文件夹") {
                    onOpen(url)
                }
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .controlSize(.small)
            .help("打开其它文件夹")

            Spacer()

            Text(currentFolder?.lastPathComponent ?? "未打开文件夹")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.secondaryText)

            Spacer()

            Button {
                onClose()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .controlSize(.small)
            .help("收起文件夹面板（重新打开：顶部条左侧的「文件夹」按钮，或 ⌘⌥B）")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    // MARK: - 分栏

    private var columnsView: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(displayedColumns, id: \.self) { directory in
                        FolderColumn(
                            directory: directory,
                            selectedChild: nextPathElement(after: directory),
                            isCurrentColumn: directory.standardizedFileURL == currentFolder?.standardizedFileURL,
                            theme: theme,
                            width: columnWidth,
                            children: childrenCache[directory.standardizedFileURL.path],
                            onSelect: { child in
                                guard let index = columns.firstIndex(where: {
                                    $0.standardizedFileURL == directory.standardizedFileURL
                                }) else { return }
                                select(child, fromColumn: index)
                            }
                        )
                        .id(directory)
                        .task(id: directory.path) {
                            await loadChildren(of: directory)
                        }

                        Rectangle()
                            .fill(theme.separator)
                            .frame(width: 1)
                    }
                }
            }
            .onChange(of: columns.last) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(newValue, anchor: .trailing)
                }
            }
        }
    }

    // MARK: - 数据

    /// 实际渲染的列：子文件夹为空的列不显示（还没读出来的先留着，读完再决定）。
    private var displayedColumns: [URL] {
        columns.filter { directory in
            guard let children = childrenCache[directory.standardizedFileURL.path] else { return true }
            return !children.isEmpty
        }
    }

    private func nextPathElement(after directory: URL) -> URL? {
        guard let index = columns.firstIndex(where: {
            $0.standardizedFileURL == directory.standardizedFileURL
        }), index + 1 < columns.count else { return nil }
        return columns[index + 1]
    }

    /// 把已经扫描出来的子文件夹塞进缓存，避免当前文件夹的那一列先空一下再填上。
    private func seedKnownSubfolders() {
        guard let currentFolder, let knownSubfolders else { return }
        childrenCache[currentFolder.standardizedFileURL.path] = knownSubfolders
    }

    private func loadChildren(of directory: URL) async {
        let key = directory.standardizedFileURL.path
        if childrenCache[key] != nil || loading.contains(key) { return }
        loading.insert(key)
        let loaded = await Task.detached(priority: .userInitiated) {
            FolderScanner.subfolders(of: directory)
        }.value
        childrenCache[key] = loaded
        loading.remove(key)
    }

    /// 点某一列里的文件夹：截断后面的列，展开新的一列，并把该文件夹打开。
    private func select(_ child: URL, fromColumn index: Int) {
        let ancestors = Array(columns.prefix(index + 1))
        columns = ancestors + [child]
        onOpen(child)
    }

    /// 外部（例如上一级、最近项目）改变了当前文件夹时，重建分栏路径。
    private func syncColumns(with folder: URL?, force: Bool) {
        guard let folder else {
            columns = []
            return
        }
        let target = folder.standardizedFileURL
        if !force {
            // 已经在显示这个文件夹，或者它在当前路径里：保留上下文，只截断
            if columns.last?.standardizedFileURL == target { return }
            if let index = columns.firstIndex(where: { $0.standardizedFileURL == target }) {
                columns = Array(columns.prefix(index + 1))
                return
            }
        }
        columns = Self.ancestorChain(of: folder, limit: 3)
    }

    // MARK: - 路径工具

    static func parent(of url: URL?) -> URL? {
        guard let url else { return nil }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path != url.standardizedFileURL.path else { return nil }
        guard parent.pathComponents.count > 1 else { return nil }
        return parent
    }

    /// 从当前文件夹往上取最多 limit 级祖先（含自己），从最上层开始排列。
    ///
    /// 例如 limit = 3 时返回 [爷爷, 父亲, 自己]。
    static func ancestorChain(of url: URL, limit: Int) -> [URL] {
        var chain: [URL] = []
        var cursor = url.standardizedFileURL
        while chain.count < limit {
            chain.insert(cursor, at: 0)
            guard let parent = parent(of: cursor) else { break }
            cursor = parent
        }
        return chain
    }
}

/// 分栏里的一列。
private struct FolderColumn: View {
    let directory: URL
    /// 下一列里被选中的那一项（用来高亮）。
    let selectedChild: URL?
    let isCurrentColumn: Bool
    let theme: AppTheme
    let width: CGFloat
    /// nil 表示还在读取
    let children: [URL]?
    let onSelect: (URL) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if let children, children.isEmpty {
                    Text("没有子文件夹")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.secondaryText.opacity(0.7))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else if let children {
                    ForEach(children, id: \.self) { child in
                        row(child)
                    }
                } else {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("读取中…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(theme.secondaryText)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: width)
        .background(isCurrentColumn ? theme.panelBackground.opacity(0.35) : Color.clear)
    }

    private func row(_ child: URL) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            Text(child.lastPathComponent)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.secondaryText.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(child.standardizedFileURL == selectedChild?.standardizedFileURL ? Color.accentColor : Color.clear)
        )
        .foregroundStyle(child.standardizedFileURL == selectedChild?.standardizedFileURL ? Color.white : theme.primaryText)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(child) }
        .contextMenu {
            Button("在访达中显示") { FolderPicker.reveal(child) }
        }
    }
}
