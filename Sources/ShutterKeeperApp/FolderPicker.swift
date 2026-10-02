import AppKit
import Foundation

/// 原生文件夹选择面板。
enum FolderPicker {
    static func chooseFolder(message: String, prompt: String = "选择") -> URL? {
        let panel = NSOpenPanel()
        panel.message = message
        panel.prompt = prompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
