#!/usr/bin/env swift
// make_awake_icon.swift — 用 AppKit 绘制 Awake 的 1024x1024 图标，并生成 .icns
//
// 用法（在仓库根目录）: swift Tools/make_awake_icon.swift
// 产物: Resources/Awake-1024.png, Resources/Awake.icns
//
// 设计：深夜蓝紫渐变底，中央“日出 + 声波”符号；
// 内容距画布边缘 80px，圆角按 macOS 图标比例（半径 190）。

import AppKit
import Foundation

let canvas: CGFloat = 1024
let margin: CGFloat = 80
let root = FileManager.default.currentDirectoryPath
let resources = root + "/Resources"
let pngPath = resources + "/Awake-1024.png"
let icnsPath = resources + "/Awake.icns"
let iconsetDir = root + "/.build/Awake.iconset"

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                   green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                   blue: CGFloat(hex & 0xFF) / 255.0,
                   alpha: alpha)
}

func linear(_ ctx: CGContext, _ stops: [(UInt32, CGFloat)], _ locations: [CGFloat],
            from: CGPoint, to: CGPoint) {
    let colors = stops.map { srgb($0.0, $0.1).cgColor } as CFArray
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors, locations: locations) else { return }
    ctx.drawLinearGradient(g, start: from, end: to, options: [])
}

func radial(_ ctx: CGContext, center: CGPoint, radius: CGFloat,
            _ inner: (UInt32, CGFloat), _ outer: (UInt32, CGFloat)) {
    let colors = [srgb(inner.0, inner.1).cgColor, srgb(outer.0, outer.1).cgColor] as CFArray
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors, locations: [0, 1]) else { return }
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                           endCenter: center, endRadius: radius,
                           options: [.drawsAfterEndLocation])
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// ---- 画布 -------------------------------------------------------------------
guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else {
    FileHandle.standardError.write("无法创建位图缓冲区\n".data(using: .utf8)!)
    exit(1)
}
rep.size = NSSize(width: canvas, height: canvas)

NSGraphicsContext.saveGraphicsState()
guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = gctx
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)

let content = CGRect(x: margin, y: margin,
                     width: canvas - margin * 2, height: canvas - margin * 2)
let shape = roundedRect(content, 190)

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

// 底色：深夜蓝紫
linear(ctx, [(0x05060F, 1), (0x12092E, 1), (0x221457, 1)], [0, 0.55, 1],
       from: CGPoint(x: 200, y: 80), to: CGPoint(x: 800, y: 944))

// 极光光晕
radial(ctx, center: CGPoint(x: 300, y: 760), radius: 560, (0x2F5BFF, 0.50), (0x2F5BFF, 0))
radial(ctx, center: CGPoint(x: 790, y: 640), radius: 520, (0x9B4DFF, 0.42), (0x9B4DFF, 0))
radial(ctx, center: CGPoint(x: 512, y: 120), radius: 420, (0xFF7A50, 0.10), (0xFF7A50, 0))

// 日落区域的暖光
let horizon: CGFloat = 430
radial(ctx, center: CGPoint(x: 512, y: horizon), radius: 420, (0xFF9A5E, 0.34), (0xFF9A5E, 0))

// 日出圆盘（只保留地平线以上）
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: horizon, width: canvas, height: canvas - horizon))
let sunRect = CGRect(x: 512 - 200, y: horizon - 200, width: 400, height: 400)
ctx.addPath(CGPath(ellipseIn: sunRect, transform: nil))
ctx.clip()
linear(ctx, [(0xFF7A4D, 0.98), (0xFFB173, 0.98), (0xFFE3B8, 0.98)], [0, 0.55, 1],
       from: CGPoint(x: 512, y: horizon - 200), to: CGPoint(x: 512, y: horizon + 200))
ctx.restoreGState()

// 日出上方的细弧线
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: horizon, width: canvas, height: canvas - horizon))
for (i, r) in [250.0, 292.0, 334.0].enumerated() {
    ctx.setStrokeColor(srgb(0xFFFFFF, 0.10 - CGFloat(i) * 0.02).cgColor)
    ctx.setLineWidth(1.5)
    ctx.strokeEllipse(in: CGRect(x: 512 - r, y: horizon - r, width: r * 2, height: r * 2))
}
ctx.restoreGState()

