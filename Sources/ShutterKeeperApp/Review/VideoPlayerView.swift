import AVKit
import AppKit
import SwiftUI

/// 内嵌 AVKit 播放器。
///
/// 不使用外部 Preview.app；进度条、播放按钮由 AVKit 提供，
/// 播放/暂停与音量由快捷键接管（需求文档 7.10）。
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickPlayerView {
        let view = DoubleClickPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DoubleClickPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
        view.onDoubleClick = onDoubleClick
    }
}

final class DoubleClickPlayerView: AVPlayerView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }
}
