#!/usr/bin/env swift
//
// 把一张方形 PNG 加工成 macOS 应用图标（.icns）。
//
//   swift Scripts/make-icon.swift <输入.png> <输出.icns>
//
// 做三件事：
// 1. 找出画面内容的外接矩形，裁掉四周多余的背景
// 2. 按 macOS 图标的圆角比例（22.37%）裁成圆角方块，四角透明
// 3. 生成 iconset 并调用 iconutil 打包成 .icns

import AppKit
import CoreGraphics
import Foundation
import ImageIO

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("用法：swift Scripts/make-icon.swift <输入.png> <输出.icns>")
    exit(2)
}

let inputURL = URL(fileURLWithPath: arguments[1])
let outputURL = URL(fileURLWithPath: arguments[2])

guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("读不到图片：\(inputURL.path)")
    exit(1)
}

let width = image.width
let height = image.height

// MARK: - 1. 找出内容边界（与四角背景色差别明显的区域）

let analysisWidth = 256
let analysisHeight = max(1, analysisWidth * height / width)
let bytesPerRow = analysisWidth * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * analysisHeight)
guard let analysisContext = CGContext(
    data: &pixels,
    width: analysisWidth,
    height: analysisHeight,
    bitsPerComponent: 8,
    bytesPerRow: bytesPerRow,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    print("无法建立分析用的绘图环境")
    exit(1)
}
analysisContext.draw(image, in: CGRect(x: 0, y: 0, width: analysisWidth, height: analysisHeight))

func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let offset = y * bytesPerRow + x * 4
    return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
}

// 背景色取四个角的平均值
let corners = [pixel(1, 1), pixel(analysisWidth - 2, 1), pixel(1, analysisHeight - 2), pixel(analysisWidth - 2, analysisHeight - 2)]
let background = (
    r: corners.map(\.r).reduce(0, +) / corners.count,
    g: corners.map(\.g).reduce(0, +) / corners.count,
    b: corners.map(\.b).reduce(0, +) / corners.count
)

var minX = analysisWidth
var minY = analysisHeight
var maxX = 0
var maxY = 0
// 阈值高一点更贴近「图标本体」的边界，免得把外圈微弱的光晕一起框进来
let threshold = 58
for y in 0..<analysisHeight {
    for x in 0..<analysisWidth {
        let color = pixel(x, y)
        let diff = max(
            abs(color.r - background.r),
            abs(color.g - background.g),
            abs(color.b - background.b)
        )
        guard diff > threshold else { continue }
        minX = min(minX, x)
        maxX = max(maxX, x)
        minY = min(minY, y)
        maxY = max(maxY, y)
    }
}

if minX >= maxX || minY >= maxY {
    print("没有找到图标内容，直接用整张图")
    minX = 0; minY = 0; maxX = analysisWidth - 1; maxY = analysisHeight - 1
}

let scaleToFull = CGFloat(width) / CGFloat(analysisWidth)
var cropRect = CGRect(
    x: CGFloat(minX) * scaleToFull,
    y: CGFloat(minY) * scaleToFull,
    width: CGFloat(maxX - minX + 1) * scaleToFull,
    height: CGFloat(maxY - minY + 1) * scaleToFull
)

print("检测到内容范围：x \(minX)…\(maxX)，y \(minY)…\(maxY)（分析图 \(analysisWidth)×\(analysisHeight)）")

// 裁成正方形（以中心为准），再留 3% 的余量（macOS 图标本体不铺满整张画布）
let side = max(cropRect.width, cropRect.height)
cropRect = CGRect(
    x: cropRect.midX - side / 2,
    y: cropRect.midY - side / 2,
    width: side,
    height: side
)
let margin = side * 0.09
cropRect = cropRect.insetBy(dx: -margin, dy: -margin)

// 分析缓冲的行是从上往下的，CGImage 裁剪用的也是左上原点，直接对应即可
let cropFromImage = CGRect(
    x: max(0, cropRect.minX),
    y: max(0, cropRect.minY),
    width: min(CGFloat(width), cropRect.width),
    height: min(CGFloat(height), cropRect.height)
)

guard let cropped = image.cropping(to: cropFromImage) else {
    print("裁剪失败")
    exit(1)
}

// MARK: - 2. 画成圆角方块

let baseSize = 1024
let cornerRadius = CGFloat(baseSize) * 0.2237

func renderIcon(size: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.interpolationQuality = .high
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let radius = cornerRadius * CGFloat(size) / CGFloat(baseSize)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.clip()
    context.draw(cropped, in: rect)
    return context.makeImage()
}

// MARK: - 3. 生成 iconset 并打包

let fileManager = FileManager.default
let workDirectory = fileManager.temporaryDirectory
    .appendingPathComponent("shutterkeeper-icon-\(UUID().uuidString)", isDirectory: true)
let iconsetURL = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
let keepIconset = ProcessInfo.processInfo.environment["SK_KEEP_ICONSET"] != nil
if !keepIconset {
    defer { try? fileManager.removeItem(at: workDirectory) }
}
print("iconset 目录：\(iconsetURL.path)")

// 需要的尺寸 → 一起写进 iconset（方便人工查看）与 .icns
let sizes = [16, 32, 64, 128, 256, 512, 1024]
var rendered: [Int: Data] = [:]
for size in sizes {
    guard let image = renderIcon(size: size), let data = pngData(image) else {
        print("渲染 \(size)px 失败")
        exit(1)
    }
    rendered[size] = data
    let iconsetName: String
    switch size {
    case 16: iconsetName = "icon_16x16.png"
    case 32: iconsetName = "icon_16x16@2x.png"
    case 64: iconsetName = "icon_32x32@2x.png"
    case 128: iconsetName = "icon_128x128.png"
    case 256: iconsetName = "icon_128x128@2x.png"
    case 512: iconsetName = "icon_256x256@2x.png"
    default: iconsetName = "icon_512x512@2x.png"
    }
    try? data.write(to: iconsetURL.appendingPathComponent(iconsetName))
}

// 自己拼 .icns 容器：magic + 总长度，然后每个条目是 4 字节类型 + 4 字节长度 + PNG 数据。
// （iconutil 在只有命令行工具的环境里不可靠，这样写反而更稳。）
func bigEndian(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
    ]
}

let entries: [(type: String, size: Int)] = [
    ("icp4", 16), ("icp5", 32), ("icp6", 64),
    ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
    ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512),
]

var body = Data()
for entry in entries {
    guard let data = rendered[entry.size] else { continue }
    body.append(contentsOf: Array(entry.type.utf8))
    body.append(contentsOf: bigEndian(UInt32(data.count + 8)))
    body.append(data)
}

var file = Data("icns".utf8)
file.append(contentsOf: bigEndian(UInt32(body.count + 8)))
file.append(body)

do {
    try fileManager.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try file.write(to: outputURL)
} catch {
    print("写入 icns 失败：\(error.localizedDescription)")
    exit(1)
}

print("已生成图标：\(outputURL.path)（\(sizes.count) 档尺寸，\(file.count) 字节）")

func pngData(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
        return nil
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
