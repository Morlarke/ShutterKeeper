import ShutterKeeperCore
import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(PrefKey.background) private var backgroundRaw = AppBackground.neutralGray.rawValue
    @AppStorage(PrefKey.dateFormat) private var dateFormat = DateFormatOption.compact.rawValue
    @AppStorage(PrefKey.backupPath) private var backupPath = ""
    @AppStorage(PrefKey.copyToBackup) private var copyToBackup = false
    @AppStorage(PrefKey.exifPanelVisible) private var exifPanelVisible = true
    @AppStorage(PrefKey.exifFields) private var exifFieldsRaw = ExifField.encode(Set(ExifField.defaultSelection))
    @AppStorage(PrefKey.cacheLocation) private var cacheLocationOverride = ""
    @AppStorage(PrefKey.readLightroomRatings) private var readLightroomRatings = true

    @State private var showClearDatabaseConfirm = false
    @State private var shortcutStore = ShortcutStore.shared
    @State private var shortcutRevision = 0
    @State private var recordingAction: ShortcutAction?
    @State private var recordingMonitor: Any?
    @State private var pendingConflict: PendingShortcutConflict?

    private var theme: AppTheme { AppTheme.from(backgroundRaw) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                appearanceSection
                dateFormatSection
                lightroomSection
                importSection
                exifSection
                storageSection
                shortcutSection
                aboutSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 600)
        .background(theme.backgroundColor)
        .environment(\.colorScheme, theme.colorScheme)
        .foregroundStyle(theme.primaryText)
    }

    // MARK: - 外观

    private var appearanceSection: some View {
        section("外观") {
            Picker("背景色", selection: $backgroundRaw) {
                ForEach(AppBackground.allCases) { background in
                    Text(background.displayName).tag(background.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text("默认深色。控件明暗会跟着背景亮度走，白底不会配深色控件。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var dateFormatSection: some View {
        section("日期格式") {
            Picker("默认格式", selection: $dateFormat) {
                ForEach(DateFormatOption.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            Text("导入建文件夹与批量改名共用这一项。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var importSection: some View {
        section("导入与备份") {
            Toggle("导入时同时复制到另一个位置", isOn: $copyToBackup)
            HStack(spacing: 8) {
                TextField("默认备份路径", text: $backupPath)
                    .textFieldStyle(.roundedBorder)
                Button("选择…") {
                    if let url = FolderPicker.chooseFolder(message: "选择默认备份位置") {
                        backupPath = url.path
                    }
                }
                .controlSize(.small)
                Button("清除") { backupPath = "" }
                    .controlSize(.small)
                    .disabled(backupPath.isEmpty)
            }
            Text("备份目录结构与主导入完全一致；备份中途目标盘断开或空间不足会停下报错。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - Lightroom

    private var lightroomSection: some View {
        section("Lightroom 协作") {
            Toggle("自动读取 Lightroom 目录里的星级", isOn: $readLightroomRatings)
                .onChange(of: readLightroomRatings) { _, _ in
                    state.review?.refreshRatingsFromFiles()
                }
            Text("Lightroom Classic 默认**不**把星级写进文件，分只存在它的目录数据库里。打开这一项后，审阅界面会直接读目录（只读，不修改 LR 的任何文件），显示你在 LR 里打的分。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)

            labeledPath("正在使用的目录文件", state.lightroomCatalogPath ?? "未找到")

            HStack(spacing: 8) {
                Button("选择目录文件…") { state.chooseLightroomCatalog() }
                    .controlSize(.small)
                Button("重新检测") {
                    Task {
                        await LightroomRatingProvider.shared.invalidateCache()
                        state.refreshLightroomCatalogPath()
                        state.review?.refreshRatingsFromFiles()
                    }
                }
                .controlSize(.small)
            }

            Text("要把星级真正写进文件（RAW 写 .xmp、JPG 写内部元数据，和 LR 里按 ⌘S 一样），用审阅菜单的「从 Lightroom 目录导入星级」。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
    }

    // MARK: - EXIF

    private var exifSection: some View {
        section("EXIF 面板") {
            Toggle("默认显示（审阅时按 P 切换）", isOn: $exifPanelVisible)
            VStack(alignment: .leading, spacing: 6) {
                Text("显示项")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                ForEach(ExifField.allCases) { field in
                    Toggle(field.displayName, isOn: binding(for: field))
                        .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func binding(for field: ExifField) -> Binding<Bool> {
        Binding(
            get: { ExifField.decode(exifFieldsRaw).contains(field) },
            set: { isOn in
                var fields = ExifField.decode(exifFieldsRaw)
                if isOn { fields.insert(field) } else { fields.remove(field) }
                exifFieldsRaw = ExifField.encode(fields)
            }
        )
    }

    // MARK: - 存储

    private var storageSection: some View {
        section("存储与缓存") {
            labeledPath("评分数据库", state.paths.databaseURL.path)
            labeledPath("缩略图缓存", effectiveCachePath)

            HStack(spacing: 8) {
                Button("改用其他缓存位置…") {
                    if let url = FolderPicker.chooseFolder(message: "选择缓存位置") {
                        cacheLocationOverride = url.path
                    }
                }
                .controlSize(.small)
                Button("恢复默认位置") { cacheLocationOverride = "" }
                    .controlSize(.small)
                    .disabled(cacheLocationOverride.isEmpty)
            }
            HStack(spacing: 8) {
                Button("清空缩略图缓存") { state.clearThumbnailCache() }
                    .controlSize(.small)
                Button("清空评分数据库") { showClearDatabaseConfirm = true }
                    .controlSize(.small)
            }
            Text("两者互相独立：缓存删掉只是下次重新生成；数据库删掉后，软件自己的记录没了，但文件里的星级仍在，重新打开文件夹可以从 .xmp 与 JPG 内部元数据恢复。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
        }
        .confirmationDialog(
            "确定清空评分数据库？",
            isPresented: $showClearDatabaseConfirm,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { state.clearRatingDatabase() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会清空软件自己的记录。照片和视频文件里的星级不受影响。")
        }
    }

    private var effectiveCachePath: String {
        cacheLocationOverride.isEmpty ? state.paths.thumbnailDirectory.path : cacheLocationOverride
    }

    private func labeledPath(_ label: String, _ path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    // MARK: - 快捷键

    private var shortcutSection: some View {
        section("快捷键") {
            Text("点「更改」后按下新的组合键。与已有快捷键冲突时会问你覆盖还是取消；按 Esc 放弃。正在输入文字时单键快捷键自动让行。")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ShortcutAction.allCases, id: \.self) { action in
                    HStack {
                        Text(action.displayName)
                            .font(.system(size: 12))
                            .frame(width: 170, alignment: .leading)
                        Spacer()
                        Text(recordingAction == action ? "请按下新快捷键…" : shortcutStore.shortcut(for: action).displayString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(recordingAction == action ? Color.accentColor : theme.secondaryText)
                        Button(recordingAction == action ? "取消" : "更改") {
                            if recordingAction == action {
                                stopRecording()
                            } else {
                                startRecording(action)
                            }
                        }
                        .controlSize(.mini)
                        Button("默认") {
                            shortcutStore.reset(action)
                            shortcutRevision += 1
                        }
                        .controlSize(.mini)
                        .disabled(!shortcutStore.isCustomized(action))
                    }
                }
            }
            HStack {
                Text("共 \(ShortcutAction.allCases.count) 项，\(shortcutStore.customizedActions.count) 项已自定义")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Spacer()
                Button("全部恢复默认") {
                    shortcutStore.resetAll()
                    shortcutRevision += 1
                }
                .controlSize(.small)
                .disabled(shortcutStore.customizedActions.isEmpty)
            }
        }
        .id(shortcutRevision)
        .alert(
            "快捷键冲突",
            isPresented: Binding(
                get: { pendingConflict != nil },
                set: { if !$0 { pendingConflict = nil } }
            ),
            presenting: pendingConflict
        ) { conflict in
            Button("覆盖", role: .destructive) {
                try? shortcutStore.set(conflict.shortcut, for: conflict.action, force: true)
                shortcutRevision += 1
                pendingConflict = nil
            }
            Button("取消", role: .cancel) { pendingConflict = nil }
        } message: { conflict in
            Text("\(conflict.shortcut.displayString) 已经被「\(conflict.existing.displayName)」使用。要覆盖它吗？")
        }
    }

    private struct PendingShortcutConflict {
        let action: ShortcutAction
        let shortcut: KeyShortcut
        let existing: ShortcutAction
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // Esc 放弃
                stopRecording()
                return nil
            }
            let candidate = KeyShortcut(
                keyCode: event.keyCode,
                modifiers: ShortcutModifiers(event.modifierFlags)
            )
            apply(candidate, to: action)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        recordingMonitor = nil
        recordingAction = nil
    }

    private func apply(_ candidate: KeyShortcut, to action: ShortcutAction) {
        if let conflict = shortcutStore.conflict(for: candidate, excluding: action) {
            pendingConflict = PendingShortcutConflict(action: action, shortcut: candidate, existing: conflict.action)
            return
        }
        try? shortcutStore.set(candidate, for: action, force: true)
        shortcutRevision += 1
    }

    // MARK: - 布局辅助

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(theme.secondaryText)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.panelBackground)
        )
    }

    // MARK: - 关于

    private var aboutSection: some View {
        section("关于") {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("快门闪选")
                            .font(.system(size: 13, weight: .semibold))
                        Text(AppInfo.version)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.panelBackground))
                            .foregroundStyle(theme.secondaryText)
                    }
                    Text("ShutterKeeper — 摄影工作流的导入 / 改名 / 审阅")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    Text("作者：\(AppInfo.author)")
                        .font(.system(size: 11.5))
                    HStack(spacing: 4) {
                        Text("联系：")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                        Link(AppInfo.contact, destination: URL(string: "mailto:\(AppInfo.contact)")!)
                            .font(.system(size: 11.5))
                    }
                }
                Spacer()
            }
        }
    }
}

/// 从 bundle 里读版本与作者信息（用 `swift run` 直接跑时给出兜底值）。
enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "beta-0.11"
    }

    static var author: String {
        Bundle.main.infoDictionary?["SKAuthor"] as? String ?? "快门镖局-陈师"
    }

    static var contact: String {
        Bundle.main.infoDictionary?["SKContact"] as? String ?? "thechengsir@foxmail.com"
    }
}
