import Foundation

/// 把 Lightroom 目录里的星级同步到文件（或只做预览）。
public enum LightroomSync {
    public struct Update: Sendable {
        public let group: AssetGroup
        public let rating: Int
        public let currentRating: Int?
    }

    public struct Plan: Sendable {
        public var updates: [Update] = []
        /// 文件里已经是这个星级，不需要动。
        public var alreadyMatching = 0
        /// Lightroom 目录里没有这张（未导入或未评分）。
        public var notInCatalog = 0
        public var total = 0

        public var hasChanges: Bool { !updates.isEmpty }
    }

    /// 对比「文件夹里的片子」与「Lightroom 目录里的星级」，得出需要动哪些。
    public static func plan(groups: [AssetGroup], catalogRatings: [String: Int]) -> Plan {
        var plan = Plan()
        plan.total = groups.count
        for group in groups {
            guard group.isRatable else { continue }
            guard let catalogRating = catalogRating(for: group, in: catalogRatings) else {
                plan.notInCatalog += 1
                continue
            }
            let current = RatingService.readRatingFromFiles(for: group)
            if current == catalogRating {
                plan.alreadyMatching += 1
                continue
            }
            plan.updates.append(Update(group: group, rating: catalogRating, currentRating: current))
        }
        return plan
    }

    /// 找出这张片子在目录里对应的星级：按配对组内任意一个文件的绝对路径匹配。
    static func catalogRating(for group: AssetGroup, in catalogRatings: [String: Int]) -> Int? {
        for file in group.files {
            let path = file.url.standardizedFileURL.path
            if let rating = catalogRatings[path] {
                return rating
            }
        }
        return nil
    }

    /// 真正写盘：RAW 写 `.xmp` 侧车，JPG 写文件内部元数据。
    @discardableResult
    public static func apply(
        plan: Plan,
        progress: ((Int, Int) -> Void)? = nil
    ) -> RatingWriteOutcome {
        var outcome = RatingWriteOutcome()
        for (index, update) in plan.updates.enumerated() {
            progress?(index, plan.updates.count)
            let result = RatingService.write(rating: update.rating, to: update.group)
            outcome.writtenFiles.append(contentsOf: result.writtenFiles)
            outcome.databaseOnlyFiles.append(contentsOf: result.databaseOnlyFiles)
            outcome.skippedFiles.append(contentsOf: result.skippedFiles)
            outcome.errors.append(contentsOf: result.errors)
        }
        progress?(plan.updates.count, plan.updates.count)
        return outcome
    }
}
