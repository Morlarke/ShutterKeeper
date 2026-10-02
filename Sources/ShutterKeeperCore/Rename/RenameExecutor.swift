import Foundation

/// 执行改名与撤销。
///
/// 用「两段式」搬运：先把所有源文件改成同目录下的临时名，再改成最终名。
/// 这样 A→B、B→C 这类链式改名、甚至 A→B、B→A 的互换都不会互相覆盖。
public enum RenameExecutor {
    public struct Outcome: Sendable {
        public var renamed: [RenameOperation] = []
        public var failures: [(url: URL, message: String)] = []

        public var succeeded: Bool { failures.isEmpty }
    }

    /// 执行改名。`conflictingSources` 里的源文件会被跳过（用户在冲突对话框里选择跳过的那些）。
    @discardableResult
    public static func apply(
        plan: RenamePlan,
        skipping conflictingSources: Set<URL> = [],
        replacingTargets: Set<URL> = [],
        progress: ((Int, Int) -> Void)? = nil
    ) -> Outcome {
        var outcome = Outcome()
        let operations = plan.operations.filter { operation in
            !conflictingSources.contains(operation.originalURL.standardizedFileURL)
        }
        guard !operations.isEmpty else { return outcome }

        var staged: [(temp: URL, operation: RenameOperation)] = []

        // 第一段：源文件 → 临时名
        for (index, operation) in operations.enumerated() {
            progress?(index, operations.count * 2)
            let temp = temporaryURL(for: operation.originalURL)
            do {
                try FileManager.default.moveItem(at: operation.originalURL, to: temp)
                staged.append((temp, operation))
            } catch {
                outcome.failures.append((operation.originalURL, error.localizedDescription))
            }
        }

        // 第二段：临时名 → 目标名
        for (index, entry) in staged.enumerated() {
            progress?(operations.count + index, operations.count * 2)
            let target = entry.operation.finalURL
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    if replacingTargets.contains(target.standardizedFileURL) {
                        // 用户选择覆盖：把已存在的文件移进废纸篓，而不是直接删掉
                        try TrashService.moveToTrash([target])
                    } else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                }
                try FileManager.default.moveItem(at: entry.temp, to: target)
                outcome.renamed.append(entry.operation)
            } catch {
                outcome.failures.append((target, error.localizedDescription))
                // 失败就退回去，别把文件卡在临时名上
                try? FileManager.default.moveItem(at: entry.temp, to: entry.operation.originalURL)
            }
        }
        progress?(operations.count * 2, operations.count * 2)
        return outcome
    }

    /// 撤销上一次改名（仅本次运行内有效）。
    ///
    /// 如果原来的文件名已经被别的文件占用，就跳过那一项并在结果里报出来。
    @discardableResult
    public static func undo(_ operations: [RenameOperation], progress: ((Int, Int) -> Void)? = nil) -> Outcome {
        var outcome = Outcome()
        let reversed = operations.reversed()
        var staged: [(temp: URL, operation: RenameOperation)] = []

        for (index, operation) in reversed.enumerated() {
            progress?(index, operations.count * 2)
            guard FileManager.default.fileExists(atPath: operation.finalURL.path) else { continue }
            if FileManager.default.fileExists(atPath: operation.originalURL.path) {
                outcome.failures.append((operation.originalURL, "原文件名已被占用，跳过"))
                continue
            }
            let temp = temporaryURL(for: operation.finalURL)
            do {
                try FileManager.default.moveItem(at: operation.finalURL, to: temp)
                staged.append((temp, operation))
            } catch {
                outcome.failures.append((operation.finalURL, error.localizedDescription))
            }
        }

        for (index, entry) in staged.enumerated() {
            progress?(operations.count + index, operations.count * 2)
            do {
                try FileManager.default.moveItem(at: entry.temp, to: entry.operation.originalURL)
                outcome.renamed.append(
                    RenameOperation(originalURL: entry.operation.finalURL, finalURL: entry.operation.originalURL)
                )
            } catch {
                outcome.failures.append((entry.operation.originalURL, error.localizedDescription))
                try? FileManager.default.moveItem(at: entry.temp, to: entry.operation.finalURL)
            }
        }
        progress?(operations.count * 2, operations.count * 2)
        return outcome
    }

    /// 同目录下的临时文件名，改名过程中不会与素材重名。
    static func temporaryURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".shutterkeeper-rename-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension)
    }
}
