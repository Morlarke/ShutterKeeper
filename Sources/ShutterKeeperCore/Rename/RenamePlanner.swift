import Foundation

/// 生成改名计划。
///
/// 规则（对应需求文档第 6 节）：
/// * 模板为 `日期_自定义文本_序列号`
/// * 按「拍摄日期 + 照片/视频」分组，同组共用一个自定义文本，序列号每组从 1 开始递增
/// * 视频单独一套序列号，不与照片混编
/// * RAW + JPG 配对后共用同一个主文件名，只保留各自的扩展名
/// * 同名附属文件（`.xmp` / `.aae` 等）跟着一起改
public enum RenamePlanner {
    public static func plan(
        groups: [AssetGroup],
        texts: [String: String] = [:],
        settings: RenameSettings = RenameSettings(),
        defaultText: String = ""
    ) -> RenamePlan {
        let buckets = makeBuckets(from: groups)
        var operations: [RenameOperation] = []
        var conflicts: [RenameConflict] = []
        var examples: [String] = []
        var unchanged = 0
        var groupPlans: [RenameGroupPlan] = []
        var newNames: [String: String] = [:]
        var filePreviews: [RenameFilePreview] = []

        for bucket in buckets {
            let text = sanitize(texts[bucket.id] ?? defaultText)
            let dateText = dateString(for: bucket.date, format: settings.dateFormat)
            var index = 1
            for group in bucket.groups {
                let sequence = sequenceString(index, digits: settings.sequenceDigits)
                let newBase = [dateText, text, sequence]
                    .filter { !$0.isEmpty }
                    .joined(separator: settings.separator)
                index += 1
                if let displayFile = group.displayFile {
                    newNames[group.id] = "\(newBase).\(displayFile.url.pathExtension)"
                }

                // 主文件 + 附属文件
                for file in group.files {
                    let target = file.directory
                        .appendingPathComponent(newBase)
                        .appendingPathExtension(file.url.pathExtension)
                    append(
                        operationFrom: file.url,
                        to: target,
                        assetID: group.id,
                        into: &operations,
                        unchanged: &unchanged
                    )
                    filePreviews.append(
                        RenameFilePreview(
                            originalURL: file.url,
                            newName: target.lastPathComponent,
                            kind: file.kind,
                            isSidecar: false,
                            assetID: group.id
                        )
                    )
                }
                for sidecar in sidecars(for: group) {
                    let extensionName = sidecar.url.pathExtension
                    let target = sidecar.url.deletingLastPathComponent()
                        .appendingPathComponent(newBase)
                        .appendingPathExtension(extensionName)
                    append(
                        operationFrom: sidecar.url,
                        to: target,
                        assetID: group.id,
                        into: &operations,
                        unchanged: &unchanged
                    )
                    filePreviews.append(
                        RenameFilePreview(
                            originalURL: sidecar.url,
                            newName: target.lastPathComponent,
                            kind: .other,
                            isSidecar: true,
                            assetID: group.id
                        )
                    )
                }
            }
            groupPlans.append(
                RenameGroupPlan(
                    id: bucket.id,
                    date: bucket.date,
                    title: bucket.title,
                    isVideo: bucket.isVideo,
                    groups: bucket.groups,
                    text: text
                )
            )
            if let first = bucket.groups.first, let example = exampleName(for: first, text: text, dateText: dateText, sequence: sequenceString(1, digits: settings.sequenceDigits), separator: settings.separator) {
                examples.append(example)
            }
        }

        // 冲突：目标已存在，且它不在本次改名的源文件里（同批互换不算冲突）
        let sourcePaths = Set(operations.map { $0.originalURL.standardizedFileURL.path })
        for operation in operations where !operation.isNoop {
            let target = operation.finalURL
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            guard !sourcePaths.contains(target.standardizedFileURL.path) else { continue }
            conflicts.append(RenameConflict(source: operation.originalURL, target: target))
        }

        return RenamePlan(
            settings: settings,
            renameGroups: groupPlans,
            operations: operations.filter { !$0.isNoop },
            conflicts: conflicts,
            examples: examples,
            unchangedCount: unchanged,
            newNames: newNames,
            files: filePreviews
        )
    }

    // MARK: - 分组

    struct Bucket {
        let id: String
        let date: Date?
        let title: String
        let isVideo: Bool
        let groups: [AssetGroup]
    }

    static func makeBuckets(from groups: [AssetGroup]) -> [Bucket] {
        var order: [String] = []
        var contents: [String: [AssetGroup]] = [:]

        for group in groups {
            let isVideo = group.isVideo
            let day = group.captureDate.map { ReviewSession.dayIdentifier(for: $0) } ?? "unknown"
            let key = "\(day)#\(isVideo ? "v" : "p")"
            if contents[key] == nil {
                contents[key] = []
                order.append(key)
            }
            contents[key]?.append(group)
        }

        return order.map { key in
            let items = (contents[key] ?? []).sorted { lhs, rhs in
                let lhsDate = lhs.captureDate ?? .distantFuture
                let rhsDate = rhs.captureDate ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.baseName.localizedStandardCompare(rhs.baseName) == .orderedAscending
            }
            let isVideo = key.hasSuffix("#v")
            let date = items.first?.captureDate
            return Bucket(
                id: key,
                date: date,
                title: isVideo ? "\(groupTitle(for: date))（视频）" : groupTitle(for: date),
                isVideo: isVideo,
                groups: items
            )
        }
    }

    static func groupTitle(for date: Date?) -> String {
        guard let date else { return "无拍摄时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    // MARK: - 细节

    static func dateString(for date: Date?, format: String) -> String {
        guard let date else { return "00000000" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = normalizedDateFormat(format)
        return formatter.string(from: date)
    }

    /// 需求文档里的默认格式写作 `yyyymmdd`，但在 ICU 里小写 `m` 表示「分钟」，
    /// 会被格式化成一串 0。这里统一把小写 `m` 当作月份处理。
    static func normalizedDateFormat(_ format: String) -> String {
        String(format.map { $0 == "m" ? "M" : $0 })
    }

    static func sequenceString(_ index: Int, digits: Int) -> String {
        String(format: "%0\(max(1, min(6, digits)))d", index)
    }

    /// 去掉文件名里不允许的字符。
    static func sanitize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return trimmed.components(separatedBy: invalid).joined()
    }

    static func append(
        operationFrom source: URL,
        to target: URL,
        assetID: String,
        into operations: inout [RenameOperation],
        unchanged: inout Int
    ) {
        let operation = RenameOperation(originalURL: source, finalURL: target, assetID: assetID)
        if operation.isNoop {
            unchanged += 1
            return
        }
        operations.append(operation)
    }

    /// 找出与某个配对组同名的附属文件（`.xmp` 最常用，Lightroom 就是这么配的）。
    static func sidecars(for group: AssetGroup) -> [FileRef] {
        group.sidecars
    }

    static func exampleName(
        for group: AssetGroup,
        text: String,
        dateText: String,
        sequence: String,
        separator: String
    ) -> String? {
        guard let file = group.displayFile ?? group.files.first else { return nil }
        let base = [dateText, text, sequence].filter { !$0.isEmpty }.joined(separator: separator)
        return "\(base).\(file.url.pathExtension)"
    }
}

extension AssetGroup {
    /// 展示用文件（优先 RAW，其次 JPG，最后视频）。
    var displayFile: FileRef? {
        if let proprietaryRAW { return proprietaryRAW }
        if let dng { return dng }
        if let jpeg { return jpeg }
        if let video { return video }
        return files.first
    }
}
