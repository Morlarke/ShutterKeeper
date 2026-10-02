import Foundation

/// 一张片子的元数据快照。字段对应 EXIF 面板要展示的内容。
public struct PhotoMetadata: Codable, Sendable, Hashable {
    public var captureDate: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var iso: Int?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var focalLength: Double?
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var orientation: Int?
    public var rating: Int?
    public var duration: Double?

    public init(
        captureDate: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        iso: Int? = nil,
        fNumber: Double? = nil,
        exposureTime: Double? = nil,
        focalLength: Double? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        orientation: Int? = nil,
        rating: Int? = nil,
        duration: Double? = nil
    ) {
        self.captureDate = captureDate
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.iso = iso
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.focalLength = focalLength
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.orientation = orientation
        self.rating = rating
        self.duration = duration
    }
}

public enum MetadataFormatting {
    /// 光圈：f/2.8
    public static func aperture(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return String(format: "f/%.1f", value)
    }

    /// 快门：1/500 s；超过 1 秒显示 2.5 s。
    public static func shutter(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 1 {
            return String(format: "%.1f s", seconds)
        }
        return "1/\(Int((1 / seconds).rounded())) s"
    }

    public static func focalLength(_ value: Double?) -> String? {
        guard let value, value > 0 else { return nil }
        return "\(Int(value.rounded())) mm"
    }

    public static func iso(_ value: Int?) -> String? {
        guard let value, value > 0 else { return nil }
        return "ISO \(value)"
    }

    public static func dimensions(_ metadata: PhotoMetadata) -> String? {
        guard let w = metadata.pixelWidth, let h = metadata.pixelHeight else { return nil }
        return "\(w) × \(h)"
    }

    public static func duration(_ seconds: Double?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    public static func date(_ date: Date?, dateFormat: String = "yyyy-MM-dd HH:mm:ss") -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter.string(from: date)
    }
}
