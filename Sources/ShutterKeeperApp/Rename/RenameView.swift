import ShutterKeeperCore
import SwiftUI

/// 批量改名模块。
///
/// 从上到下三层：功能条 → 改名控制区（示例、统一填写、每组文本、开始改名）→ 素材浏览区。
/// 浏览区用访达的视图模式：**⌘2 分栏视图**（默认）和 **⌘1 图标视图**，
/// 两种视图都直接作用在当前文件夹上，不再单开一栏文件夹列表。
struct RenameView: View {
    @ObservedObject var rename: RenameState
    let theme: AppTheme

    @EnvironmentObject private var state: AppState
    @AppStorage(PrefKey.dateFormat) private var dateFormatRaw = DateFormatOption.compact.rawValue
    @AppStorage(PrefKey.sequenceDigits) private var sequenceDigits = 3
    @FocusState private var focusedField: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            separator
            if rename.folder == nil {
                emptyState
            } else {
                controlBand
                separator
                RenameBrowserView(rename: rename, cache: state.thumbnailCache, theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // 点浏览区就结束文字输入，方向键才会回到「切换文件夹」上
                    .simultaneousGesture(
                        TapGesture().onEnded { focusedField = nil }
                    )
            }
        }
        .onAppear {
            rename.updateSettings {
                $0.dateFormat = dateFormatRaw
                $0.sequenceDigits = sequenceDigits
            }
            rename.openDefaultFolderIfNeeded(lastUsed: state.defaultRenameFolder)
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

    // MARK: - 功能条

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                if let parent = FolderBrowserView.parent(of: rename.folder) {
                    rename.open(folder: parent)
                }
            } label: {
                Image(systemName: "arrow.up")
            }
            .controlSize(.small)
            .help("上一级（⌥⌘↑）")
            .disabled(FolderBrowserView.parent(of: rename.folder) == nil)

            Button {
                rename.chooseFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .controlSize(.small)
            .help("打开其它文件夹")

            if let folder = rename.folder {
                Text(folder.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(folder.deletingLastPathComponent().path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 240, alignment: .leading)
                Button {
                    rename.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("重新扫描")
            }

            Spacer()

            viewModePicker

            if rename.isWorking || rename.isScanning {
                ProgressView().controlSize(.small)
            }
            if let status = rename.statusMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var viewModePicker: some View {
        HStack(spacing: 4) {
            ForEach(RenameViewMode.allCases) { mode in
                let isSelected = rename.viewMode == mode
                Button {
                    rename.viewMode = mode
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11))
                        Text(mode.title)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.accentColor.opacity(0.85) : Color.clear)
                    )
                    .foregroundStyle(isSelected ? Color.white : theme.secondaryText)
                }
                .buttonStyle(.plain)
                .help("\(mode.title)（\(mode == .icons ? "⌘1" : "⌘2")）")
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.panelBackground)
        )
        .fixedSize()
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil")
                .font(.system(size: 28))
                .foregroundStyle(theme.secondaryText)
            Text("先选一个文件夹")
                .font(.system(size: 13, weight: .medium))
            Text("模板：日期_自定义文本_序列号，例如 20260927_婚礼_001.CR3\n按拍摄日期分组，同组共用一个文本；RAW + JPG 共用同一个主文件名；视频单独一套序列号。")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("打开文件夹…") { rename.chooseFolder() }
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 改名控制区（固定在浏览区上方）

    private var controlBand: some View {
        HStack(alignment: .top, spacing: 16) {
            groupColumn
                .frame(maxWidth: .infinity, alignment: .leading)

            Rectangle().fill(theme.separator).frame(width: 1, height: 92)

            summaryColumn
                .frame(width: 300, alignment: .leading)
        }
        .padding(12)
        .background(theme.panelBackground.opacity(0.25))
    }

