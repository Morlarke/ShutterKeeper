import ShutterKeeperCore
import SwiftUI

/// 导入模块。
///
/// 从上到下：来源选择 → 项目设置（项目名/日期/目标/备份）→ 源文件按拍摄日期分组预览 → 进度与执行。
struct ImportView: View {
    @ObservedObject var importer: ImportState
    let theme: AppTheme

    @EnvironmentObject private var state: AppState
    @State private var previewLimit = 240

    var body: some View {
        VStack(spacing: 0) {
            sourceBar
            separator
            settingsBar
            separator
            previewArea
            separator
            actionBar
        }
        .alert(
            "目标文件夹已存在",
            isPresented: Binding(
                get: { importer.projectFolderConflict },
                set: { if !$0 { importer.cancelFolderConflict() } }
            )
        ) {
            Button("合并进已有文件夹") { importer.resolveFolderConflictMerge() }
            Button("新建带后缀的文件夹") { importer.resolveFolderConflictNewFolder() }
            Button("取消", role: .cancel) { importer.cancelFolderConflict() }
        } message: {
            Text("\(importer.plan?.projectURL.path ?? "")\n\n合并会把文件放进已有文件夹；新建会创建「\(importer.plan?.projectFolderName ?? "")-2」这样的新文件夹。")
        }
        .alert(
            "有 \(importer.pendingConflicts.count) 个文件需要决定",
            isPresented: Binding(
                get: { !importer.pendingConflicts.isEmpty },
                set: { if !$0 { importer.cancelConflicts() } }
            )
        ) {
            Button("跳过这些文件") { importer.resolveConflicts(.skip) }
            Button("覆盖（旧文件进废纸篓）", role: .destructive) { importer.resolveConflicts(.overwrite) }
            Button("取消", role: .cancel) { importer.cancelConflicts() }
        } message: {
            Text(conflictMessage)
        }
        .alert(
            "导入完成",
            isPresented: Binding(
                get: { importer.askToTrashSources },
                set: { if !$0 { importer.keepSourceFiles() } }
            )
        ) {
            Button("移入废纸篓", role: .destructive) { importer.trashSourceFiles() }
            Button("保留卡内文件", role: .cancel) { importer.keepSourceFiles() }
            Button("在访达中显示") {
                importer.keepSourceFiles()
                importer.revealProject()
            }
        } message: {
            Text("已导入 \(importer.lastOutcome?.copied.count ?? 0) 个文件到\n\(importer.lastProjectURL?.path ?? "")\n\n要不要把这次已确认导入的卡内原文件移入废纸篓？（只删除已成功导入的那些）")
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { importer.errorMessage != nil },
                set: { if !$0 { importer.errorMessage = nil } }
            )
        ) {
            Button("知道了", role: .cancel) { importer.errorMessage = nil }
        } message: {
            Text(importer.errorMessage ?? "")
        }
    }

    private var separator: some View {
        Rectangle().fill(theme.separator).frame(height: 1)
    }

    private var conflictMessage: String {
        let names = importer.pendingConflicts.prefix(6).map { $0.task.source.lastPathComponent }
        let kinds = Set(importer.pendingConflicts.map { $0.kind == .alreadyImported ? "之前导入过" : "目标已存在" })
        var lines = ["类型：" + kinds.sorted().joined(separator: "、")]
        lines.append("例如：" + names.joined(separator: "、"))
        if importer.pendingConflicts.count > names.count {
            lines.append("…等共 \(importer.pendingConflicts.count) 个")
        }
        lines.append("")
        lines.append("「跳过」只导入其余文件；「覆盖」会把目标里已存在的文件先移入废纸篓。")
        return lines.joined(separator: "\n")
    }

    // MARK: - 来源

    private var sourceBar: some View {
        HStack(spacing: 10) {
            Text("来源")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.secondaryText)

            Menu {
                ForEach(importer.volumes) { volume in
                    Button {
                        importer.selectSource(volume.url, label: volume.name)
                    } label: {
                        Text("\(volume.name)（\(volume.badgeText)）")
                    }
                }
                if importer.volumes.isEmpty {
                    Text("没有检测到挂载的卷")
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "externaldrive")
                    Text(importer.sourceLabel.isEmpty ? "选择卷" : importer.sourceLabel)
                }
            }
            .frame(width: 220)
            .disabled(importer.isImporting)

            Button("选择文件夹…") { importer.chooseSourceFolder() }
                .controlSize(.small)
                .disabled(importer.isImporting)

            Button {
                importer.refreshVolumes()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("重新检测挂载的卷")

            if let source = importer.source {
                Text(source.path)
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if importer.isScanning {
                ProgressView().controlSize(.small)
            } else if importer.sourceFileCount > 0 {
                Text("\(importer.sourceFileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: importer.sourceBytes, countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            } else if importer.volumes.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "sdcard")
                    Text("没有检测到外接设备，插上 SD 卡 / U 盘后点左边的刷新")
                }
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - 项目设置

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("项目名")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                TextField("例如 婚礼", text: $importer.projectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(importer.isImporting)
                    .onChange(of: importer.projectName) { _, _ in importer.rebuildPlan() }

                Text("日期")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                TextField(hintDate, text: $importer.dateText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .disabled(importer.isImporting)
                    .onChange(of: importer.dateText) { _, _ in importer.rebuildPlan() }

                Text("目标位置")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                Button("选择…") { importer.chooseDestination() }
                    .controlSize(.small)
                    .disabled(importer.isImporting)
                Text(importer.destinationRoot?.path ?? "未选择")
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 320, alignment: .leading)

                Spacer()
            }

            HStack(spacing: 12) {
                Toggle("同时备份到另一个位置", isOn: Binding(
                    get: { importer.copyToBackup },
                    set: { importer.setCopyToBackup($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .disabled(importer.isImporting)

                Button("选择备份位置…") { importer.chooseBackup() }
                    .controlSize(.small)
                    .disabled(importer.isImporting)

                Text(importer.backupRoot?.path ?? "未选择备份位置")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(importer.copyToBackup && importer.backupRoot == nil ? Color.orange : theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 360, alignment: .leading)

                Spacer()

                if let plan = importer.plan {
                    Text("将创建：\(plan.projectURL.lastPathComponent)/")
                        .font(.system(size: 11.5, weight: .medium))
                    Text("Photos \(plan.photoCount) 张 · Videos \(plan.videoCount) 个")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                    if !plan.hasEnoughSpace {
                        Text("目标空间不足！")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    if plan.settings.copyToBackup && !plan.backupHasEnoughSpace {
                        Text("备份空间不足！")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.panelBackground.opacity(0.3))
    }

    private var hintDate: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = importer.earliestCaptureDate {
            return formatter.string(from: date)
        }
        return formatter.string(from: Date())
    }

    // MARK: - 源文件预览

    private var previewArea: some View {
        Group {
            if importer.assets.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.secondaryText)
                    Text(importer.isScanning ? "正在读取来源…" : "选一张 SD 卡或文件夹开始导入")
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(importer.dayGroups) { group in
                            daySection(group)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func daySection(_ group: ImportDayGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text("\(group.assets.count) 张 · \(group.fileCount) 个文件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: 10)], spacing: 10) {
                ForEach(group.assets.prefix(previewLimit)) { asset in
                    ImportAssetCell(asset: asset, cache: cache, theme: theme)
                }
                if group.assets.count > previewLimit {
                    Text("还有 \(group.assets.count - previewLimit) 张未显示")
                        .font(.system(size: 10.5))
                        .foregroundStyle(theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var cache: ThumbnailCache? { state.thumbnailCache }

    // MARK: - 执行

    private var actionBar: some View {
        VStack(spacing: 8) {
            if let progress = importer.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                    HStack(spacing: 10) {
                        Text(progress.statusText)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text("\(progress.filesCompleted)/\(progress.filesTotal) 个文件")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.secondaryText)
                        if let remaining = progress.estimatedRemaining, remaining > 0 {
                            Text("剩余约 \(Int(remaining.rounded())) 秒")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.secondaryText)
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                if let status = importer.statusMessage {
                    Text(status)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                }
                Spacer()
                if let plan = importer.plan, !importer.isImporting {
                    Text("共 \(plan.tasks.count) 个文件 · \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                if importer.isImporting {
                    Button("取消导入") { importer.cancelImport() }
                        .controlSize(.large)
                }
                Button {
                    importer.start()
                } label: {
                    Text("开始导入")
                        .frame(maxWidth: 140)
                }
                .controlSize(.large)
                .disabled(!importer.canStart)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 预览用的一个素材格子（配对后只显示一个）。
private struct ImportAssetCell: View {
    let asset: AssetGroup
    let cache: ThumbnailCache?
    let theme: AppTheme

    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Rectangle().fill(Color.black.opacity(0.25))
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: asset.isVideo ? "film" : "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(theme.secondaryText)
                }
                if asset.isPaired, !asset.isVideo {
                    VStack {
                        HStack {
                            Text("RAW+JPG")
                                .font(.system(size: 8, weight: .medium))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .foregroundStyle(.white)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(3)
                }
            }
            .frame(height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.separator, lineWidth: 1)
            )
            Text(asset.displayName)
                .font(.system(size: 9.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(theme.secondaryText)
        }
        .task(id: asset.id) {
            guard image == nil, let cache, let file = asset.previewFile else { return }
            image = await cache.thumbnail(for: file, maxPixel: 220)
        }
    }
}
