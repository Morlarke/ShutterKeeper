import Foundation

/// 快捷键起作用的场景。同一个按键在不同场景下可以承担不同功能
/// （例如空格：照片是全屏，视频是播放/暂停）。
public enum ShortcutContext: String, Codable, Sendable {
    case any
    case photo
    case video

    public func matches(_ other: ShortcutContext) -> Bool {
        self == .any || other == .any || self == other
    }
}

/// 可绑定的操作。
public enum ShortcutAction: String, CaseIterable, Codable, Sendable {
    case rate0, rate1, rate2, rate3, rate4, rate5
    case next, previous
    case nextDateGroup, previousDateGroup
    case volumeUp, volumeDown
    case toggleFullScreen
    case videoPlayPause
    case toggleExifPanel
    case togglePanels
    case deleteCurrent
    case filterClear
    case filterAtLeast1, filterAtLeast2, filterAtLeast3, filterAtLeast4, filterAtLeast5
    case thumbnailSizeUp, thumbnailSizeDown
    case zoomIn, zoomOut, zoomToFit
    case zoomToActualSize
    case parentFolder
    case toggleFolderPanel
    case undo
    case iconView
    case columnView
    case rotateLeft
    case rotateRight
    case selectAll
    case showInfo

    public var displayName: String {
        switch self {
        case .rate0, .rate1, .rate2, .rate3, .rate4, .rate5:
            return "打 \(ratingValue ?? 0) 星"
        case .next: return "下一张"
        case .previous: return "上一张"
        case .nextDateGroup: return "下一组（按日期）"
        case .previousDateGroup: return "上一组（按日期）"
        case .volumeUp: return "视频音量 +"
        case .volumeDown: return "视频音量 −"
        case .toggleFullScreen: return "照片全屏"
        case .videoPlayPause: return "视频播放 / 暂停"
        case .toggleExifPanel: return "EXIF 面板显示 / 隐藏"
        case .togglePanels: return "显示 / 隐藏面板"
        case .deleteCurrent: return "删除当前（进废纸篓）"
        case .filterClear: return "清除星级筛选"
        case .filterAtLeast1, .filterAtLeast2, .filterAtLeast3, .filterAtLeast4, .filterAtLeast5:
            return "筛选 ≥\(filterStars ?? 1) 星"
        case .thumbnailSizeUp: return "缩略图变大"
        case .thumbnailSizeDown: return "缩略图变小"
        case .zoomIn: return "放大"
        case .zoomOut: return "缩小"
        case .zoomToFit: return "适应窗口"
        case .zoomToActualSize: return "1:1 像素"
        case .parentFolder: return "打开上一级文件夹"
        case .toggleFolderPanel: return "显示 / 隐藏文件夹面板"
        case .undo: return "撤销上一次改名"
        case .iconView: return "改成图标视图"
        case .columnView: return "改成分栏视图"
        case .rotateLeft: return "向左旋转 90°"
        case .rotateRight: return "向右旋转 90°"
        case .selectAll: return "全选"
        case .showInfo: return "文件简介"
        }
    }

    public var ratingValue: Int? {
        switch self {
        case .rate0: return 0
        case .rate1: return 1
        case .rate2: return 2
        case .rate3: return 3
        case .rate4: return 4
        case .rate5: return 5
        default: return nil
        }
    }

    public var filterStars: Int? {
        switch self {
        case .filterAtLeast1: return 1
        case .filterAtLeast2: return 2
        case .filterAtLeast3: return 3
        case .filterAtLeast4: return 4
        case .filterAtLeast5: return 5
        default: return nil
        }
    }

    /// 默认场景。空格与上下方向键在照片/视频下含义不同，因此分开声明。
    public var context: ShortcutContext {
        switch self {
        case .nextDateGroup, .previousDateGroup, .toggleFullScreen:
            return .photo
        case .volumeUp, .volumeDown, .videoPlayPause:
            return .video
        default:
            return .any
        }
    }