    private var summaryColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "模板示例", theme: theme)
            Text(rename.example ?? "—")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            HStack(spacing: 10) {
                miniStat(rename.isRenamingSubset ? "选中" : "片子", "\(rename.isRenamingSubset ? rename.selection.count : rename.groups.count)")
                miniStat("要改名", "\(rename.pendingFileCount)")
                miniStat("不变", "\(rename.pendingUnchangedCount)")
                if rename.conflictCount > 0 {
                    miniStat("重名", "\(rename.conflictCount)", warning: true)
                }
            }

            HStack(spacing: 10) {
                Button {
                    rename.apply()
                } label: {
                    Text("开始改名")
                        .frame(maxWidth: 140)
                }
                .controlSize(.large)
                .disabled(!rename.canApply)

                Text(rename.canUndo ? "⌘Z 撤销（\(rename.lastOperations.count) 个文件）" : "⌘Z 撤销")
                    .font(.system(size: 10.5))
                    .foregroundStyle(rename.canUndo ? theme.primaryText : theme.secondaryText)
            }
        }
    }

    private func miniStat(_ label: String, _ value: String, warning: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(warning ? Color.orange : theme.primaryText)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
        }
    }

    private var groupColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionTitle(text: "按拍摄日期分组", theme: theme)

                if rename.isRenamingSubset {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("只改选中的 \(rename.selection.count) 张")
                            .font(.system(size: 11, weight: .medium))
                        Button("取消选择") { _ = rename.clearSelectionIfNeeded() }
                            .controlSize(.mini)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                }

                Text("统一填写")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)

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
                        .frame(minWidth: 86, idealWidth: index == 0 ? 120 : 100, maxWidth: 150)
                        .focused($focusedField, equals: "bulk#\(index)")
                }

                Button {
                    rename.addSegment()
                } label: {
                    Image(systemName: "plus")
                }
                .controlSize(.small)
                .help("增加一个自定义文本（最多 4 段，例如 婚礼_新娘_精修）")
                .disabled(rename.segmentCount >= 4)

                Button {
                    rename.removeSegment()
                } label: {
                    Image(systemName: "minus")
                }
                .controlSize(.small)
                .help("减少一个自定义文本")
                .disabled(rename.segmentCount <= 1)

                Button("应用到全部") { rename.applyBulkSegments() }
                    .controlSize(.small)
                    .disabled(rename.buckets.isEmpty)

                Rectangle().fill(theme.separator).frame(width: 1, height: 18)

                Picker("", selection: $dateFormatRaw) {
                    ForEach(DateFormatOption.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }
                .labelsHidden()
                .frame(width: 126)
                .help("日期格式")
                .onChange(of: dateFormatRaw) { _, newValue in
                    rename.updateSettings { $0.dateFormat = newValue }
                }

                Picker("", selection: $sequenceDigits) {
                    ForEach(1...6, id: \.self) { digits in
                        Text("\(digits) 位序号").tag(digits)
                    }
                }
                .labelsHidden()
                .frame(width: 98)
                .help("序列号位数")
                .onChange(of: sequenceDigits) { _, newValue in
                    rename.updateSettings { $0.sequenceDigits = newValue }
                }

            }

            ScrollView {
                LazyVStack(spacing: 5) {
                    if rename.buckets.isEmpty {
                        Text("这个文件夹里没有可改名的素材")
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.secondaryText)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(rename.buckets) { bucket in
                            bucketRow(bucket)
                        }
                    }
                }
            }
            // 高度跟着分组数量走，最多约两行半，剩下的留给下面的素材区
            .frame(height: min(CGFloat(max(rename.buckets.count, 1)) * 42 + 8, 104))
        }
    }

    private func bucketRow(_ bucket: RenameGroupPlan) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(bucket.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(bucket.count) 张")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.secondaryText)
                    Text(bucket.familyLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.panelBackground))
                        .foregroundStyle(theme.secondaryText)
                }
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
                .frame(minWidth: 96, idealWidth: 150, maxWidth: 200)
                .focused($focusedField, equals: "\(bucket.id)#\(index)")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.panelBackground.opacity(0.6))
        )
    }
}
