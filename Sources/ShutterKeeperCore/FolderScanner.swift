import Foundation

public struct FolderScanResult: Sendable {
    public let folder: URL
    public var groups: [AssetGroup]
    /// 忽略掉的文件（隐藏文件、`.xmp`、`.aae` 等附属文件、不支持的格式）。
    public var ignoredFiles: [URL]
}

/// 扫描文件夹，产出「一张片子」列表。
public enum FolderScanner {
    /// 扫描时直接忽略的扩展名：这些是附属文件，不是素材。
    static let ignoredExtensions: Set<String> = ["aae", "thm", "lrv", "xmp", "db", "tmp", "ds_store"]

    /// 只列出子文件夹（用于文件夹面板与「空文件夹但有下级」的提示）。
    public static func subfolders(of url: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        return contents
            .filter { item in
                guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return false }
                return values.isDirectory == true && values.isHidden != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public static func scan(
        folder: URL,
        includeSubfolders: Bool = false,
        readMetadata: Bool = true,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> FolderScanResult {
        let fileManager = FileManager.default
        var files: [FileRef] = []
        var ignored: [URL] = []

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .isHiddenKey,
        ]
        let enumeratorOptions: FileManager.DirectoryEnumerationOptions = includeSubfolders
            ? [.skipsHiddenFiles, .skipsPackageDescendants]
            : [.skipsHiddenFiles, .skipsPackageDescendants]

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: enumeratorOptions
        ) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            if !includeSubfolders, url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            if values?.isHidden == true { continue }

            let ext = url.pathExtension.lowercased()
            guard !ignoredExtensions.contains(ext) else {
                ignored.append(url)
                continue
            }
            let kind = MediaTypes.kind(forPathExtension: ext)
            guard kind != .other else {
                ignored.append(url)
                continue
            }
            files.append(
                FileRef(
                    url: url,
                    kind: kind,
                    fileSize: values?.fileSize.map(Int64.init),
                    modificationDate: values?.contentModificationDate,
                    creationDate: values?.creationDate
                )
            )
        }

        var groups = Pairing.group(files)

        if readMetadata {
            for index in groups.indices {
                progress?(index, groups.count)
                enrich(&groups[index])
            }
        }
        progress?(groups.count, groups.count)

        groups.sort { $0.sortKey < $1.sortKey }
        return FolderScanResult(folder: folder, groups: groups, ignoredFiles: ignored)
    }

    /// 填入拍摄日期并刷新排序键。
    public static func enrich(_ group: inout AssetGroup) {
        let date = captureDate(for: group)
        group.captureDate = date
        group.sortKey = AssetGroup.makeSortKey(captureDate: date, baseName: group.baseName)
    }

    /// 拍摄日期：照片读 EXIF；视频没有 EXIF 时用文件创建日期。
    public static func captureDate(for group: AssetGroup) -> Date? {
        if let preview = group.previewFile, preview.kind != .video {
            if let metadata = try? ExifReader.read(url: preview.url), let date = metadata.captureDate {
                return date
            }
            // RAW 没有 EXIF 时，退到同组另外的成员再试一次
            for file in group.files where file.kind != .video {
                if let metadata = try? ExifReader.read(url: file.url), let date = metadata.captureDate {
                    return date
                }
            }
        }
        if let video = group.video {
            return ExifReader.fileSystemFallback(for: video.url)
        }
        return group.files.compactMap(\.creationDate).min()
    }
}
