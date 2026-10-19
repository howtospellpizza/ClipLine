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
    case thin = "细"
    case medium = "中"
    case thick = "粗"

    var id: String { rawValue }

    var strokeLineWidth: CGFloat {
        switch self {
        case .thin: return 2.0
        case .medium: return 4.0
        case .thick: return 7.5
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
    case transparent = "透明"
    case black = "黑底"
    case white = "白底"

    var id: String { rawValue }

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
        case rect = "框选"
        case arrow = "箭头"
        case pen = "画笔"
        case mosaic = "马赛克"
        case text = "文字"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .rect: return "rectangle"
            case .arrow: return "arrow.up.right"
            case .pen: return "scribble"
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
