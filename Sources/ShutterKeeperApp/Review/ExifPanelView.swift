import ShutterKeeperCore
import SwiftUI

/// 右侧 EXIF 信息面板（P 键切换）。显示项可在偏好设置里勾选。
struct ExifPanelView: View {
    let group: AssetGroup?
    let metadata: PhotoMetadata?
    let rating: Int?
    let fields: Set<ExifField>
    let theme: AppTheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let group {
                    fileSection(group)
                    exifSection(group)
                } else {
                    Text("没有选中的照片")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.secondaryText)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 268)
        .background(theme.panelBackground.opacity(0.45))
    }

    // MARK: - 文件

    private func fileSection(_ group: AssetGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "文件", theme: theme)
            if fields.contains(.fileName) {
                row("文件名", group.displayName, monospaced: false)
            }
            if group.isPaired {
                ForEach(group.files, id: \.url) { file in
                    row(file.fileExtension.uppercased(), file.fileName, monospaced: false, secondary: true)
                }
            }
            if !group.databaseOnlyTargets.isEmpty {
                let names = Set(group.databaseOnlyTargets.map { $0.fileExtension.uppercased() }).sorted().joined(separator: " / ")
                Text("\(names)：星级只记在软件内，不写入文件")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            if group.isVideo {
                Text("视频不打分")
                    .font(.system(size: 10.5))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    // MARK: - EXIF

    private func exifSection(_ group: AssetGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "EXIF", theme: theme)
            if let metadata {
                if fields.contains(.captureDate), let text = MetadataFormatting.date(metadata.captureDate) {
                    row("拍摄时间", text)
                }
                if fields.contains(.camera), let text = cameraText(metadata) {
                    row("相机", text)
                }
                if fields.contains(.lens), let text = metadata.lensModel {
                    row("镜头", text)
                }
                if fields.contains(.iso), let text = MetadataFormatting.iso(metadata.iso) {
                    row("ISO", text)
                }
                if fields.contains(.aperture), let text = MetadataFormatting.aperture(metadata.fNumber) {
                    row("光圈", text)
                }
                if fields.contains(.shutter), let text = MetadataFormatting.shutter(metadata.exposureTime) {
                    row("快门", text)
                }
                if fields.contains(.focalLength), let text = MetadataFormatting.focalLength(metadata.focalLength) {
                    row("焦距", text)
                }
                if fields.contains(.dimensions), let text = MetadataFormatting.dimensions(metadata) {
                    row("尺寸", text)
                }
                if let duration = MetadataFormatting.duration(metadata.duration) {
                    row("时长", duration)
                }
                if let rating {
                    row("星级", "\(rating) 星")
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在读取…")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
            }
        }
    }

    private func cameraText(_ metadata: PhotoMetadata) -> String? {
        let parts = [metadata.cameraMake, metadata.cameraModel].compactMap { $0 }
        let text = parts.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    private func row(_ label: String, _ value: String, monospaced: Bool = true, secondary: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(theme.secondaryText)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 11.5, design: monospaced ? .monospaced : .default))
                .foregroundStyle(secondary ? theme.secondaryText : theme.primaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
