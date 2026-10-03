import Foundation

/// 旋转一张片子（RAW + JPG 配对时两个都处理）。
///
/// 全部是**非破坏性**的：JPG / TIFF / DNG 改写文件内部的方向标记，
/// RAW 改写同名 `.xmp` 里的 `tiff:Orientation`。像素数据一律不动。
public enum RotateService {
    public struct Outcome: Sendable {
        public var updatedFiles: [URL] = []
        public var updatedSidecars: [URL] = []
        /// 不支持的格式（PNG / HEIC / PSD / 视频等）。
        public var skipped: [(url: URL, reason: String)] = []
        public var errors: [String] = []

        public var succeeded: Bool { errors.isEmpty }
    }

    /// 当前方向标记（1–8）；RAW 读侧车，其它读文件内部 EXIF。
    public static func orientation(of group: AssetGroup) -> Int? {
        for file in group.files {
            switch file.kind {
            case .jpeg, .tiff, .dng:
                if let value = try? OrientationWriter.readOrientation(of: file.url) { return value }
            case .proprietaryRAW:
                if let value = XMPSidecar.readOrientation(for: file) { return value }
            default:
                continue
            }
        }
        return nil
    }

    @discardableResult
    public static func rotate(_ group: AssetGroup, clockwise: Bool) -> Outcome {
        var outcome = Outcome()
        for file in group.files {
            switch file.kind {
            case .jpeg, .tiff, .dng:
                do {
                    let current = (try? OrientationWriter.readOrientation(of: file.url)) ?? nil
                    let next = EXIFOrientation.rotated(current ?? 1, clockwise: clockwise)
                    let wrote = try OrientationWriter.writeOrientation(next, to: file.url)
                    if wrote {
                        outcome.updatedFiles.append(file.url)
                    } else {
                        outcome.skipped.append((file.url, "文件里没有方向标记"))
                    }
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            case .proprietaryRAW:
                do {
                    let current = XMPSidecar.readOrientation(for: file) ?? 1
                    let next = EXIFOrientation.rotated(current, clockwise: clockwise)
                    try XMPSidecar.writeOrientation(next, for: file)
                    outcome.updatedSidecars.append(file.sidecarURL)
                } catch {
                    outcome.errors.append(error.localizedDescription)
                }
            case .png:
                outcome.skipped.append((file.url, "PNG 没有方向标记，旋转需要重新编码"))
            case .heic:
                outcome.skipped.append((file.url, "HEIC 首版不支持写入"))
            case .psd:
                outcome.skipped.append((file.url, "PSD 首版不支持写入"))
            case .otherImage:
                outcome.skipped.append((file.url, "这个格式不支持写入方向标记"))
            case .video:
                outcome.skipped.append((file.url, "视频不旋转"))
            case .other:
                continue
            }
        }
        return outcome
    }
}
