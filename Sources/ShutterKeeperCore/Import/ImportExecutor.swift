import Foundation

/// 真正搬文件的地方：分块拷贝、进度、取消、覆盖、备份。
///
/// 拷贝先写到同目录的临时文件，校验大小之后再改名就位，
/// 所以中途拔卡或空间不足都不会在目标里留下半个文件。
public enum ImportExecutor {
    public struct Options {
        /// 源文件路径 → 用户对该冲突的决定。
        public var decisions: [String: ImportDecision] = [:]
        /// 没预先决定的冲突，交给调用方询问用户；返回 nil 表示跳过。
        public var resolveConflict: ((ImportConflict) -> ImportDecision?)?
        public var progress: ((ImportProgress) -> Void)?
        public var shouldCancel: (() -> Bool)?
        public var history: ImportHistoryStore?
        public var volumeName: String?
        public var sourceRoot: URL?

        public init() {}
    }

    public static func run(plan: ImportPlan, options: Options = Options()) -> ImportOutcome {
        var outcome = ImportOutcome()
        let fileManager = FileManager.default
        let conflictMap = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.task.source.path, $0) })

        func report(_ progress: ImportProgress) {
            options.progress?(progress)
        }
        func cancelled() -> Bool {
            options.shouldCancel?() ?? false
        }

        // 目标目录
        do {
            try fileManager.createDirectory(at: plan.projectURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: plan.projectURL.appendingPathComponent("Photos", isDirectory: true),
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: plan.projectURL.appendingPathComponent("Videos", isDirectory: true),
                withIntermediateDirectories: true
            )
        } catch {
            outcome.failures.append((plan.projectURL, "无法创建目标文件夹：\(error.localizedDescription)"))
            return outcome
        }

        report(
            ImportProgress(
                phase: .preparing,
                currentFileName: "",
                filesCompleted: 0,
                filesTotal: plan.tasks.count,
                bytesCompleted: 0,
                bytesTotal: plan.totalBytes,
                estimatedRemaining: nil
            )
        )

        var bytesDone: Int64 = 0
        let started = Date()

        // 第一遍：主导入
        for (index, task) in plan.tasks.enumerated() {
            if cancelled() {
                outcome.cancelled = true
                break
            }

            var decision: ImportDecision?
            if let conflict = conflictMap[task.source.path] {
                decision = options.decisions[task.source.path]
                    ?? options.resolveConflict?(conflict)
                    ?? .skip
            }
            if decision == .skip {
                outcome.skipped.append(task)
                continue
            }

            do {
                try copyFile(
                    task: task,
                    overwrite: decision == .overwrite,
                    phase: .copying,
                    bytesDone: bytesDone,
                    filesCompleted: index,
                    totalFiles: plan.tasks.count,
                    totalBytes: plan.totalBytes,
                    started: started,
                    report: report,
                    cancelled: cancelled
                )
                outcome.copied.append(task)
                bytesDone += task.fileSize
            } catch let error as CopyError {
                if case .cancelled = error {
                    outcome.cancelled = true
                    break
                }
                outcome.failures.append((task.source, error.message))
                // 需求文档 5.5：中途拔卡、空间不够、文件损坏都停下来问用户
                break
            } catch {
                outcome.failures.append((task.source, error.localizedDescription))
                break
            }
        }

        // 第二遍：备份（结构完全一致）
        if !outcome.cancelled, plan.settings.copyToBackup, plan.settings.backupRoot != nil {
            var backupBytes: Int64 = 0
            for (index, task) in outcome.copied.enumerated() {
                if cancelled() {
                    outcome.cancelled = true
                    break
                }
                guard let backupDestination = task.backupDestination else { continue }
                let backupTask = ImportTask(
                    source: task.destination,
                    destination: backupDestination,
                    backupDestination: nil,
                    fileSize: task.fileSize,
                    isSidecar: task.isSidecar,
                    assetID: task.assetID,
                    isVideo: task.isVideo
                )
                do {
                    try copyFile(
                        task: backupTask,
                        overwrite: true,
                        phase: .backingUp,
                        bytesDone: backupBytes,
                        filesCompleted: index,
                        totalFiles: outcome.copied.count,
                        totalBytes: plan.totalBytes,
                        started: started,
                        report: report,
                        cancelled: cancelled
                    )
                    backupBytes += task.fileSize
                } catch let error as CopyError {
                    if case .cancelled = error {
                        outcome.cancelled = true
                        break
                    }
                    outcome.backupFailures.append((task.source, error.message))
                    break
                } catch {
                    outcome.backupFailures.append((task.source, error.localizedDescription))
                    break
                }
            }
        }

        report(
            ImportProgress(
                phase: .finishing,
                currentFileName: "",
                filesCompleted: outcome.copied.count,
                filesTotal: plan.tasks.count,
                bytesCompleted: bytesDone,
                bytesTotal: plan.totalBytes,
                estimatedRemaining: 0
            )
        )

        // 记录导入历史（用于下次判断「卡里这个文件是不是导过了」）
        if let history = options.history, let volume = options.volumeName, !outcome.copied.isEmpty {
            let entries = outcome.copied.compactMap { task -> ImportHistoryEntry? in
                guard let sourceRoot = options.sourceRoot else { return nil }
                return ImportHistoryEntry(
                    volume: volume,
                    relativePath: VolumeScanner.relativePath(of: task.source, from: sourceRoot),
                    fileName: task.source.lastPathComponent,
                    fileSize: task.fileSize,
                    projectPath: plan.projectURL.path
                )
            }
            try? history.record(entries)
        }

        return outcome
    }

    // MARK: - 拷贝

    enum CopyError: Error {
        case cancelled
        case failed(URL, String)

        var message: String {
            switch self {
            case .cancelled: return "已取消"
            case .failed(let url, let message): return "\(url.lastPathComponent)：\(message)"
            }
        }
    }

    static func copyFile(
        task: ImportTask,
        overwrite: Bool,
        phase: ImportProgress.Phase,
        bytesDone: Int64,
        filesCompleted: Int,
        totalFiles: Int,
        totalBytes: Int64,
        started: Date,
        report: (ImportProgress) -> Void,
        cancelled: () -> Bool
    ) throws {
        let fileManager = FileManager.default
        let destination = task.destination
        let folder = destination.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw CopyError.failed(folder, "无法创建目录：\(error.localizedDescription)")
        }

        if fileManager.fileExists(atPath: destination.path) {
            if overwrite {
                // 覆盖＝把旧文件移入废纸篓，而不是直接删掉
                _ = TrashService.moveToTrash([destination])
            } else {
                throw CopyError.failed(destination, "目标已存在")
            }
        }

        let partial = folder.appendingPathComponent(".\(destination.lastPathComponent).shutterkeeper-part")
        try? fileManager.removeItem(at: partial)

        guard let input = try? FileHandle(forReadingFrom: task.source) else {
            throw CopyError.failed(task.source, "无法读取源文件（卡是不是被拔掉了？）")
        }
        defer { try? input.close() }
        guard fileManager.createFile(atPath: partial.path, contents: nil),
              let output = try? FileHandle(forWritingTo: partial) else {
            throw CopyError.failed(partial, "无法写入目标文件（空间不足或没有权限）")
        }

        let chunkSize = 4 << 20
        var copied: Int64 = 0
        do {
            while true {
                if cancelled() {
                    try? output.close()
                    try? fileManager.removeItem(at: partial)
                    throw CopyError.cancelled
                }
                guard let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
                let elapsed = Date().timeIntervalSince(started)
                let done = bytesDone + copied
                let speed = elapsed > 0 ? Double(done) / elapsed : 0
                let remaining = speed > 1 ? Double(totalBytes - done) / speed : nil
                report(
                    ImportProgress(
                        phase: phase,
                        currentFileName: task.source.lastPathComponent,
                        filesCompleted: filesCompleted,
                        filesTotal: totalFiles,
                        bytesCompleted: done,
                        bytesTotal: totalBytes,
                        estimatedRemaining: remaining
                    )
                )
            }
            try output.synchronize()
            try output.close()
        } catch let error as CopyError {
            try? output.close()
            try? fileManager.removeItem(at: partial)
            throw error
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: partial)
            throw CopyError.failed(task.source, "拷贝中断：\(error.localizedDescription)")
        }

        // 校验大小，确认没有拷坏
        let writtenSize = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let sourceSize = (try? task.source.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? task.fileSize
        guard writtenSize == sourceSize else {
            try? fileManager.removeItem(at: partial)
            throw CopyError.failed(task.source, "拷贝后大小不一致（源 \(sourceSize) 字节，目标 \(writtenSize) 字节）")
        }

        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw CopyError.failed(destination, error.localizedDescription)
        }
    }

}
