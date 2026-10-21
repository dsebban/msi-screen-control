import AppKit
import SwiftUI
import MSIScreenCore

/// An original shield and M mark, with one palette shared by the panel and menu bar.
enum MonitorAppearance {
    static let panelSize = NSSize(width: 440, height: 680)
    static let secondaryText = Color(red: 0.67, green: 0.70, blue: 0.79)
    static let panelBackground = LinearGradient(
        colors: [Color(red: 0.13, green: 0.15, blue: 0.18), Color(red: 0.085, green: 0.115, blue: 0.13)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    static func color(for state: ScreenState?) -> NSColor {
        guard let state else {
            return NSColor(srgbRed: 0.43, green: 0.43, blue: 0.43, alpha: 1)
        }
        switch state.mode {
        case .pbp, .pip:
            return NSColor(srgbRed: 0.66, green: 0.18, blue: 1, alpha: 1)
        case .off:
            return color(for: state.source1)
        }
    }

    static func color(for input: Input) -> NSColor {
        switch input {
        case .hdmi1, .hdmi2:
            return NSColor(srgbRed: 1, green: 0.42, blue: 0.02, alpha: 1)
        case .usbc:
            return NSColor(srgbRed: 0.01, green: 0.84, blue: 0.90, alpha: 1)
        case .dp:
            return NSColor(srgbRed: 0.18, green: 0.46, blue: 1, alpha: 1)
        }
    }

    static func tint(for state: ScreenState?) -> Color { Color(nsColor: color(for: state)) }
    static func tint(for input: Input) -> Color { Color(nsColor: color(for: input)) }

    static func statusImage(for state: ScreenState?, updateReady: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / 18, y: bounds.height / 18)
            context.saveGState()
            context.move(to: CGPoint(x: 3, y: 14))
            context.addLine(to: CGPoint(x: 3, y: 4))
            context.addLine(to: CGPoint(x: 9, y: 9))
            context.addLine(to: CGPoint(x: 15, y: 4))
            context.addLine(to: CGPoint(x: 15, y: 14))
            context.setLineWidth(2.5)
            context.setLineCap(.square)
            context.setLineJoin(.miter)
            context.replacePathWithStrokedPath()
            context.clip()
            let primary = state.map { color(for: $0.source1) } ?? NSColor(white: 0.55, alpha: 0.75)
            context.setFillColor(primary.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 18, height: 18))
            if let state, state.mode != .off {
                let secondary = state.mode == .pip ? state.pipInput : state.source2
                context.setFillColor(color(for: secondary).cgColor)
                // PBP follows the physical left/right order. PIP keeps a
                // smaller secondary accent instead of implying equal halves.
                context.fill(state.mode == .pbp
                    ? CGRect(x: 9, y: 0, width: 9, height: 18)
                    : CGRect(x: 12, y: 10, width: 6, height: 8))
            }
            context.restoreGState()
            if updateReady {
                let badge = CGRect(x: 12.5, y: 0.5, width: 5, height: 5)
                context.setFillColor(NSColor.systemYellow.cgColor)
                context.fillEllipse(in: badge)
                context.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
                context.setLineWidth(0.75)
                context.strokeEllipse(in: badge)
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Decorative when placed beside a layout label; the label carries the status.
struct MonitorMark: View {
    let state: ScreenState?

    var body: some View {
        ZStack {
            MarkShape(geometry: .shield)
                .fill(LinearGradient(colors: [MonitorAppearance.tint(for: state),
                                              MonitorAppearance.tint(for: state).opacity(0.8),
                                              Color(nsColor: MonitorAppearance.color(for: state).blended(withFraction: 0.45, of: .black)
                                                    ?? MonitorAppearance.color(for: state))],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            MarkShape(geometry: .shield)
                .strokeBorder(.white.opacity(0.67), lineWidth: 1.2)
            MarkShape(geometry: .letter)
                .stroke(.white, style: StrokeStyle(lineWidth: 3.2, lineCap: .square, lineJoin: .miter))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct MarkShape: InsettableShape {
    let geometry: MonitorMarkGeometry
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let area = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let side = min(area.width, area.height)
        let transform = CGAffineTransform(scaleX: side / 18, y: side / 18)
            .concatenating(CGAffineTransform(translationX: area.midX - side / 2,
                                           y: area.midY - side / 2))
        return Path(geometry.path).applying(transform)
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private enum MonitorMarkGeometry: Sendable {
    case shield, letter

    // Coordinates share an 18-point square with a downward-facing Y axis.
    var path: CGPath {
        let path = CGMutablePath()
        switch self {
        case .shield:
            path.move(to: CGPoint(x: 9, y: 1))
            path.addLine(to: CGPoint(x: 16, y: 3.5))
            path.addLine(to: CGPoint(x: 15.5, y: 11))
            path.addLine(to: CGPoint(x: 9, y: 17))
            path.addLine(to: CGPoint(x: 2.5, y: 11))
            path.addLine(to: CGPoint(x: 2, y: 3.5))
            path.closeSubpath()
        case .letter:
            path.move(to: CGPoint(x: 5, y: 11.5))
            path.addLine(to: CGPoint(x: 5, y: 6))
            path.addLine(to: CGPoint(x: 9, y: 9.5))
            path.addLine(to: CGPoint(x: 13, y: 6))
            path.addLine(to: CGPoint(x: 13, y: 11.5))
        }
        return path
    }
}

/// Static vector waves reproduce the reference screen without image assets or timers.
struct MonitorScreenArtwork: View {
    let input: Input

    private var warm: Bool { input == .hdmi1 || input == .hdmi2 }
    private var top: Color {
        switch input {
        case .hdmi1, .hdmi2: return Color(red: 1, green: 0.56, blue: 0.24)
        case .usbc: return Color(red: 0.02, green: 0.72, blue: 0.65)
        case .dp: return Color(red: 0.18, green: 0.53, blue: 0.98)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [top, warm ? Color(red: 0.36, green: 0.035, blue: 0.19)
                                                : Color(red: 0.015, green: 0.21, blue: 0.39)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Path { path in
                    let w = geometry.size.width
                    let h = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: warm ? h * 0.12 : h * 0.55))
                    path.addCurve(to: CGPoint(x: w, y: h * 0.20),
                                  control1: CGPoint(x: w * 0.42, y: h * (warm ? 0.35 : 0.9)),
                                  control2: CGPoint(x: w * 0.48, y: h * (warm ? 1.18 : 0.04)))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [warm ? Color(red: 0.55, green: 0.065, blue: 0.10)
                                                  : Color(red: 0.015, green: 0.30, blue: 0.42),
                                              Color(red: 0.045, green: 0.04, blue: 0.20)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                Path { path in
                    let w = geometry.size.width
                    let h = geometry.size.height
                    path.move(to: CGPoint(x: 0, y: h * 0.47))
                    path.addCurve(to: CGPoint(x: w, y: h * 0.53),
                                  control1: CGPoint(x: w * 0.46, y: h * 0.65),
                                  control2: CGPoint(x: w * 0.39, y: h * 1.45))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [warm ? Color(red: 0.21, green: 0.025, blue: 0.14)
                                                  : Color(red: 0.015, green: 0.20, blue: 0.30),
                                              Color(red: 0.015, green: 0.035, blue: 0.16)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
