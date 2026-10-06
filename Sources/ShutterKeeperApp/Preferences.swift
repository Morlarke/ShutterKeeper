import ShutterKeeperCore
import SwiftUI

/// 偏好设置的存储键。全部存在 UserDefaults 里，跟着 App 走。
enum PrefKey {
    static let dateFormat = "dateFormat"
    static let backupPath = "backupPath"
    static let cacheLocation = "cacheLocation"
    static let background = "background"
    static let exifPanelVisible = "exifPanelVisible"
    static let exifFields = "exifFields"
    static let copyToBackup = "copyToBackup"
    static let rawFileExtensions = "rawFileExtensions"
    /// 是否自动读取 Lightroom 目录里的星级（Lightroom 默认不写文件，需要它才能看到分）
    static let readLightroomRatings = "readLightroomRatings"
    /// 记住用过的 Lightroom 目录文件
    static let lightroomCatalogPath = "lightroomCatalogPath"
    /// 文件夹面板是否展开（记住上次状态）
    static let folderPanelVisible = "folderPanelVisible"
    /// 批量改名的序列号位数
    static let sequenceDigits = "sequenceDigits"
    /// 最近一次导入的目标文件夹（改名模块默认进这里）
    static let lastImportedFolder = "lastImportedFolder"
    /// 导入的目标父目录
    static let importDestinationRoot = "importDestinationRoot"
    /// 改名模块分栏视图的列宽
    static let renameColumnWidth = "renameColumnWidth"
}

/// 日期格式选项：导入建文件夹与批量改名共用。
enum DateFormatOption: String, CaseIterable, Identifiable {
    case compact = "yyyymmdd"
    case dashed = "yyyy-MM-dd"
    case underscored = "yyyy_MM_dd"
    case dashedCompact = "yyyyMMdd-HHmmss"

    var id: String { rawValue }
    var displayName: String {
        if self == .dashedCompact { return rawValue + "（含时间）" }
        return rawValue
    }
}

/// EXIF 面板可显示的字段。
enum ExifField: String, CaseIterable, Identifiable {
    case fileName
    case captureDate
    case camera
    case lens
    case iso
    case aperture
    case shutter
    case focalLength
    case dimensions

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fileName: return "文件名"
        case .captureDate: return "拍摄时间"
        case .camera: return "相机型号"
        case .lens: return "镜头型号"
        case .iso: return "ISO"
        case .aperture: return "光圈"
        case .shutter: return "快门"
        case .focalLength: return "焦距"
        case .dimensions: return "尺寸"
        }
    }

    static var defaultSelection: [ExifField] { allCases }

    static func decode(_ string: String) -> Set<ExifField> {
        let parts = string.split(separator: ",").map(String.init)
        let fields = parts.compactMap { ExifField(rawValue: $0) }
        return fields.isEmpty ? Set(defaultSelection) : Set(fields)
    }

    static func encode(_ fields: Set<ExifField>) -> String {
        ExifField.allCases.filter { fields.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}
