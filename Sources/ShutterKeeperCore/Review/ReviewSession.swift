import Foundation

/// 按拍摄日期分出来的一组（用于上下方向键跳组、以及界面上的日期分隔）。
public struct DateGroup: Identifiable, Sendable {
    public let id: String
    public let date: Date?
    public let title: String
    /// 在「当前可见列表」中的下标范围。
    public let range: Range<Int>

    public var count: Int { range.count }
}

/// 审阅模块的状态机。
///
/// 只做纯逻辑：过滤、选中、导航、日期分组、删除后的落点。
/// 不碰界面，也不碰文件，方便单独验证。
public struct ReviewSession: Sendable {
    public private(set) var groups: [AssetGroup]
    public private(set) var ratings: [String: Int]
    public var filter: RatingFilter
    public private(set) var currentID: String?

    public init(groups: [AssetGroup], ratings: [String: Int] = [:], filter: RatingFilter = .inactive) {
        self.groups = groups
        self.ratings = ratings
        self.filter = filter
        self.currentID = groups.first?.id
        self.currentID = firstVisibleID(preferring: currentID)
    }

    // MARK: - 列表

    public var visibleGroups: [AssetGroup] {
        guard filter.isActive else { return groups }
        return groups.filter { filter.matches(ratings[$0.id]) }
    }

    public var visibleCount: Int { visibleGroups.count }

    public var current: AssetGroup? {
        guard let currentID else { return nil }
        return groups.first { $0.id == currentID }
    }

    public var currentVisibleIndex: Int? {
        guard let currentID else { return nil }
        return visibleGroups.firstIndex { $0.id == currentID }
    }

    public func rating(for group: AssetGroup) -> Int? {
        ratings[group.id]
    }

    public var currentRating: Int? {
        current.flatMap { ratings[$0.id] }
    }

    // MARK: - 选中与导航

    public mutating func select(id: String?) {
        guard let id, groups.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    public mutating func selectVisible(index: Int) {
        let visible = visibleGroups
        guard visible.indices.contains(index) else { return }
        currentID = visible[index].id
    }

    /// 左右方向键：在可见列表里上下移动。
    public mutating func selectNext() {
        step(by: 1)
    }

    public mutating func selectPrevious() {
        step(by: -1)
    }

    private mutating func step(by delta: Int) {
        let visible = visibleGroups
        guard !visible.isEmpty else {
            currentID = nil
            return
        }
        guard let index = currentVisibleIndex else {
            currentID = visible.first?.id
            return
        }
        let target = index + delta
        guard visible.indices.contains(target) else { return }
        currentID = visible[target].id
    }

    /// 上下方向键（照片时）：跳到上/下一个日期分组的第一张。
    public mutating func selectNextDateGroup() {
        jumpDateGroup(by: 1)
    }

    public mutating func selectPreviousDateGroup() {
        jumpDateGroup(by: -1)
    }

    private mutating func jumpDateGroup(by delta: Int) {
        let groups = dateGroups
        guard !groups.isEmpty,
              let index = currentVisibleIndex,
              let currentGroupIndex = groups.firstIndex(where: { $0.range.contains(index) }) else { return }
        let target = currentGroupIndex + delta
        guard groups.indices.contains(target) else { return }
        selectVisible(index: groups[target].range.lowerBound)
    }

    public var dateGroups: [DateGroup] {
        var result: [DateGroup] = []
        var index = 0
        for group in visibleGroups {
            if let last = result.last, sameDay(last.date, group.captureDate) {
                result[result.count - 1] = DateGroup(
                    id: last.id,
                    date: last.date,
                    title: last.title,
                    range: last.range.lowerBound..<(index + 1)
                )
            } else {
                let date = group.captureDate
                result.append(
                    DateGroup(
                        id: date.map { Self.dayIdentifier(for: $0) } ?? "unknown",
                        date: date,
                        title: Self.title(for: date),
                        range: index..<(index + 1)
                    )
                )
            }
            index += 1
        }
        return result
    }

    /// 当前照片属于第几个日期组（从 1 开始，给界面显示用）。
    public var currentDateGroupPosition: Int? {
        guard let index = currentVisibleIndex else { return nil }
        return dateGroups.firstIndex { $0.range.contains(index) }.map { $0 + 1 }
    }

    // MARK: - 打分与筛选

    public mutating func setRating(_ rating: Int, for groupID: String) {
        ratings[groupID] = max(0, min(5, rating))
    }

    public mutating func applyFilter(_ newFilter: RatingFilter) {
        let previousIndex = currentVisibleIndex
        filter = newFilter
        guard filter.isActive else { return }
        if let currentID, visibleGroups.contains(where: { $0.id == currentID }) {
            return
        }
        // 当前这张被筛掉了：跳到下一张符合的（没有就退到上一张）
        let visible = visibleGroups
        guard !visible.isEmpty else {
            self.currentID = nil
            return
        }
        if let previousIndex, visible.indices.contains(previousIndex) {
            currentID = visible[previousIndex].id
        } else {
            currentID = visible.last?.id
        }
    }

    // MARK: - 删除

    /// 删除后把选中项落到「原位置的那一张」，没有就退到上一张。
    @discardableResult
    public mutating func removeCurrent() -> AssetGroup? {
        guard let currentID, let removeIndex = groups.firstIndex(where: { $0.id == currentID }) else { return nil }
        let visibleIndexBefore = currentVisibleIndex
        let removed = groups.remove(at: removeIndex)
        ratings.removeValue(forKey: removed.id)
        self.currentID = nil
        let visible = visibleGroups
        guard !visible.isEmpty else { return removed }
        if let visibleIndexBefore {
            self.currentID = visible[min(visibleIndexBefore, visible.count - 1)].id
        } else {
            self.currentID = visible.first?.id
        }
        return removed
    }

    // MARK: - 重新载入

    public mutating func reload(groups: [AssetGroup], ratings: [String: Int], keepingSelection: Bool = true) {
        let previousSelection = keepingSelection ? currentID : nil
        self.groups = groups
        self.ratings = ratings
        if let previousSelection, groups.contains(where: { $0.id == previousSelection }) {
            currentID = previousSelection
        } else {
            currentID = firstVisibleID(preferring: nil)
        }
    }

    private func firstVisibleID(preferring id: String?) -> String? {
        let visible = visibleGroups
        guard !visible.isEmpty else { return nil }
        if let id, visible.contains(where: { $0.id == id }) { return id }
        return visible.first?.id
    }

    private func sameDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (lhs?, rhs?): return Calendar.current.isDate(lhs, inSameDayAs: rhs)
        }
    }

    public static func title(for date: Date?) -> String {
        guard let date else { return "无拍摄时间" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 EEEE"
        return formatter.string(from: date)
    }

    public static func dayIdentifier(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
