import Foundation

/// 修饰键（不依赖 AppKit，方便核心层测试）。
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let command = ShortcutModifiers(rawValue: 1 << 0)
    public static let shift = ShortcutModifiers(rawValue: 1 << 1)
    public static let option = ShortcutModifiers(rawValue: 1 << 2)
    public static let control = ShortcutModifiers(rawValue: 1 << 3)
}

/// 一个按键组合。
public struct KeyShortcut: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ShortcutModifiers

    public init(keyCode: UInt16, modifiers: ShortcutModifiers = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 展示用文本，例如「⌘⌥1」「空格」「←」。
    public var displayString: String {
        let name = KeyCodeNames.name(for: keyCode) ?? "键码\(keyCode)"
        return modifierSymbols + name
    }

    public var modifierSymbols: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }
}

/// macOS 虚拟键码名称表。覆盖默认快捷键用到的键以及常见可重绑的键。
public enum KeyCodeNames {
    private static let table: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "回车", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
        42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "空格",
        50: "`", 51: "⌫", 53: "Esc", 65: "小键盘.", 67: "小键盘*", 69: "小键盘+",
        71: "小键盘清除", 75: "小键盘/", 76: "小键盘回车", 78: "小键盘-", 81: "小键盘=",
        82: "小键盘0", 83: "小键盘1", 84: "小键盘2", 85: "小键盘3", 86: "小键盘4",
        87: "小键盘5", 88: "小键盘6", 89: "小键盘7", 91: "小键盘8", 92: "小键盘9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "帮助", 115: "Home", 116: "Page Up", 117: "⌦", 118: "F4", 119: "End",
        120: "F2", 121: "Page Down", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    public static func name(for keyCode: UInt16) -> String? {
        table[keyCode]
    }

    /// 便于设置界面列举可绑定的按键。
    public static var allKeyCodes: [UInt16] {
        table.keys.sorted()
    }
}
