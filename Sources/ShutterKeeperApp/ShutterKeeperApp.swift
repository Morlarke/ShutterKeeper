import ShutterKeeperCore
import SwiftUI

@main
struct ShutterKeeperDesktopApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .sidebar) {
                ForEach(Array(AppTab.allCases.enumerated()), id: \.element) { index, tab in
                    Button(tab.title) { state.selectedTab = tab }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                }
                Divider()
                Button("下一个模块") { state.selectNextModule() }
                    .keyboardShortcut("\\", modifiers: .command)
                Button("上一个模块") { state.selectPreviousModule() }
                    .keyboardShortcut("\\", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("撤销上一次改名") { state.undoLastRename() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!state.canUndoRename)
            }
            CommandMenu("审阅") {
                Button("重新扫描当前文件夹") { state.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(state.currentFolder == nil)
                Divider()
                if let review = state.review {
                    Button(review.folderPanelVisible ? "收起文件夹面板" : "展开文件夹面板") {
                        review.folderPanelVisible.toggle()
                    }
                    Divider()
                    Button(review.exifPanelVisible ? "隐藏 EXIF 面板" : "显示 EXIF 面板") {
                        review.exifPanelVisible.toggle()
                    }
                    Button(review.panelsVisible ? "隐藏胶片条" : "显示胶片条") {
                        review.panelsVisible.toggle()
                    }
                    Divider()
                    Button("清除星级筛选") { review.setFilter(.inactive) }
                        .disabled(!review.session.filter.isActive)
                    Divider()
                    Button("向右旋转 90°") { review.rotate(clockwise: true) }
                        .disabled(review.actionTargets.isEmpty)
                    Button("向左旋转 90°") { review.rotate(clockwise: false) }
                        .disabled(review.actionTargets.isEmpty)
                    Button("在访达中显示") { review.revealSelection() }
                    Button("文件简介") { review.showInfoForSelection() }
                    Divider()
                    Button("全选") { review.selectAllVisible() }
                        .disabled(review.visibleGroups.isEmpty)
                    Button("取消选择") { review.clearSelection() }
                        .disabled(review.selectionCount == 0)
                    Divider()
                    Button("适应窗口") { review.applyZoom(.fit) }
                    Button("1:1 像素") { review.applyZoom(.actualSize) }
                    Button("放大") { review.applyZoom(.zoomIn) }
                    Button("缩小") { review.applyZoom(.zoomOut) }
                    Divider()
                    Button("删除当前（移入废纸篓）") { review.requestDelete() }
                        .disabled(review.current == nil)
                    Divider()
                    Button("从 Lightroom 目录导入星级…") { state.prepareLightroomSync() }
                        .disabled(state.isLightroomSyncing)
                    Button("选择 Lightroom 目录文件…") { state.chooseLightroomCatalog() }
                        .disabled(state.isLightroomSyncing)
                }
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(state)
        }
    }
}
