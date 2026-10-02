import Foundation

/// 一个可导入的来源卷（SD 卡 / 读卡器挂载的宗卷）。
public struct SourceVolume: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let name: String
    public let isRemovable: Bool
    public let isEjectable: Bool
    /// 卷里的 DCIM 目录（有的话）。
    public let dcimFolders: [URL]

    public var hasMedia: Bool { !dcimFolders.isEmpty }

    /// 外接设备（U 盘、读卡器、外置硬盘）通常是「可推出」的；内置硬盘不是。
    public var isExternal: Bool { isEjectable || isRemovable }

    public var badgeText: String {
        if hasMedia { return "DCIM" }
        return isExternal ? "外接设备" : "内置"
    }
}

public extension Array where Element == SourceVolume {
    /// 优先选：有 DCIM 的外接设备 → 有 DCIM 的卷 → 其它外接设备 → 第一个卷。
    var preferredSource: SourceVolume? {
        first { $0.hasMedia && $0.isExternal }
            ?? first { $0.hasMedia }
            ?? first { $0.isExternal }
            ?? first
    }
}

/// 找出可以导入的卷与里面的素材。
public enum VolumeScanner {
    /// 挂载在 /Volumes 下的卷（跳过系统卷与隐藏卷）。
    public static func mountedVolumes() -> [SourceVolume] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
            .volumeIsBrowsableKey, .isHiddenKey, .volumeIsInternalKey,
        ]
        let candidates = (try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []

        var result: [SourceVolume] = []
        for url in candidates {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isHidden == true { continue }
            if values.volumeIsBrowsable == false { continue }
            // /Volumes/Macintosh HD 这类指向系统盘的符号链接不是导入来源
            if url.resolvingSymlinksInPath().standardizedFileURL.path == "/" { continue }
            let name = values.volumeName ?? url.lastPathComponent
            result.append(
                SourceVolume(
                    url: url,
                    name: name,
                    isRemovable: values.volumeIsRemovable ?? false,
                    isEjectable: values.volumeIsEjectable ?? false,
                    dcimFolders: dcimFolders(in: url)
                )
            )
        }
        return result.sorted { lhs, rhs in
            // 可移动卷排前面，其次按名字
            if lhs.isRemovable != rhs.isRemovable { return lhs.isRemovable }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 卷里的 DCIM 目录（相机卡的标准结构）。
    public static func dcimFolders(in volume: URL) -> [URL] {
        let fileManager = FileManager.default
        let dcim = volume.appendingPathComponent("DCIM", isDirectory: true)
        guard fileManager.fileExists(atPath: dcim.path) else { return [] }
        let contents = (try? fileManager.contentsOfDirectory(
            at: dcim,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let subfolders = contents.filter { item in
            (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        return (subfolders.isEmpty ? [dcim] : subfolders)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 扫描一个来源（卷或者任意文件夹），找出所有素材文件。
    ///
    /// 相机卡的目录通常只有两级（DCIM/100CANON），但为了兼容把文件直接放在根目录的卡，
    /// 这里做有限深度（默认 3 层）的遍历，并跳过系统目录。
    public static func mediaFiles(in source: URL, maxDepth: Int = 3) -> [URL] {
        let fileManager = FileManager.default
        let skipped: Set<String> = [
            ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", "System Volume Information",
        ]
        var results: [URL] = []
        var frontier: [(url: URL, depth: Int)] = [(source, 0)]

        while !frontier.isEmpty {
            let (directory, depth) = frontier.removeFirst()
            let items = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for item in items {
                guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { continue }
                if values.isDirectory == true {
                    if skipped.contains(item.lastPathComponent) { continue }
                    if depth < maxDepth { frontier.append((item, depth + 1)) }
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let kind = MediaTypes.kind(for: item)
                let sidecar = MediaTypes.isSidecarFile(item.pathExtension)
                guard kind != .other || sidecar else { continue }
                results.append(item)
            }
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// 卷的剩余空间。
    ///
    /// 优先用 `attributesOfFileSystem`（在临时目录、网络卷上都可靠），
    /// 拿不到再退回卷资源键。
    public static func freeSpace(of url: URL) -> Int64? {
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
           let size = attributes[.systemFreeSize] as? NSNumber {
            return size.int64Value
        }
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let capacity = values?.volumeAvailableCapacity { return Int64(capacity) }
        return nil
    }

    /// 判断一个来源属于哪个卷：`/Volumes/<卷名>/...` 归到卷，其它情况用文件夹本身当一卷。
    ///
    /// 返回值里的 root 用来算相对路径，导入历史靠「卷 + 相对路径 + 文件名 + 大小」判断是否重复导入。
    public static func volumeIdentity(for source: URL) -> (name: String, root: URL) {
        let standardized = source.standardizedFileURL
        let components = standardized.pathComponents
        if components.count >= 2, components[1] == "Volumes", components.count >= 3 {
            let name = components[2]
            return (name, URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true))
        }
        return (standardized.lastPathComponent, standardized)
    }

    /// 相对来源根目录的路径（不含文件名）。
    public static func relativePath(of url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.deletingLastPathComponent().lastPathComponent }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return (relative as NSString).deletingLastPathComponent
    }
}
