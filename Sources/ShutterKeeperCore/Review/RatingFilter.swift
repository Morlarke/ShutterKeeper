import Foundation

/// 星级筛选条件。
public struct RatingFilter: Equatable, Sendable {
    public enum Comparison: String, CaseIterable, Identifiable, Codable, Sendable {
        case atLeast
        case atMost
        case exactly

        public var id: String { rawValue }

        public var symbol: String {
            switch self {
            case .atLeast: return "≥"
            case .atMost: return "≤"
            case .exactly: return "="
            }
        }

        public var displayName: String {
            switch self {
            case .atLeast: return "大于或等于"
            case .atMost: return "小于或等于"
            case .exactly: return "等于"
            }
        }
    }

    /// 关闭筛选时一律显示全部。
    public var isActive: Bool
    public var comparison: Comparison
    public var stars: Int

    public init(isActive: Bool = false, comparison: Comparison = .atLeast, stars: Int = 0) {
        self.isActive = isActive
        self.comparison = comparison
        self.stars = max(0, min(5, stars))
    }

    public static let inactive = RatingFilter()

    public func matches(_ rating: Int?) -> Bool {
        guard isActive else { return true }
        let value = rating ?? 0
        switch comparison {
        case .atLeast: return value >= stars
        case .atMost: return value <= stars
        case .exactly: return value == stars
        }
    }

    public var summary: String {
        isActive ? "\(comparison.symbol)\(stars) 星" : "全部"
    }
}
