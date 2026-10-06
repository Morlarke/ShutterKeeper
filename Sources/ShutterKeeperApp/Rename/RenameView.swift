import ShutterKeeperCore
import SwiftUI

/// 批量改名模块。
///
/// 浏览区就是访达式的图标 / 分栏视图；改名的参数放在弹窗里：
/// **选中文件 → 点「批量改名…」→ 在弹窗里选格式 → 确认**。
/// 不选任何文件时，弹窗默认处理整个文件夹。
struct RenameView: View {
    @ObservedObject var rename: RenameState
    let theme: AppTheme

    @EnvironmentObject private var state: AppState
    @AppStorage(PrefKey.dateFormat) private var dateFormatRaw = DateFormatOption.compact.rawValue
    @AppStorage(PrefKey.sequenceDigits) private var sequenceDigits = 3

    @State private var showingSheet = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            separator
            if rename.folder == nil {
                emptyState
            } else {
                RenameBrowserView(rename: rename, cache: state.thumbnailCache, theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                separator
                actionBar
            }
        }
        .onAppear {
            rename.updateSettings {
                $0.dateFormat = dateFormatRaw
                $0.sequenceDigits = sequenceDigits
            }
            rename.openDefaultFolderIfNeeded(lastUsed: state.defaultRenameFolder)
        }
        .sheet(isPresented: $showingSheet) {
            RenameSheet(rename: rename, theme: theme, dateFormat: $dateFormatRaw, sequenceDigits: $sequenceDigits) {
                showingSheet = false
                rename.apply()
            }
        }
        .alert(
            "有 \(rename.pendingConflicts.count) 个目标文件名已存在",
            isPresented: Binding(
                get: { !rename.pendingConflicts.isEmpty },
                set: { if !$0 { rename.cancelConflicts() } }
            )
        ) {
            Button("跳过冲突项") { rename.applySkippingConflicts() }
            Button("覆盖（旧文件进废纸篓）", role: .destructive) { rename.applyReplacingConflicts() }
            Button("取消", role: .cancel) { rename.cancelConflicts() }
        } message: {
            Text(conflictMessage)
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { rename.errorMessage != nil },
                set: { if !$0 { rename.errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { rename.errorMessage = nil }
        } message: {
            Text(rename.errorMessage ?? "")
        }
        .alert(
            rename.pendingDelete.count > 1 ? "删除选中的 \(rename.pendingDelete.count) 张？" : "删除这一张？",
            isPresented: Binding(
                get: { !rename.pendingDelete.isEmpty },
                set: { if !$0 { rename.cancelDelete() } }
            ),
            presenting: rename.pendingDelete
        ) { _ in
            Button("移入废纸篓", role: .destructive) { rename.confirmDelete() }
            Button("取消", role: .cancel) { rename.cancelDelete() }
        } message: { groups in
            let fileCount = groups.reduce(0) { $0 + $1.deletionTargets.count }
            let names = groups.prefix(6).map(\.displayName).joined(separator: "、")
            Text("将把这 \(groups.count) 张片子的 \(fileCount) 个文件移入废纸篓（配对成员和 .xmp 附属文件一起）。\n\n\(names)")
        }
    }

    private var separator: some View {
        Rectangle().fill(theme.separator).frame(height: 1)
    }

    private var conflictMessage: String {
        let names = rename.pendingConflicts.prefix(6).map { $0.target.lastPathComponent }
        var lines = ["例如：" + names.joined(separator: "、")]
        if rename.pendingConflicts.count > names.count {
            lines.append("…等共 \(rename.pendingConflicts.count) 个")
        }
        lines.append("")
        lines.append("「跳过冲突项」只改其余文件；「覆盖」会把已存在的文件先移入废纸篓再改名。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 顶部功能条

    private var toolbar: some View {
        ZStack {
            // 视图切换放在正中间
            viewModePicker

            HStack(spacing: 10) {
                Button {
                    if let parent = FolderBrowserView.parent(of: rename.folder) {
                        rename.open(folder: parent)
                    }
                } label: {
                    Image(systemName: "chevron.up")
                }
                .controlSize(.small)
                .help("上一级（⌥⌘↑）")
                .disabled(FolderBrowserView.parent(of: rename.folder) == nil)

                Button {
                    rename.chooseFolder()
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .help("打开其它文件夹")

                if let folder = rename.folder {
                    Text(folder.lastPathComponent)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(folder.deletingLastPathComponent().path)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .frame(maxWidth: 220, alignment: .leading)

                    Button {
                        rename.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("重新扫描")
                }

                Spacer()

                if rename.isScanning {
                    ProgressView().controlSize(.small)
                }
                if let status = rename.statusMessage, !rename.isWorking {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .frame(maxWidth: 260, alignment: .trailing)
                }

                // 改名按钮放在原来视图按钮的位置（右上角）
                Button {
                    rename.rebuildPlan()
                    showingSheet = true
                } label: {
                    Label("批量改名…", systemImage: "pencil")
                }
                .controlSize(.large)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!rename.canOpenSheet)
                .help("改名设置与预览（⌘⇧R）")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var viewModePicker: some View {
        Picker("", selection: $rename.viewMode) {
            ForEach(RenameViewMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 210)
        .help("⌘1 图标视图 / ⌘2 分栏视图")
    }

    // MARK: - 底部动作条

    private var actionBar: some View {
        HStack(spacing: 12) {
            if rename.isRenamingSubset {
                Label("已选 \(rename.selection.count) 张", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Button("取消选择") { _ = rename.clearSelectionIfNeeded() }
                    .controlSize(.small)
            } else {
                Text("共 \(rename.groups.count) 张 · 不选则整个文件夹都改")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
            }

            Spacer()

            if rename.isWorking {
                ProgressView().controlSize(.small)
            }

            if rename.canUndo {
                Button("撤销") { rename.undoLastRename() }
                    .controlSize(.large)
                    .help("撤销上一次改名（⌘Z）")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil")
                .font(.system(size: 30))
                .foregroundStyle(theme.secondaryText)
            Text("先选一个文件夹")
                .font(.system(size: 14, weight: .medium))
            Text("选中要改名的文件，点右下角「批量改名…」；不选就处理整个文件夹。")
                .font(.system(size: 12))
                .foregroundStyle(theme.secondaryText)
            Button("打开文件夹…") { rename.chooseFolder() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 改名设置弹窗

struct RenameSheet: View {
    @ObservedObject var rename: RenameState
    let theme: AppTheme
    @Binding var dateFormat: String
    @Binding var sequenceDigits: Int
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pencil")
                    .font(.system(size: 15, weight: .semibold))
                Text("批量改名")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(rename.isRenamingSubset ? "处理选中的 \(rename.selection.count) 张" : "处理整个文件夹（\(rename.groups.count) 张）")
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.secondaryText)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            Form {
                Section("命名格式") {
                    Picker("日期来源", selection: $rename.dateSource) {
                        ForEach(RenameDateSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }

                    if rename.dateSource == .custom {
                        TextField("自定义日期文本（例如 202608）", text: $rename.customDateText)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("日期格式", selection: $dateFormat) {
                            ForEach(DateFormatOption.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        }
                        .onChange(of: dateFormat) { _, newValue in
                            rename.updateSettings { $0.dateFormat = newValue }
                        }
                    }

                    Picker("序列号位数", selection: $sequenceDigits) {
                        ForEach(1...6, id: \.self) { digits in
                            Text("\(digits) 位").tag(digits)
                        }
                    }
                    .onChange(of: sequenceDigits) { _, newValue in
                        rename.updateSettings { $0.sequenceDigits = newValue }
                    }

                    LabeledContent("模板示例") {
                        Text(rename.example ?? "—")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Section("自定义文本（可多段）") {
                    HStack(spacing: 8) {
                        ForEach(0..<rename.segmentCount, id: \.self) { index in
                            TextField("文本\(index + 1)", text: Binding(
                                get: { index < rename.bulkSegments.count ? rename.bulkSegments[index] : "" },
                                set: { newValue in
                                    while rename.bulkSegments.count <= index {
                                        rename.bulkSegments.append("")
                                    }
                                    rename.bulkSegments[index] = newValue
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                        Button {
                            rename.addSegment()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("增加一段（例如 婚礼_新娘_精修）")
                        .disabled(rename.segmentCount >= 4)
                        Button {
                            rename.removeSegment()
                        } label: {
                            Image(systemName: "minus")
                        }
                        .disabled(rename.segmentCount <= 1)
                        Button("应用到全部") { rename.applyBulkSegments() }
                            .disabled(rename.buckets.isEmpty)
                    }
                }

                Section("按拍摄日期分组（每组一行，可分别填写）") {
                    if rename.buckets.isEmpty {
                        Text("这个文件夹里没有可改名的素材")
                            .foregroundStyle(theme.secondaryText)
                    } else {
                        ForEach(rename.buckets) { bucket in
                            bucketRow(bucket)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 12) {
                if rename.pendingOperations.isEmpty {
                    Label("当前设置下没有文件需要改名（文件名已经符合模板），改一下自定义文本或日期来源再试", systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                } else {
                    Text("共 \(rename.pendingFileCount) 个文件要改名")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("开始改名") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rename.pendingOperations.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .frame(width: 640, height: 560)
    }

    private func bucketRow(_ bucket: RenameGroupPlan) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bucket.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text("\(bucket.count) 张 · \(bucket.familyLabel)")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
            }
            .frame(width: 200, alignment: .leading)

            ForEach(0..<rename.segmentCount, id: \.self) { index in
                TextField("文本\(index + 1)", text: Binding(
                    get: {
                        let values = rename.segments(for: bucket.id)
                        return index < values.count ? values[index] : ""
                    },
                    set: { rename.setSegment(index, value: $0, for: bucket.id) }
                ))
                .textFieldStyle(.roundedBorder)
            }
            Spacer(minLength: 0)
        }
    }
}
