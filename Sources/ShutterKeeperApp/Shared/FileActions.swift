import AppKit
import Foundation

/// 右键菜单里几个与系统打交道的动作。
enum FileActions {
    /// 在访达中选中这些文件。
    static func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// 打开访达的「简介」窗口。
    ///
    /// 走 AppleScript 调 Finder；如果被系统隐私设置拦下（第一次会弹「想要控制访达」），
    /// 返回 false，由调用方退回「在访达中显示」。
    @discardableResult
    static func showInfo(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        // 一次最多开 5 个窗口，免得选了几百张时把访达塞爆
        let limited = Array(urls.prefix(5))
        for url in limited {
            guard runFinderInfoScript(for: url) else { return false }
        }
        return true
    }

    private static func runFinderInfoScript(for url: URL) -> Bool {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            activate
            open information window of (POSIX file "\(escaped)" as alias)
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        return error == nil
    }
}
