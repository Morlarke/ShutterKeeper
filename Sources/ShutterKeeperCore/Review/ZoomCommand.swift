import Foundation

/// 送到预览画布的一次缩放指令。
///
/// 画布自己维护缩放状态（滚轮、拖拽都在它手里），
/// 菜单与快捷键通过这个指令去驱动它。
public struct ZoomCommand: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// 适应窗口（Bridge 里的 Fit in Window）
        case fit
        /// 1:1 像素
        case actualSize
        case zoomIn
        case zoomOut
    }

    public let id: UUID
    public let kind: Kind

    public init(kind: Kind) {
        self.id = UUID()
        self.kind = kind
    }
}
