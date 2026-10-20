import AppKit
import CoreGraphics
import SwiftUI

// MARK: - Capture Result (Full Screen Image + Selected Rect on Screen)

struct CaptureSelectionResult {
    let fullScreenCGImage: CGImage
    let fullScreenFrame: NSRect
    let scaleFactor: CGFloat
    let selectedScreenRect: NSRect
    let croppedImage: NSImage
}

// MARK: - Annotation Model & Stroke Size Preset

enum StrokePreset: String, CaseIterable, Identifiable {
    case thin
    case medium
    case thick

    var id: String { rawValue }

    var localizedShortLabel: String {
        L10n.strokeShortLabel(self)
    }

    var localizedTooltip: String {
        L10n.strokeTooltip(self)
    }

    var strokeLineWidth: CGFloat {
        switch self {
        case .thin: return 2.0
        case .medium: return 4.0
        case .thick: return 7.5
        }
    }

    var highlighterBrushWidth: CGFloat {
        switch self {
        case .thin: return 14.0
        case .medium: return 22.0
        case .thick: return 32.0
        }
    }

    var counterBadgeDiameter: CGFloat {
        switch self {
        case .thin: return 22.0
        case .medium: return 28.0
        case .thick: return 36.0
        }
    }

    var mosaicBrushWidth: CGFloat {
        switch self {
        case .thin: return 14.0
        case .medium: return 24.0
        case .thick: return 40.0
        }
    }

    var textFontSize: CGFloat {
        switch self {
        case .thin: return 14.0
        case .medium: return 18.0
        case .thick: return 26.0
        }
    }

    var dotDiameter: CGFloat {
        switch self {
        case .thin: return 6.0
        case .medium: return 9.0
        case .thick: return 12.5
        }
    }
}

enum TextBackgroundStyle: String, CaseIterable, Identifiable {
    case transparent
    case black
    case white

    var id: String { rawValue }

    var localizedShortLabel: String {
        L10n.textBgShortLabel(self)
    }

    var localizedTooltip: String {
        L10n.textBgTooltip(self)
    }

    var fillNSColor: NSColor? {
        switch self {
        case .transparent:
            return nil
        case .black:
            return NSColor(calibratedWhite: 0.08, alpha: 0.90)
        case .white:
            return NSColor(calibratedWhite: 0.98, alpha: 0.94)
        }
    }
}

struct PinAnnotation: Identifiable {
    enum Tool: String, CaseIterable, Identifiable {
        case rect
        case arrow
        case pen
        case highlighter
        case counter
        case mosaic
        case text

        var id: String { rawValue }

        var localizedName: String {
            L10n.toolName(self)
        }

        var icon: String {
            switch self {
            case .rect: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .pen: return "scribble"
            case .highlighter: return "highlighter"
            case .counter: return "1.circle.fill"
            case .mosaic: return "checkerboard.rectangle"
            case .text: return "textformat"
            }
        }
    }

    let id = UUID()
    var tool: Tool
    var color: NSColor
    var lineWidth: CGFloat
    var points: [CGPoint]
    var text: String = ""
    var textBackgroundStyle: TextBackgroundStyle = .transparent
}
