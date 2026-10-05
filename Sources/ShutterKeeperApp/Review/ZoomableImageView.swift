import AppKit
import ShutterKeeperCore
import SwiftUI

/// 大图预览：滚轮缩放、拖拽平移，最大到 1:1 像素。
///
/// 「1:1」按设备像素算：Retina 屏上 1 个图像像素对应 1 个物理像素，
/// 这才是检查对焦时用户真正想要的效果。
struct ZoomableImageView: NSViewRepresentable {
    let preview: PreviewLoader.Preview?
    /// 换图时递增，用来把缩放重置回「适应窗口」。
    let resetToken: Int
    /// 来自菜单 / 快捷键的缩放指令（⌘0 适应窗口、⌘⇧0 到 1:1 等）。
    let command: ZoomCommand?
    /// 大图区域的背景色（与偏好设置里的背景色是同一项）。
    let background: AppBackground
    var onSelectBackground: (AppBackground) -> Void
    var onZoomChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> ZoomCanvasView {
        let view = ZoomCanvasView()
        view.onZoomChanged = onZoomChanged
        view.background = background
        view.onSelectBackground = onSelectBackground
        return view
    }

    func updateNSView(_ view: ZoomCanvasView, context: Context) {
        view.onZoomChanged = onZoomChanged
        view.background = background
        view.onSelectBackground = onSelectBackground
        view.apply(preview: preview, resetToken: resetToken)
        view.apply(command: command)
    }
}

/// 右键背景色菜单的动作接收者。
private final class BackgroundMenuTarget: NSObject {
    weak var view: ZoomCanvasView?

    @objc func selectBackground(_ sender: NSMenuItem) {
        let cases = AppBackground.allCases
        guard cases.indices.contains(sender.tag) else { return }
        view?.onSelectBackground?(cases[sender.tag])
    }
}

final class ZoomCanvasView: NSView {
    var onZoomChanged: ((CGFloat) -> Void)?
    var onSelectBackground: ((AppBackground) -> Void)?
    var background: AppBackground = .neutralGray {
        didSet {
            if background != oldValue { needsDisplay = true }
        }
    }

    private lazy var backgroundMenuTarget: BackgroundMenuTarget = {
        let target = BackgroundMenuTarget()
        target.view = self
        return target
    }()