// 地平线
ctx.setFillColor(srgb(0xFFFFFF, 0.16).cgColor)
ctx.fill(CGRect(x: 176, y: horizon - 1.25, width: 672, height: 2.5))
ctx.setFillColor(srgb(0xFFC79A, 0.55).cgColor)
ctx.fill(CGRect(x: 332, y: horizon - 1.25, width: 360, height: 2.5))

// 声波：七根圆角竖条，从地平线升起（中间最高）
let heights: [CGFloat] = [92, 152, 222, 286, 222, 152, 92]
let barWidth: CGFloat = 30
let gap: CGFloat = 18
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var barX = 512 - totalWidth / 2

for h in heights {
    let bar = CGRect(x: barX, y: horizon, width: barWidth, height: h)
    let path = roundedRect(bar, barWidth / 2)

    // 地平线下的倒影：贴边渐隐，模拟水面
    ctx.saveGState()
    let mirror = CGRect(x: barX, y: horizon + 1.5, width: barWidth, height: h * 0.30)
    ctx.addPath(roundedRect(mirror, barWidth / 2))
    ctx.clip()
    linear(ctx, [(0xFFFFFF, 0.20), (0xFFFFFF, 0.0)], [0, 1],
           from: CGPoint(x: barX, y: horizon), to: CGPoint(x: barX, y: horizon + h * 0.30))
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 26, color: srgb(0xFFD9B0, 0.35).cgColor)
    ctx.addPath(path)
    ctx.clip()
    linear(ctx, [(0xFFFFFF, 0.98), (0xE9F0FF, 0.94)], [0, 1],
           from: CGPoint(x: barX, y: horizon), to: CGPoint(x: barX, y: horizon + h))
    ctx.restoreGState()

    barX += barWidth + gap
}

// 顶部柔光
radial(ctx, center: CGPoint(x: 360, y: 900), radius: 520, (0xFFFFFF, 0.10), (0xFFFFFF, 0))

// 暗角
radial(ctx, center: CGPoint(x: 512, y: 540), radius: 720, (0x000000, 0.0), (0x000000, 0.38))

// 内描边
ctx.addPath(shape)
ctx.setStrokeColor(srgb(0xFFFFFF, 0.20).cgColor)
ctx.setLineWidth(2.5)
ctx.strokePath()

ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 编码失败\n".data(using: .utf8)!)
    exit(1)
}
try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
do {
    try png.write(to: URL(fileURLWithPath: pngPath))
} catch {
    FileHandle.standardError.write("写入 PNG 失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}

// ---- 生成 .icns -------------------------------------------------------------
@discardableResult
func run(_ tool: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch {
        FileHandle.standardError.write("无法执行 \(tool): \(error)\n".data(using: .utf8)!)
        return -1
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        FileHandle.standardError.write(data)
    }
    return p.terminationStatus
}

try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes = [16, 32, 128, 256, 512]
for s in sizes {
    let one = iconsetDir + "/icon_\(s)x\(s).png"
    let two = iconsetDir + "/icon_\(s)x\(s)@2x.png"
    guard run("/usr/bin/sips", ["-z", "\(s)", "\(s)", pngPath, "--out", one]) == 0,
          run("/usr/bin/sips", ["-z", "\(s * 2)", "\(s * 2)", pngPath, "--out", two]) == 0 else {
        FileHandle.standardError.write("sips 生成 \(s)px 图标失败\n".data(using: .utf8)!)
        exit(1)
    }
}

guard run("/usr/bin/iconutil", ["-c", "icns", iconsetDir, "-o", icnsPath]) == 0 else {
    FileHandle.standardError.write("iconutil 生成 icns 失败\n".data(using: .utf8)!)
    exit(1)
}

// ---- 汇报 -------------------------------------------------------------------
func sizeBytes(_ path: String) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    return (attrs?[.size] as? NSNumber)?.intValue ?? 0
}

let pngBytes = sizeBytes(pngPath)
let icnsBytes = sizeBytes(icnsPath)
guard pngBytes > 0, icnsBytes > 0 else {
    FileHandle.standardError.write("产物为空\n".data(using: .utf8)!)
    exit(1)
}

print("==> icon written: Resources/Awake-1024.png (\(pngBytes) bytes, 1024x1024)")
print("==> icns written: Resources/Awake.icns (\(icnsBytes) bytes)")