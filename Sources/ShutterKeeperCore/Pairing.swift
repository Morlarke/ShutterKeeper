import Foundation

/// RAW + JPG 配对逻辑。
///
/// 规则：同一文件夹内、主文件名相同（忽略大小写）的照片文件归为一张。
/// 视频单独成组，不与同名照片合并（避免 Live Photo 之类的误合并）。
public enum Pairing {
    public enum Family {
        case photo
        case video

        public var key: String {
            switch self {
            case .photo: return "p"
            case .video: return "v"
            }
        }
    }

    public static func family(for kind: MediaKind) -> Family {
        kind == .video ? .video : .photo
    }

    /// 把一批文件按配对规则分组。返回结果按 `sortKey` 排序。
    public static func group(_ files: [FileRef]) -> [AssetGroup] {
        var buckets: [String: [FileRef]] = [:]
        var order: [String] = []

        for file in files {
            guard !MediaTypes.isSidecar(pathExtension: file.fileExtension) else { continue }
            guard file.kind != .other else { continue }
            let key = "\(file.directory.standardizedFileURL.path)#\(family(for: file.kind).key)#\(file.baseName.lowercased())"
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(file)
        }

        let groups: [AssetGroup] = order.compactMap { key in
            guard let members = buckets[key], let first = members.first else { return nil }
            let sorted = members.sorted { lhs, rhs in
                // 组内顺序固定：预览文件优先，其余按扩展名排序，保证结果稳定。
                if lhs.kind == rhs.kind { return lhs.fileExtension < rhs.fileExtension }
                return kindRank(lhs.kind) < kindRank(rhs.kind)
            }
            return AssetGroup(folder: first.directory, baseName: preferredBaseName(sorted), files: sorted)
        }

        return groups.sorted { $0.sortKey < $1.sortKey }
    }

    private static func kindRank(_ kind: MediaKind) -> Int {
        switch kind {
        case .jpeg: return 0
        case .tiff: return 1
        case .png: return 2
        case .heic: return 3
        case .dng: return 4
        case .proprietaryRAW: return 5
        case .video: return 6
        case .psd: return 7
        case .otherImage: return 8
        case .other: return 9
        }
    }

    /// 展示基名优先取 RAW/DNG，其次是 JPG，最后视频。
    private static func preferredBaseName(_ files: [FileRef]) -> String {
        for kind in [MediaKind.proprietaryRAW, .dng, .jpeg, .tiff, .png, .heic, .psd, .otherImage, .video] {
            if let match = files.first(where: { $0.kind == kind }) {
                return match.baseName
            }
        }
        return files.first?.baseName ?? ""
    }
}