    private var image: CGImage?
    private var imagePixelSize: CGSize = .zero
    private var zoom: CGFloat = 1
    private var minZoom: CGFloat = 0.05
    private var offset: CGPoint = .zero
    private var dragOrigin: NSPoint?
    private var dragStartOffset: CGPoint = .zero
    private var currentResetToken = -1
    private var lastCommandID: UUID?
    private var pendingReset = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    /// 视图是图层支撑的，必须显式裁掉越界内容，
    /// 否则放大后的图片会画到胶片条和顶部信息条上面去。
    private func configureLayer() {
        wantsLayer = true
        layer?.masksToBounds = true
        clipsToBounds = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.masksToBounds = true
    }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? 2
    }

    /// 1 个图像像素占多少「点」。zoom = 1 时是 1/backingScale。
    private var pointsPerPixel: CGFloat { zoom / backingScale }

    func apply(preview: PreviewLoader.Preview?, resetToken: Int) {
        let tokenChanged = resetToken != currentResetToken
        currentResetToken = resetToken

        if let preview {
            let sizeChanged = preview.imagePixelSize != imagePixelSize
            image = preview.image
            imagePixelSize = preview.imagePixelSize
            if sizeChanged { pendingReset = true }
        } else {
            image = nil
            imagePixelSize = .zero
        }
        if tokenChanged { pendingReset = true }

        if pendingReset, imagePixelSize.width > 0 {
            resetToFit()
        } else {
            clampZoom()
            needsDisplay = true
        }
    }

    /// 执行菜单 / 快捷键送来的缩放指令，同一条指令只执行一次。
    func apply(command: ZoomCommand?) {
        guard let command, command.id != lastCommandID else { return }
        lastCommandID = command.id
        switch command.kind {
        case .fit:
            resetToFit()
        case .actualSize:
            guard imagePixelSize.width > 0 else { return }
            zoom = max(minZoom, 1)
            offset = .zero
            needsDisplay = true
            onZoomChanged?(zoom)
        case .zoomIn:
            zoomAt(point: CGPoint(x: bounds.midX, y: bounds.midY), factor: 1.25)
        case .zoomOut:
            zoomAt(point: CGPoint(x: bounds.midX, y: bounds.midY), factor: 0.8)
        }
    }

    // MARK: - 布局

    override func layout() {
        super.layout()
        if pendingReset {
            resetToFit()
        } else {
            clampZoom()
            clampOffset()
            needsDisplay = true
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if pendingReset {
            resetToFit()
        } else {
            clampZoom()
            needsDisplay = true
        }
    }

    func resetToFit() {
        guard imagePixelSize.width > 0, imagePixelSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return
        }
        let oneToOneSize = CGSize(width: imagePixelSize.width / backingScale, height: imagePixelSize.height / backingScale)
        let fit = min(bounds.width / oneToOneSize.width, bounds.height / oneToOneSize.height)
        // 不把图片放大到超过 1:1
        minZoom = min(1, max(0.02, fit))
        zoom = minZoom
        offset = .zero
        pendingReset = false
        needsDisplay = true
        onZoomChanged?(zoom)
    }

    private func clampZoom() {
        guard imagePixelSize.width > 0 else { return }
        let oneToOneSize = CGSize(width: imagePixelSize.width / backingScale, height: imagePixelSize.height / backingScale)
        let fit = min(bounds.width / oneToOneSize.width, bounds.height / oneToOneSize.height)
        minZoom = min(1, max(0.02, fit))
        let clamped = min(1, max(minZoom, zoom))
        if clamped != zoom {
            zoom = clamped
            onZoomChanged?(zoom)
        }
    }

    private func clampOffset() {
        let size = drawSize
        let maxX = max(0, (size.width - bounds.width) / 2) + 40
        let maxY = max(0, (size.height - bounds.height) / 2) + 40
        offset.x = min(maxX, max(-maxX, offset.x))
        offset.y = min(maxY, max(-maxY, offset.y))
    }

    // MARK: - 绘制

    private var drawSize: CGSize {
        guard imagePixelSize.width > 0 else { return .zero }
        return CGSize(width: imagePixelSize.width * pointsPerPixel, height: imagePixelSize.height * pointsPerPixel)
    }

    private var drawOrigin: CGPoint {
        let size = drawSize
        return CGPoint(
            x: (bounds.width - size.width) / 2 + offset.x,
            y: (bounds.height - size.height) / 2 + offset.y
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        background.nsColor.setFill()
        bounds.fill()
        guard let image, imagePixelSize.width > 0 else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // 1:1 或更大时不做插值，像素边界更清楚；缩小时用高质量缩放
        context.interpolationQuality = zoom >= 0.98 ? .none : .high
        let size = drawSize
        let origin = drawOrigin
        let rect = CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height)
        context.draw(image, in: rect)

        // 浅色背景下加一圈细描边，免得白色照片和背景糊在一起
        let borderColor = background.isDark
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(white: 0, alpha: 0.20)
        context.setStrokeColor(borderColor.cgColor)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
    }

    /// 右键：切换大图区域背景色（白 / 浅灰 / 中性灰 / 黑）。
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let title = NSMenuItem(title: "大图背景色", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        for (index, option) in AppBackground.allCases.enumerated() {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(BackgroundMenuTarget.selectBackground(_:)),
                keyEquivalent: ""
            )
            item.target = backgroundMenuTarget
            item.tag = index
            item.state = option == background ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - 缩放与平移

    override func scrollWheel(with event: NSEvent) {
        guard imagePixelSize.width > 0 else { return }
        let raw = event.scrollingDeltaY
        guard raw != 0 else { return }
        let factor = event.hasPreciseScrollingDeltas ? exp(raw * 0.015) : exp(raw * 0.15)
        zoomAt(point: convert(event.locationInWindow, from: nil), factor: factor)
    }

    override func magnify(with event: NSEvent) {
        guard imagePixelSize.width > 0 else { return }
        zoomAt(point: convert(event.locationInWindow, from: nil), factor: 1 + event.magnification)
    }

    private func zoomAt(point: CGPoint, factor: CGFloat) {
        let oldSize = drawSize
        let oldOrigin = drawOrigin
        guard oldSize.width > 0 else { return }
        let relative = CGPoint(
            x: (point.x - oldOrigin.x) / oldSize.width,
            y: (point.y - oldOrigin.y) / oldSize.height
        )

        let target = min(1, max(minZoom, zoom * factor))
        guard abs(target - zoom) > 0.0001 else { return }
        zoom = target

        let newSize = drawSize
        let centered = CGPoint(
            x: (bounds.width - newSize.width) / 2,
            y: (bounds.height - newSize.height) / 2
        )
        offset = CGPoint(
            x: point.x - relative.x * newSize.width - centered.x,
            y: point.y - relative.y * newSize.height - centered.y
        )
        clampOffset()
        needsDisplay = true
        onZoomChanged?(zoom)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // 双击在「1:1 像素」和「适应窗口」之间切换（Lightroom / Bridge 的习惯）
            if zoom >= 0.995 {
                resetToFit()
            } else {
                apply(command: ZoomCommand(kind: .actualSize))
            }
            return
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
        dragStartOffset = offset
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = CGPoint(
            x: dragStartOffset.x + (point.x - dragOrigin.x),
            y: dragStartOffset.y + (point.y - dragOrigin.y)
        )
        clampOffset()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin != nil {
            NSCursor.pop()
        }
        dragOrigin = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

extension PreviewLoader.Preview {
    /// 视图里真正绘制的像素尺寸（方向校正之后）。
    var imagePixelSize: CGSize { orientedPixelSize }
}