    /// 需求文档第 9 节的默认快捷键。
    public var defaultShortcut: KeyShortcut {
        switch self {
        case .rate1: return KeyShortcut(keyCode: 18)
        case .rate2: return KeyShortcut(keyCode: 19)
        case .rate3: return KeyShortcut(keyCode: 20)
        case .rate4: return KeyShortcut(keyCode: 21)
        case .rate5: return KeyShortcut(keyCode: 23)
        case .rate0: return KeyShortcut(keyCode: 29)
        case .previous: return KeyShortcut(keyCode: 123)
        case .next: return KeyShortcut(keyCode: 124)
        case .previousDateGroup: return KeyShortcut(keyCode: 126)
        case .nextDateGroup: return KeyShortcut(keyCode: 125)
        case .volumeUp: return KeyShortcut(keyCode: 126)
        case .volumeDown: return KeyShortcut(keyCode: 125)
        case .toggleFullScreen: return KeyShortcut(keyCode: 49)
        case .videoPlayPause: return KeyShortcut(keyCode: 49)
        case .toggleExifPanel: return KeyShortcut(keyCode: 35)
        case .togglePanels: return KeyShortcut(keyCode: 48)
        case .deleteCurrent: return KeyShortcut(keyCode: 51)
        case .filterClear: return KeyShortcut(keyCode: 29, modifiers: [.command, .option])
        case .filterAtLeast1: return KeyShortcut(keyCode: 18, modifiers: [.command, .option])
        case .filterAtLeast2: return KeyShortcut(keyCode: 19, modifiers: [.command, .option])
        case .filterAtLeast3: return KeyShortcut(keyCode: 20, modifiers: [.command, .option])
        case .filterAtLeast4: return KeyShortcut(keyCode: 21, modifiers: [.command, .option])
        case .filterAtLeast5: return KeyShortcut(keyCode: 23, modifiers: [.command, .option])
        case .thumbnailSizeUp: return KeyShortcut(keyCode: 24, modifiers: [.command])
        case .thumbnailSizeDown: return KeyShortcut(keyCode: 27, modifiers: [.command])
        case .zoomIn: return KeyShortcut(keyCode: 24, modifiers: [.command, .shift])
        case .zoomOut: return KeyShortcut(keyCode: 27, modifiers: [.command, .shift])
        case .zoomToFit: return KeyShortcut(keyCode: 29, modifiers: [.command])
        case .zoomToActualSize: return KeyShortcut(keyCode: 29, modifiers: [.command, .shift])
        case .parentFolder: return KeyShortcut(keyCode: 126, modifiers: [.command, .option])
        case .toggleFolderPanel: return KeyShortcut(keyCode: 11, modifiers: [.command, .option])
        case .undo: return KeyShortcut(keyCode: 6, modifiers: [.command])
        case .iconView: return KeyShortcut(keyCode: 18, modifiers: [.command])
        case .columnView: return KeyShortcut(keyCode: 19, modifiers: [.command])
        case .rotateLeft: return KeyShortcut(keyCode: 33, modifiers: [.command])
        case .rotateRight: return KeyShortcut(keyCode: 30, modifiers: [.command])
        case .selectAll: return KeyShortcut(keyCode: 0, modifiers: [.command])
        case .showInfo: return KeyShortcut(keyCode: 34, modifiers: [.command])
        }
    }

    /// 「切换上/下一个视图」在需求文档里是 ⌘\ 与 ⌘⇧\，用来在顶部三个模块之间循环。
    public static let nextModule = KeyShortcut(keyCode: 42, modifiers: [.command])
    public static let previousModule = KeyShortcut(keyCode: 42, modifiers: [.command, .shift])
}

/// 快捷键冲突。
public struct ShortcutConflict: Equatable, Sendable {
    public let action: ShortcutAction
    public let shortcut: KeyShortcut
}
