#!/usr/bin/env swift
// make_awake_icon.swift — 用 AppKit 绘制 Awake 的 1024x1024 图标，并生成 .icns 与 iOS AppIcon。
//
// 用法（在仓库根目录）: swift Tools/make_awake_icon.swift
// 产物: Resources/Awake-1024.png, Resources/Awake.icns,
//       ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//
// 设计（黑白两色，唯一图形是「听觉系统」的抽象）：
//   一条从外向内收拢的螺旋线（耳蜗），旋到中心后不再闭合，而是向右上挑开成一段
//   张开的弧——「被唤醒的那一下」。中心一枚实心点，是声音落点。
//   没有渐变、没有光斑、没有文字；两个元素：一条线、一个点。
//
// 几何全部按 1024 画布与 80 安全边距推导，图形中心偏左 26px，给挑开的弧留出呼吸。

import AppKit
import Foundation

let canvas: CGFloat = 1024
let root = FileManager.default.currentDirectoryPath
let resources = root + "/Resources"
let iconsetDir = root + "/.build/Awake.iconset"
let fm = FileManager.default
try? fm.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

/// 画一张 1024 的图。squircle 为 true 时给 macOS 的圆角底板留白。
func render(squircle: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext

    // 底板：近黑，纵向极轻的层次，让纯黑不死板。
    let plate = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    let radius: CGFloat = squircle ? 190 : 0
    let path = CGPath(roundedRect: plate.insetBy(dx: squircle ? 24 : 0, dy: squircle ? 24 : 0),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(path)
    ctx.clip()
    let colors = [srgb(0x0b0c0e).cgColor, srgb(0x15171a).cgColor] as CFArray
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])
    }

    // 螺旋：耳蜗。等宽线（11pt），1.9 圈，开口朝右上。
    let center = CGPoint(x: canvas * 0.475, y: canvas * 0.485)
    let rOuter: CGFloat = 258
    let rInner: CGFloat = 30
    let turns: Double = 1.9
    let steps = 480
    // 开口方向：右上 28 度（Canvas 坐标 y 向上）。
    let mouth = Double.pi * 0.155

    func point(_ t: Double) -> CGPoint {
        let k = t / Double(steps)
        let angle = mouth + (1 - k) * turns * 2 * Double.pi
        let r = rInner + (rOuter - rInner) * CGFloat(k)
        return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
    }

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(srgb(0xf7f8fa).cgColor)
    ctx.setLineWidth(11)
    ctx.move(to: point(0))
    for i in 1...steps { ctx.addLine(to: point(Double(i))) }
    ctx.strokePath()

    // 醒来：从开口起、三段同角度、逐级外扩的弧——声音离开耳朵的形状。
    // 角度固定（不跟着螺旋转），所以看起来是"向外散开"，不是继续盘旋。
    let ripples: [(CGFloat, Double, Double)] = [(46, 0.98, 0.62), (86, 0.82, 0.42), (126, 0.66, 0.26)]
    for (offset, span, alpha) in ripples {
        let radius = rOuter + offset
        ctx.setStrokeColor(srgb(0xf7f8fa, alpha + 0.5).cgColor)
        ctx.setLineWidth(10)
        ctx.addArc(center: center, radius: radius,
                   startAngle: CGFloat(mouth - span / 2), endAngle: CGFloat(mouth + span / 2),
                   clockwise: false)
        ctx.strokePath()
    }

    // 中心落点：声音到达的地方。
    let dot = NSBezierPath(ovalIn: CGRect(x: center.x - 13, y: center.y - 13, width: 26, height: 26))
    srgb(0xf7f8fa).setFill()
    dot.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try data.write(to: URL(fileURLWithPath: path))
}

let master = render(squircle: true)
try writePNG(master, resources + "/Awake-1024.png")

// .icns：从 1024 逐级缩放，iconutil 需要这些尺寸。
let sizes: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
let source = NSImage(size: NSSize(width: canvas, height: canvas))
source.addRepresentation(master)
for (size, name) in sizes {
    let target = NSImage(size: NSSize(width: size, height: size))
    target.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    target.unlockFocus()
    guard let tiff = target.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: URL(fileURLWithPath: iconsetDir + "/" + name + ".png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", resources + "/Awake.icns"]
try task.run()
task.waitUntilExit()

// iOS：单张 1024，圆角由系统裁；不能带透明边。
let iosRep = render(squircle: false)
try writePNG(iosRep, root + "/ios/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

print("icon ok: Resources/Awake-1024.png, Resources/Awake.icns, iOS AppIcon.png")
