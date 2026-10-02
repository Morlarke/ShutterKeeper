import Foundation

/// 快捷键存储：默认值来自需求文档，用户改动持久化在 UserDefaults 里。
public final class ShortcutStore {
    /// 全应用共用一份，保证设置界面与按键分发读到的是一致的。
    public static let shared = ShortcutStore()

    public enum StoreError: Error, LocalizedError {
        case conflict(ShortcutConflict)

        public var errorDescription: String? {
            switch self {
            case .conflict(let conflict):
                return "\(conflict.shortcut.displayString) 已被「\(conflict.action.displayName)」占用"
            }
        }
    }

    private let defaults: UserDefaults
    private let storageKey = "shortcuts.overrides.v1"
    private var overrides: [String: KeyShortcut]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            self.overrides = decoded
        } else {
            self.overrides = [:]
        }
    }

    // MARK: - 读写

    public func shortcut(for action: ShortcutAction) -> KeyShortcut {
        overrides[action.rawValue] ?? action.defaultShortcut
    }

    public func isCustomized(_ action: ShortcutAction) -> Bool {
        overrides[action.rawValue] != nil
    }

    /// 找出会与此组合冲突的其它操作。只有在场景重叠时才算冲突。
    public func conflict(for candidate: KeyShortcut, excluding action: ShortcutAction) -> ShortcutConflict? {
        for other in ShortcutAction.allCases where other != action {
            guard shortcut(for: other) == candidate else { continue }
            guard other.context.matches(action.context) else { continue }
            return ShortcutConflict(action: other, shortcut: candidate)
        }
        return nil
    }

    /// 设置快捷键。有冲突时抛错，由界面询问用户是否覆盖。
    public func set(_ candidate: KeyShortcut, for action: ShortcutAction, force: Bool = false) throws {
        if !force, let conflict = conflict(for: candidate, excluding: action) {
            throw StoreError.conflict(conflict)
        }
        if force {
            // 覆盖：把冲突项也改成新组合以外的默认值，避免两处重名
            if let existing = conflict(for: candidate, excluding: action) {
                overrides.removeValue(forKey: existing.action.rawValue)
            }
        }
        if candidate == action.defaultShortcut {
            overrides.removeValue(forKey: action.rawValue)
        } else {
            overrides[action.rawValue] = candidate
        }
        persist()
    }

    public func reset(_ action: ShortcutAction) {
        overrides.removeValue(forKey: action.rawValue)
        persist()
    }

    public func resetAll() {
        overrides.removeAll()
        persist()
    }

    public var customizedActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { overrides[$0.rawValue] != nil }
    }

    // MARK: - 事件匹配

    /// 根据当前场景找出该按下的组合对应哪个操作。
    ///
    /// 场景越具体的规则优先：视频播放时按空格是播放/暂停，而不是照片全屏。
    public func action(for candidate: KeyShortcut, context: ShortcutContext) -> ShortcutAction? {
        let candidates = ShortcutAction.allCases.filter { action in
            shortcut(for: action) == candidate && action.context.matches(context)
        }
        return candidates.sorted { lhs, rhs in
            specificity(lhs.context) > specificity(rhs.context)
        }.first
    }

    private func specificity(_ context: ShortcutContext) -> Int {
        context == .any ? 0 : 1
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
