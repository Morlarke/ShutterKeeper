import ShutterKeeperCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(PrefKey.background) private var backgroundRaw = AppBackground.neutralGray.rawValue
    @StateObject private var keyboard = KeyboardController()
    private var rename: RenameState { state.rename }

    private var theme: AppTheme { AppTheme.from(backgroundRaw) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(theme.separator)
                .frame(height: 1)
            moduleContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.backgroundColor)
        .environment(\.colorScheme, theme.colorScheme)
        .foregroundStyle(theme.primaryText)
        .frame(minWidth: 1040, minHeight: 660)
        .onAppear { installKeyboard() }
        .onDisappear { keyboard.stop() }
        .onChange(of: state.selectedTab) { _, newValue in
            // 切到审阅时，默认看改名模块正在处理的那个文件夹
            if newValue == .review {
                state.syncReviewToRenameFolder()
            }
        }
        .alert(
            "从 Lightroom 目录同步星级",
            isPresented: Binding(
                get: { state.lightroomRequest != nil },
                set: { if !$0 { state.lightroomRequest = nil } }
            ),
            presenting: state.lightroomRequest
        ) { _ in
            Button("写入文件", role: .destructive) { state.confirmLightroomSync() }
            Button("取消", role: .cancel) { state.cancelLightroomSync() }
        } message: { request in
            Text(Self.lightroomMessage(request))
        }
    }

    private static func lightroomMessage(_ request: AppState.LightroomSyncRequest) -> String {
        let plan = request.plan
        var lines: [String] = []
        lines.append("目录文件：\(request.catalogURL.lastPathComponent)")
        lines.append("这个文件夹共 \(plan.total) 张片子。")
        lines.append("需要写入：\(plan.updates.count) 张")
        lines.append("已一致：\(plan.alreadyMatching) 张；目录里没打分的：\(plan.notInCatalog) 张（跳过，不会清零）")
        lines.append("")
        lines.append("RAW 写同名 .xmp 附属文件，JPG 写文件内部元数据（不改像素）。已有 .xmp 的话只更新星级，其余内容保留。")
        return lines.joined(separator: "\n")
    }

    private func installKeyboard() {
        keyboard.onNextModule = { state.selectNextModule() }
        keyboard.onPreviousModule = { state.selectPreviousModule() }
        keyboard.contextProvider = {
            guard state.selectedTab == .review, state.review?.currentIsVideo == true else { return .photo }
            return .video
        }
        keyboard.onAction = { action in
            switch state.selectedTab {
            case .review:
                guard let review = state.review else { return false }
                return review.handle(action)
            case .rename:
                return rename.handle(action)
            case .importTab:
                return false
            }
        }
        keyboard.onEscape = {
            // 先让当前模块清掉多选，再考虑退出全屏
            if state.selectedTab == .review, state.review?.clearSelectionIfNeeded() == true {
                return true
            }
            if state.selectedTab == .rename, state.rename.clearSelectionIfNeeded() {
                return true
            }
            if FullScreenController.isFullScreen {
                FullScreenController.exit()
                return true
            }
            return false
        }
        keyboard.start()
    }

    // MARK: - 顶部

    private var header: some View {
        ZStack {
            // 三个模块标签居中
            tabPicker

            HStack(spacing: 8) {
                Spacer()
                if let folder = state.currentFolder {
                    Text(folder.lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 260, alignment: .trailing)
                    Button {
                        state.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isScanning)
                    .help("重新扫描当前文件夹（⌘R）")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(theme.colorScheme == .dark ? Color(white: 1).opacity(0.03) : Color(white: 1).opacity(0.55))
    }

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = state.selectedTab == tab
                Button {
                    state.selectedTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .medium))
                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? accentFill : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color.white : theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("\(tab.title)（⌘⌥\(AppTab.allCases.firstIndex(of: tab).map { $0 + 1 } ?? 1)）")
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.panelBackground)
        )
    }

    private var accentFill: Color {
        Color.accentColor.opacity(theme.colorScheme == .dark ? 0.85 : 0.95)
    }

    @ViewBuilder
    private var moduleContent: some View {
        switch state.selectedTab {
        case .importTab:
            ImportView(importer: state.importer, theme: theme)
        case .rename:
            RenameView(rename: rename, theme: theme)
        case .review:
            if let review = state.review {
                ReviewView(review: review, theme: theme)
            } else if state.isScanning {
                scanningPlaceholder
            } else {
                StartView(theme: theme)
            }
        }
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在读取文件夹…")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
