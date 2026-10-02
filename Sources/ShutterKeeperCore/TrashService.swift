import Foundation

/// 删除一律进废纸篓，不做彻底删除。
public enum TrashService {
    public struct Outcome: Sendable {
        public var trashed: [URL] = []
        public var failures: [(url: URL, message: String)] = []

        public var allSucceeded: Bool { failures.isEmpty }
    }

    /// 把一组文件（含 `.xmp` 附属文件）移入废纸篓。
    @discardableResult
    public static func moveToTrash(_ urls: [URL]) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                outcome.trashed.append(url)
            } catch {
                outcome.failures.append((url, error.localizedDescription))
            }
        }
        return outcome
    }

    /// 删除一张片子：配对成员 + 相应的 `.xmp` 附属文件。
    @discardableResult
    public static func moveToTrash(group: AssetGroup) -> Outcome {
        moveToTrash(group.deletionTargets.map(\.url))
    }
}
