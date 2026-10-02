import ShutterKeeperCore
import SwiftUI

// MARK: - 通用外观

struct SectionTitle: View {
    let text: String
    let theme: AppTheme

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.secondaryText)
    }
}

// MARK: - 启动 / 最近项目

struct StartView: View {
    @EnvironmentObject private var state: AppState
    let theme: AppTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionTitle(text: "最近打开", theme: theme)
                Spacer()
                Button("打开文件夹…") { state.chooseFolder() }
                    .controlSize(.small)
            }

            if state.recentFolders.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.recentFolders) { folder in
                            recentRow(folder)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有打开过文件夹")
                .font(.system(size: 14, weight: .medium))
            Text("点右上角「打开文件夹…」，选择 SD 卡或硬盘上的照片目录。\n导入、改名、审阅三个模块互相独立，随时可以单独使用。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.panelBackground)
        )
    }

    private func recentRow(_ folder: RecentFolder) -> some View {
        Button {
            state.open(folder: folder.url)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .foregroundStyle(theme.secondaryText)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Text(folder.path)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(Self.relativeFormatter.localizedString(for: folder.lastOpened, relativeTo: Date()))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.panelBackground)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("从列表移除") { state.forget(folder: folder) }
            Button("在访达中显示") { FolderPicker.reveal(folder.url) }
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()
}
