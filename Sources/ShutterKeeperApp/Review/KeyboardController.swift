import AppKit
import ShutterKeeperCore

extension ShortcutModifiers {
    /// 把 AppKit 的修饰键翻译成核心层用的位标记（忽略 Caps Lock / Fn 等）。
    init(_ flags: NSEvent.ModifierFlags) {
        var value: ShortcutModifiers = []
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
}

/// 全局快捷键分发。
///
/// 用本地事件监听而不是 SwiftUI 的 keyboardShortcut，
/// 因为需求里既有单键（0–5、P、空格、Del）也有组合键，还要求可自定义与冲突检测。
@MainActor
final class KeyboardController: ObservableObject {
    private var monitor: Any?
    private let store: ShortcutStore

    /// 交给审阅模块处理；返回 true 表示已消费这次按键。
    var onAction: ((ShortcutAction) -> Bool)?
    /// 当前场景：视频还是照片（决定空格与上下方向键的含义）。
    var contextProvider: (() -> ShortcutContext)?
    var onNextModule: (() -> Void)?
    var onPreviousModule: (() -> Void)?
    /// Esc：返回 true 表示消费掉（例如退出了全屏）。
    var onEscape: (() -> Bool)?

    init(store: ShortcutStore = .shared) {
        self.store = store
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    /// 正在输入文字时不要抢按键（例如手动输入项目名、自定义文本框）。
    private var isTyping: Bool {
        if let responder = NSApp.keyWindow?.firstResponder {
            if let textView = responder as? NSTextView, textView.isEditable { return true }
            if let textField = responder as? NSTextField, textField.isEditable { return true }
        }
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView { return true }
        return false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: ShortcutModifiers(event.modifierFlags))

        if isTyping {
            // 正在输入文字：单键留给输入框；⌘Z / ⌘X / ⌘C / ⌘V / ⌘A 也留给输入框，
            // 但 ⌘1、⌘2、⌘0 这类与文字编辑无关的组合键照常生效。
            guard shortcut.modifiers.contains(.command) else { return event }
            if Self.textEditingKeyCodes.contains(shortcut.keyCode) { return event }
        }

        if shortcut == ShortcutAction.nextModule {
            onNextModule?()
            return nil
        }
        if shortcut == ShortcutAction.previousModule {
            onPreviousModule?()
            return nil
        }
        if event.keyCode == 53 {  // Esc
            if onEscape?() == true { return nil }
            return event
        }
        let context = contextProvider?() ?? .photo
        guard let action = store.action(for: shortcut, context: context) else { return event }
        return onAction?(action) == true ? nil : event
    }

    /// 与文字编辑冲突的按键（撤销、剪切、拷贝、粘贴、全选）。
    private static let textEditingKeyCodes: Set<UInt16> = [6, 7, 8, 9, 0]
}
