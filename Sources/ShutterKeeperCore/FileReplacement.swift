import Foundation

/// 原地替换文件内容，但保留原文件的创建日期、扩展属性与权限。
///
/// 先写同目录临时文件，再用 `replaceItemAt` 交换，避免半截写入损坏原文件。
enum FileReplacement {
    static func replaceContents(of url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).shutterkeeper-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
