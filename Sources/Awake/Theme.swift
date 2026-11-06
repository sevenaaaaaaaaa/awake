import SwiftUI
import AppKit

// MARK: - Theme

/// Typography scale: four sizes, nothing below 12pt.
/// Hierarchy comes from weight, opacity and spacing rather than extra sizes.
enum AwakeType {
    static let metaSize: CGFloat = 12
    static let bodySize: CGFloat = 15
    static let titleSize: CGFloat = 20
    static let displaySize: CGFloat = 32
}

enum AwakeTheme {
    static let background = Color(red: 0.035, green: 0.035, blue: 0.047)
    static let elevated = Color(red: 0.075, green: 0.075, blue: 0.092)
    static let hairline = Color.white.opacity(0.075)
    static let secondaryText = Color.white.opacity(0.56)
    static let tertiaryText = Color.white.opacity(0.34)
    static let accent = Color(red: 0.55, green: 0.80, blue: 1.00)
    static let warm = Color(red: 1.00, green: 0.72, blue: 0.42)

    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let quick = Animation.easeOut(duration: 0.18)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Artwork palette

/// A tiny colour story extracted from the current artwork. Everything in the UI
/// (glow, gradients, lyric highlights) derives from these three colours, which is
/// what makes Awake feel like it belongs to the album that is playing.
struct ArtworkPalette: Equatable {
    var primary: Color
    var secondary: Color
    var deep: Color

    static let fallback = ArtworkPalette(
        primary: Color(hex: 0x7C6CF0),
        secondary: Color(hex: 0x3FB6C9),
        deep: Color(hex: 0x0B0B12))

    static let night = ArtworkPalette(
        primary: Color(hex: 0x5B6CFF),
        secondary: Color(hex: 0x9B5BFF),
        deep: Color(hex: 0x08080E))

    init(primary: Color, secondary: Color, deep: Color) {
        self.primary = primary
        self.secondary = secondary
        self.deep = deep
    }

    init(image: NSImage?) {
        guard let image, let sampled = Self.sample(image) else {
            self = .fallback
            return
        }
        primary = sampled.primary
        secondary = sampled.secondary
        deep = sampled.deep
    }

    private static func sample(_ image: NSImage) -> (primary: Color, secondary: Color, deep: Color)? {
        let side = 24
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: side,
                                         pixelsHigh: side,
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
                   from: .zero,
                   operation: .copy,
                   fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        var saturated: [(r: Double, g: Double, b: Double, weight: Double)] = []
        var all: [(r: Double, g: Double, b: Double)] = []

        for y in 0..<side {
            for x in 0..<side {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Double(color.redComponent)
                let g = Double(color.greenComponent)
                let b = Double(color.blueComponent)
                all.append((r, g, b))
                let maxC = max(r, max(g, b))
                let minC = min(r, min(g, b))
                let saturation = maxC > 0 ? (maxC - minC) / maxC : 0
                let brightness = maxC
                if saturation > 0.22 && brightness > 0.12 {
                    saturated.append((r, g, b, saturation * (0.35 + brightness)))
                }
            }
        }

        let source = saturated.isEmpty ? all.map { ($0.r, $0.g, $0.b, 1.0) } : saturated
        guard !source.isEmpty else { return nil }

        var sumR = 0.0, sumG = 0.0, sumB = 0.0, weightSum = 0.0
        for pixel in source {
            sumR += pixel.r * pixel.weight
            sumG += pixel.g * pixel.weight
            sumB += pixel.b * pixel.weight
            weightSum += pixel.weight
        }
        guard weightSum > 0 else { return nil }
        let r = sumR / weightSum
        let g = sumG / weightSum
        let b = sumB / weightSum

        let primary = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)

        // Secondary: the most saturated pixel cluster that is not a near-duplicate of the primary.
        var bestSecondary: (r: Double, g: Double, b: Double, distance: Double)?
        for pixel in saturated {
            let distance = pow(pixel.r - r, 2) + pow(pixel.g - g, 2) + pow(pixel.b - b, 2)
            if distance > (bestSecondary?.distance ?? 0.02) {
                bestSecondary = (pixel.r, pixel.g, pixel.b, distance)
            }
        }
        let secondaryRGB = bestSecondary.map { ($0.r, $0.g, $0.b) } ?? (b, r, g)
        let secondary = Color(.sRGB,
                              red: secondaryRGB.0 * 0.85,
                              green: secondaryRGB.1 * 0.85,
                              blue: secondaryRGB.2 * 0.85,
                              opacity: 1)
        let deep = Color(.sRGB,
                         red: r * 0.09 + 0.012,
                         green: g * 0.09 + 0.012,
                         blue: b * 0.09 + 0.018,
                         opacity: 1)
        return (primary, secondary, deep)
    }

    /// The immersive background used by the Now Playing stage.
    var stageGradient: LinearGradient {
        LinearGradient(colors: [deep, AwakeTheme.background],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    var glowGradient: RadialGradient {
        RadialGradient(colors: [primary.opacity(0.45), primary.opacity(0.0)],
                       center: .topLeading,
                       startRadius: 10,
                       endRadius: 720)
    }
}

// MARK: - Helpers

extension Double {
    var timecode: String {
        guard isFinite && self >= 0 else { return "0:00" }
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(.ultraThinMaterial.opacity(0.55), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            )
    }

}

// MARK: - Artwork

struct ArtworkView: View {
    var image: NSImage?
    var cornerRadius: CGFloat = 12
    var symbolScale: CGFloat = 0.26
    var palette: ArtworkPalette = .fallback

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [palette.primary.opacity(0.75), palette.secondary.opacity(0.55), palette.deep],
                               startPoint: .topLeading,
                               endPoint: .bottomTrailing)
                GeometryReader { geo in
                    Image(systemName: "music.note")
                        .font(.system(size: min(geo.size.width, geo.size.height) * symbolScale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
