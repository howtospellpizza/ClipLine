import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Vision

// MARK: - Pin Window ViewModel (Dual-Panel Architecture: Image Canvas Panel + Detached Toolbar Panel)

@MainActor
final class PinSessionViewModel: ObservableObject {
    enum ResizeHandle: CaseIterable {
        case topLeft, topCenter, topRight
        case middleLeft, middleRight
        case bottomLeft, bottomCenter, bottomRight

        var cursor: NSCursor {
            switch self {
            case .topCenter, .bottomCenter:
                return DirectionalCursor.northSouth
            case .middleLeft, .middleRight:
                return DirectionalCursor.eastWest
            case .topLeft, .bottomRight:
                return DirectionalCursor.northWestSouthEast
            case .topRight, .bottomLeft:
                return DirectionalCursor.northEastSouthWest
            }
        }
    }

    let id = UUID()
    @Published var baseImage: NSImage
    @Published var pixelatedBaseImage: NSImage?
    @Published var baseSize: NSSize

    let fullScreenCGImage: CGImage?
    let fullScreenFrame: NSRect?
    let captureScaleFactor: CGFloat
    @Published var cropScreenRect: NSRect?
    @Published var hasMovedWindow: Bool = false

    @Published var annotations: [PinAnnotation] = []
    @Published var currentDragPoints: [CGPoint] = []
    @Published var activeTool: PinAnnotation.Tool? = nil {
        didSet {
            if activeTool == .mosaic && pixelatedBaseImage == nil {
                regeneratePixelatedImage()
            }
            updateToolbarPanelPosition()
            hostingPanel?.canvasView?.window?.invalidateCursorRects(for: hostingPanel!.canvasView!)
        }
    }
    @Published var selectedColor: Color = .red {
        didSet {
            hostingPanel?.canvasView?.applyStyleChangeToSelectionOrField(updateColor: true, updatePreset: false, updateBackground: false)
        }
    }
    @Published var strokePreset: StrokePreset = .medium {
        didSet {
            hostingPanel?.canvasView?.applyStyleChangeToSelectionOrField(updateColor: false, updatePreset: true, updateBackground: false)
        }
    }
    @Published var textBackgroundStyle: TextBackgroundStyle = .transparent {
        didSet {
            hostingPanel?.canvasView?.applyStyleChangeToSelectionOrField(updateColor: false, updatePreset: false, updateBackground: true)
            updateToolbarPanelPosition()
        }
    }
    @Published var selectedTextAnnotationID: UUID? = nil
    @Published var scale: CGFloat = 1.0
    @Published var windowOpacity: Double = 1.0
    @Published var showToolbar: Bool = true {
        didSet {
            updateToolbarPanelPosition()
        }
    }
    @Published var toastMessage: String? = nil
    @Published var isPerformingOCR: Bool = false
    @Published var isClosed: Bool = false
    var activeOCRTask: Task<Void, Never>? = nil

    // Option to force pixelation failure in tests to verify fail-closed solid redaction block
    var forceMosaicFallbackForTesting: Bool = false
    @Published var pendingTextNormalizedPos: CGPoint? = nil
    @Published var pendingTextString: String = ""
    var editingExistingTextAnnotationID: UUID? = nil
    var editingOriginalAnnotationSnapshot: PinAnnotation? = nil

    weak var hostingPanel: PinFloatingPanel?
    weak var toolbarPanel: NSPanel?

    /// Exact margin around the image inside `hostingPanel` so 8 resize handles sit comfortably inside the window
    static let canvasMargin: CGFloat = 16

    var currentToolLineWidth: CGFloat {
        guard let tool = activeTool else { return strokePreset.strokeLineWidth }
        switch tool {
        case .mosaic:
            return strokePreset.mosaicBrushWidth
        case .highlighter:
            return strokePreset.highlighterBrushWidth
        case .counter:
            return strokePreset.counterBadgeDiameter
        case .text:
            return strokePreset.textFontSize
        case .rect, .arrow, .pen:
            return strokePreset.strokeLineWidth
        }
    }

    var nextCounterLabel: String {
        let count = annotations.filter { $0.tool == .counter }.count
        return "\(count + 1)"
    }

    static func constrainedNormalizedEndPoint(
        for tool: PinAnnotation.Tool,
        start: CGPoint,
        rawEnd: CGPoint,
        canvasSize: NSSize
    ) -> CGPoint {
        let w = max(1.0, canvasSize.width)
        let h = max(1.0, canvasSize.height)
        let dxPt = (rawEnd.x - start.x) * w
        let dyPt = (rawEnd.y - start.y) * h

        switch tool {
        case .rect:
            let side = max(abs(dxPt), abs(dyPt))
            let sx: CGFloat = dxPt >= 0 ? 1.0 : -1.0
            let sy: CGFloat = dyPt >= 0 ? 1.0 : -1.0
            let maxSideX = sx >= 0 ? (1.0 - start.x) * w : start.x * w
            let maxSideY = sy >= 0 ? (1.0 - start.y) * h : start.y * h
            let clampedSide = min(side, min(maxSideX, maxSideY))
            return CGPoint(
                x: max(0.0, min(1.0, start.x + (sx * clampedSide) / w)),
                y: max(0.0, min(1.0, start.y + (sy * clampedSide) / h))
            )
        case .arrow:
            let dist = hypot(dxPt, dyPt)
            guard dist > 0.001 else { return rawEnd }
            let step = CGFloat.pi / 4.0
            let snappedAngle = (atan2(dyPt, dxPt) / step).rounded() * step
            let ux = cos(snappedAngle)
            let uy = sin(snappedAngle)
            var maxDist = dist
            if ux > 0.0001 {
                maxDist = min(maxDist, ((1.0 - start.x) * w) / ux)
            } else if ux < -0.0001 {
                maxDist = min(maxDist, (start.x * w) / (-ux))
            }
            if uy > 0.0001 {
                maxDist = min(maxDist, ((1.0 - start.y) * h) / uy)
            } else if uy < -0.0001 {
                maxDist = min(maxDist, (start.y * h) / (-uy))
            }
            let finalDist = max(0.0, maxDist)
            return CGPoint(
                x: max(0.0, min(1.0, start.x + (ux * finalDist) / w)),
                y: max(0.0, min(1.0, start.y + (uy * finalDist) / h))
            )
        default:
            return rawEnd
        }
    }

    init(
        image: NSImage,
        fullScreenCGImage: CGImage? = nil,
        fullScreenFrame: NSRect? = nil,
        captureScaleFactor: CGFloat = 2.0,
        cropScreenRect: NSRect? = nil
    ) {
        self.baseImage = image
        self.baseSize = image.size
        self.fullScreenCGImage = fullScreenCGImage
        self.fullScreenFrame = fullScreenFrame
        self.captureScaleFactor = captureScaleFactor
        self.cropScreenRect = cropScreenRect
        self.pixelatedBaseImage = nil
    }

    func regeneratePixelatedImage() {
        self.pixelatedBaseImage = MosaicRenderer.createPixelatedImage(from: baseImage)
    }

    var canAdjustCrop: Bool {
        fullScreenCGImage != nil && fullScreenFrame != nil && cropScreenRect != nil && !hasMovedWindow && scale == 1.0 && annotations.isEmpty
    }

    /// Computes the exact frame of `hostingPanel` for a given `imageScreenRect`.
    /// Notice: NO `minPanelWidth`! The image panel is ALWAYS `image.width + 32` by `image.height + 32`!
    static func panelFrameForImageScreenRect(_ imageScreenRect: NSRect) -> NSRect {
        NSRect(
            x: round(imageScreenRect.minX - canvasMargin),
            y: round(imageScreenRect.minY - canvasMargin),
            width: round(imageScreenRect.width + canvasMargin * 2),
            height: round(imageScreenRect.height + canvasMargin * 2)
        )
    }

    /// Positions the detached toolbar panel cleanly below (or above if near screen bottom) the image panel.
    func updateToolbarPanelPosition() {
        guard let imgPanel = hostingPanel, let tbPanel = toolbarPanel else { return }
        if !showToolbar || !imgPanel.isVisible {
            tbPanel.orderOut(nil)
            return
        }

        if let tbPanel = tbPanel as? PinToolbarPanel {
            tbPanel.refreshToolbarRootView()
        }
        if let contentView = tbPanel.contentView {
            contentView.invalidateIntrinsicContentSize()
            contentView.layoutSubtreeIfNeeded()
            let fitting = contentView.fittingSize
            if fitting.width > 10 && fitting.height > 10 {
                tbPanel.setContentSize(fitting)
            }
        }

        let imgFrame = imgPanel.frame
        // Actual image screen rect inside imgPanel
        let imageMinX = imgFrame.minX + Self.canvasMargin
        let imageMinY = imgFrame.minY + Self.canvasMargin
        let imageMaxY = imgFrame.maxY - Self.canvasMargin

        let tbSize = tbPanel.frame.size
        let screen = imgPanel.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // Align toolbar left with image left, clamped to screen visible bounds
        var tbX = round(imageMinX)
        if tbX + tbSize.width > visible.maxX - 8 {
            tbX = round(visible.maxX - tbSize.width - 8)
        }
        if tbX < visible.minX + 8 {
            tbX = round(visible.minX + 8)
        }

        // Place toolbar 12pt below the bottom border of the image (leaving plenty of room for bottom handles!)
        var tbY = round(imageMinY - tbSize.height - 12)
        if tbY < visible.minY + 6 {
            // If image is at the very bottom of the screen, place toolbar 12pt above the top border of the image
            tbY = round(imageMaxY + 12)
        }

        tbPanel.setFrameOrigin(NSPoint(x: tbX, y: tbY))
        if !tbPanel.isVisible {
            tbPanel.orderFrontRegardless()
        }
    }

    func applyResize(handle: ResizeHandle, startMouse: NSPoint, startCropRect: NSRect, currentMouse: NSPoint) {
        guard let cg = fullScreenCGImage,
              let screenFrame = fullScreenFrame,
              let panel = hostingPanel
        else { return }

        let dx = round(currentMouse.x - startMouse.x)
        let dy = round(currentMouse.y - startMouse.y)

        var newMinX = startCropRect.minX
        var newMaxX = startCropRect.maxX
        var newMinY = startCropRect.minY
        var newMaxY = startCropRect.maxY

        let minCropSize: CGFloat = 24.0
        switch handle {
        case .topLeft:
            newMinX = max(screenFrame.minX, min(startCropRect.minX + dx, startCropRect.maxX - minCropSize))
            newMaxY = min(screenFrame.maxY, max(startCropRect.maxY + dy, startCropRect.minY + minCropSize))
        case .topCenter:
            newMaxY = min(screenFrame.maxY, max(startCropRect.maxY + dy, startCropRect.minY + minCropSize))
        case .topRight:
            newMaxX = min(screenFrame.maxX, max(startCropRect.maxX + dx, startCropRect.minX + minCropSize))
            newMaxY = min(screenFrame.maxY, max(startCropRect.maxY + dy, startCropRect.minY + minCropSize))
        case .middleLeft:
            newMinX = max(screenFrame.minX, min(startCropRect.minX + dx, startCropRect.maxX - minCropSize))
        case .middleRight:
            newMaxX = min(screenFrame.maxX, max(startCropRect.maxX + dx, startCropRect.minX + minCropSize))
        case .bottomLeft:
            newMinX = max(screenFrame.minX, min(startCropRect.minX + dx, startCropRect.maxX - minCropSize))
            newMinY = max(screenFrame.minY, min(startCropRect.minY + dy, startCropRect.maxY - minCropSize))
        case .bottomCenter:
            newMinY = max(screenFrame.minY, min(startCropRect.minY + dy, startCropRect.maxY - minCropSize))
        case .bottomRight:
            newMaxX = min(screenFrame.maxX, max(startCropRect.maxX + dx, startCropRect.minX + minCropSize))
            newMinY = max(screenFrame.minY, min(startCropRect.minY + dy, startCropRect.maxY - minCropSize))
        }

        let rect = NSRect(x: newMinX, y: newMinY, width: newMaxX - newMinX, height: newMaxY - newMinY)
        if rect == self.cropScreenRect { return }

        let localRect = NSRect(
            x: rect.origin.x - screenFrame.origin.x,
            y: rect.origin.y - screenFrame.origin.y,
            width: rect.width,
            height: rect.height
        )

        guard let reCropped = PixPinSelectionView.cropImage(
            cgImage: cg,
            viewHeight: screenFrame.height,
            scaleFactor: captureScaleFactor,
            rect: localRect
        ) else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.cropScreenRect = rect
        self.baseImage = reCropped
        self.baseSize = reCropped.size
        let panelFrame = Self.panelFrameForImageScreenRect(rect)
        panel.setFrame(panelFrame, display: true, animate: false)
        panel.canvasView?.needsDisplay = true
        updateToolbarPanelPosition()
        CATransaction.commit()
    }

    func finishResize() {
        if activeTool == .mosaic || pixelatedBaseImage != nil {
            regeneratePixelatedImage()
        }
        if let cv = hostingPanel?.canvasView {
            hostingPanel?.invalidateCursorRects(for: cv)
        }
    }

    func showToast(_ msg: String) {
        toastMessage = msg
        hostingPanel?.canvasView?.needsDisplay = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if self.toastMessage == msg {
                self.toastMessage = nil
                self.hostingPanel?.canvasView?.needsDisplay = true
            }
        }
    }

    func undo() {
        if !annotations.isEmpty {
            _ = annotations.popLast()
            hostingPanel?.canvasView?.needsDisplay = true
        }
    }

    func cancelPendingTextEditing() {
        let editID = editingExistingTextAnnotationID
        let snapshot = editingOriginalAnnotationSnapshot
        editingExistingTextAnnotationID = nil
        editingOriginalAnnotationSnapshot = nil
        pendingTextNormalizedPos = nil
        pendingTextString = ""
        if let tf = hostingPanel?.canvasView?.textField {
            tf.delegate = nil
            hostingPanel?.canvasView?.clearTextFieldReference()
            tf.removeFromSuperview()
        }
        if let editID = editID {
            if let snapshot = snapshot,
               let idx = annotations.firstIndex(where: { $0.id == editID && $0.tool == .text }) {
                annotations[idx] = snapshot
            }
            selectedTextAnnotationID = editID
        }
        if let cv = hostingPanel?.canvasView {
            cv.window?.invalidateCursorRects(for: cv)
            cv.needsDisplay = true
        }
    }

    func commitPendingText() {
        if let tf = hostingPanel?.canvasView?.textField {
            pendingTextString = tf.stringValue
            tf.delegate = nil
            hostingPanel?.canvasView?.clearTextFieldReference()
            tf.removeFromSuperview()
        }
        guard let pos = pendingTextNormalizedPos else {
            editingExistingTextAnnotationID = nil
            editingOriginalAnnotationSnapshot = nil
            return
        }
        let trimmed = pendingTextString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editID = editingExistingTextAnnotationID,
           let idx = annotations.firstIndex(where: { $0.id == editID && $0.tool == .text }) {
            if trimmed.isEmpty {
                annotations.remove(at: idx)
                selectedTextAnnotationID = nil
            } else {
                annotations[idx].color = NSColor(selectedColor)
                annotations[idx].lineWidth = strokePreset.textFontSize
                annotations[idx].points = [pos]
                annotations[idx].text = trimmed
                annotations[idx].textBackgroundStyle = textBackgroundStyle
                selectedTextAnnotationID = editID
            }
        } else if !trimmed.isEmpty {
            let newItem = PinAnnotation(
                tool: .text,
                color: NSColor(selectedColor),
                lineWidth: strokePreset.textFontSize,
                points: [pos],
                text: trimmed,
                textBackgroundStyle: textBackgroundStyle
            )
            annotations.append(newItem)
            selectedTextAnnotationID = newItem.id
        }
        editingExistingTextAnnotationID = nil
        editingOriginalAnnotationSnapshot = nil
        pendingTextNormalizedPos = nil
        pendingTextString = ""
        if let cv = hostingPanel?.canvasView {
            cv.window?.invalidateCursorRects(for: cv)
            cv.needsDisplay = true
        }
    }

    func renderCompositeImage() -> NSImage? {
        let targetSize = baseSize
        guard targetSize.width >= 1, targetSize.height >= 1 else { return nil }

        // Preserve exact Retina backing resolution from baseImage representations so exported/stitched images stay razor-sharp
        let scaleFactor: CGFloat = baseImage.representations.reduce(1.0) { acc, rep in
            guard targetSize.width > 0, rep.pixelsWide > 0 else { return acc }
            return max(acc, CGFloat(rep.pixelsWide) / targetSize.width)
        }
        let pixelW = max(1, Int((targetSize.width * scaleFactor).rounded()))
        let pixelH = max(1, Int((targetSize.height * scaleFactor).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelW,
            pixelsHigh: pixelH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        guard let gfxCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            return nil
        }
        NSGraphicsContext.current = gfxCtx
        let ctx = gfxCtx.cgContext

        baseImage.draw(in: NSRect(origin: .zero, size: targetSize))

        ctx.saveGState()
        ctx.translateBy(x: 0, y: targetSize.height)
        ctx.scaleBy(x: 1.0, y: -1.0)

        for item in annotations {
            drawAnnotationInCGContext(item, ctx: ctx, size: targetSize)
        }

        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: targetSize)
        result.addRepresentation(rep)
        return result
    }

    func drawAnnotationInCGContext(_ item: PinAnnotation, ctx: CGContext, size: NSSize, scaleMultiplier: CGFloat = 1.0) {
        guard !item.points.isEmpty else { return }
        let pts = item.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let lw = item.lineWidth * scaleMultiplier

        ctx.saveGState()
        ctx.setStrokeColor(item.color.cgColor)
        ctx.setFillColor(item.color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch item.tool {
        case .rect:
            guard pts.count >= 2 else { break }
            let rect = CGRect(
                x: min(pts[0].x, pts.last!.x),
                y: min(pts[0].y, pts.last!.y),
                width: abs(pts.last!.x - pts[0].x),
                height: abs(pts.last!.y - pts[0].y)
            )
            ctx.stroke(rect)

        case .arrow:
            guard pts.count >= 2 else { break }
            let start = pts[0]
            let end = pts.last!
            ctx.move(to: start)
            ctx.addLine(to: end)
            ctx.strokePath()

            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLength: CGFloat = max(12.0, item.lineWidth * 3.4) * scaleMultiplier
            let arrowAngle: CGFloat = .pi / 6
            let p1 = CGPoint(
                x: end.x - headLength * cos(angle - arrowAngle),
                y: end.y - headLength * sin(angle - arrowAngle)
            )
            let p2 = CGPoint(
                x: end.x - headLength * cos(angle + arrowAngle),
                y: end.y - headLength * sin(angle + arrowAngle)
            )
            ctx.move(to: end)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.fillPath()

        case .pen:
            guard pts.count >= 2 else { break }
            ctx.move(to: pts[0])
            for p in pts.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()

        case .highlighter:
            guard pts.count >= 2 else { break }
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(item.color.withAlphaComponent(0.38).cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.butt)
            ctx.setLineJoin(.round)
            ctx.move(to: pts[0])
            for p in pts.dropFirst() {
                ctx.addLine(to: p)
            }
            ctx.strokePath()
            ctx.restoreGState()

        case .counter:
            let center = pts[0]
            let diameter = max(18.0, item.lineWidth) * scaleMultiplier
            let radius = diameter / 2.0
            let badgeRect = CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter)

            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 3.5, color: NSColor.black.withAlphaComponent(0.36).cgColor)
            ctx.setFillColor(item.color.cgColor)
            ctx.fillEllipse(in: badgeRect)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(max(1.8, 2.0 * scaleMultiplier))
            ctx.strokeEllipse(in: badgeRect)
            ctx.restoreGState()

            let label = item.text.isEmpty ? "1" : item.text
            let fontSize = round(diameter * (label.count >= 2 ? 0.48 : 0.56))
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let rgb = item.color.usingColorSpace(.sRGB) ?? item.color
            let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
            let fgColor: NSColor = luma > 0.72 ? .black : .white
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: fgColor
            ]
            let textSize = (label as NSString).size(withAttributes: attrs)
            ctx.saveGState()
            ctx.translateBy(x: center.x, y: center.y)
            ctx.scaleBy(x: 1.0, y: -1.0)
            (label as NSString).draw(
                at: CGPoint(x: -textSize.width / 2.0, y: -textSize.height / 2.0),
                withAttributes: attrs
            )
            ctx.restoreGState()

        case .mosaic:
            guard pts.count >= 2 else { break }
            let strokePath = CGMutablePath()
            strokePath.move(to: pts[0])
            for p in pts.dropFirst() {
                strokePath.addLine(to: p)
            }
            let strokedMaskPath = strokePath.copy(
                strokingWithWidth: lw,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )

            ctx.saveGState()
            ctx.addPath(strokedMaskPath)
            ctx.clip()

            let pixelated = forceMosaicFallbackForTesting ? nil : (pixelatedBaseImage ?? MosaicRenderer.createPixelatedImage(from: baseImage))
            if let pixImg = pixelated,
               let tiff = pixImg.tiffRepresentation,
               let bmp = NSBitmapImageRep(data: tiff),
               let cgPix = bmp.cgImage {
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1.0, y: -1.0)
                ctx.interpolationQuality = .none
                ctx.draw(cgPix, in: CGRect(origin: .zero, size: size))
            } else {
                // Fail-closed redaction: if pixelation cannot be produced, paint opaque dark blocks rather than leaving underlying pixels exposed
                ctx.setFillColor(NSColor(calibratedWhite: 0.12, alpha: 1.0).cgColor)
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            ctx.restoreGState()

        case .text:
            let pos = pts[0]
            let fontSize = max(12.0, item.lineWidth) * scaleMultiplier
            let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: item.color
            ]
            if item.textBackgroundStyle == .transparent {
                let textShadow = NSShadow()
                textShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
                textShadow.shadowBlurRadius = 2.0
                textShadow.shadowOffset = NSSize(width: 0, height: -1)
                attrs[.shadow] = textShadow
            }
            let textSize = (item.text as NSString).size(withAttributes: attrs)
            ctx.saveGState()
            // pos is the TOP-LEFT corner of the text glyph box in top-down coordinates.
            // Flipping Y at (pos.x, pos.y) puts y=0 at pos.y and y<0 downward (towards bottom of image).
            // So the text box occupies x: [0, textSize.width], y: [-textSize.height, 0].
            ctx.translateBy(x: pos.x, y: pos.y)
            ctx.scaleBy(x: 1.0, y: -1.0)
            if let bgFill = item.textBackgroundStyle.fillNSColor {
                let padX: CGFloat = 8.0 * scaleMultiplier
                let padY: CGFloat = 4.0 * scaleMultiplier
                let pillRect = CGRect(
                    x: -padX,
                    y: -textSize.height - padY,
                    width: textSize.width + padX * 2,
                    height: textSize.height + padY * 2
                )
                let radius: CGFloat = 6.0 * scaleMultiplier
                let path = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.5, color: NSColor.black.withAlphaComponent(0.28).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(bgFill.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            (item.text as NSString).draw(at: CGPoint(x: 0, y: -textSize.height), withAttributes: attrs)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    @discardableResult
    func copyToClipboard() -> Bool {
        commitPendingText()
        guard let img = renderCompositeImage() else {
            showToast(L10n.toastRenderFailedRefusedExport)
            return false
        }
        let pboard = ClotheslineManager.shared.pasteboardProvider()
        guard ClipboardHelper.copyImages([img], pasteboard: pboard, tempDir: ClotheslineManager.shared.tempDirOverride) else {
            showToast(L10n.toastCopyFailed)
            return false
        }
        showToast(L10n.toastCopiedSingleImage)
        return true
    }

    func clipToClothesline() {
        ClotheslineManager.shared.clipToLine(vm: self)
    }

    func saveToFile() {
        commitPendingText()
        guard let img = renderCompositeImage() else {
            showToast(L10n.toastRenderFailedCannotSave)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        panel.nameFieldStringValue = "ClipLine_\(formatter.string(from: Date())).png"
        panel.level = .screenSaver

        if panel.runModal() == .OK, let url = panel.url {
            if let png = ClipboardHelper.pngData(from: img),
               (try? png.write(to: url, options: .atomic)) != nil {
                showToast(L10n.toastSavedSingleImage)
            } else {
                showToast(L10n.toastSaveFailedCheckPermissions)
            }
        }
    }

    private static var strictQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=+#/?;")
        return set
    }()

    static func encodeQueryValue(_ text: String) -> String? {
        text.addingPercentEncoding(withAllowedCharacters: strictQueryValueAllowed)
    }

    static func buildCustomTranslationURL(template: String, text: String) -> URL? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("{text}"), let encoded = encodeQueryValue(text) else { return nil }
        let urlStr = trimmed.replacingOccurrences(of: "{text}", with: encoded)
        guard let url = URL(string: urlStr),
              let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if scheme == "http",
           let host = url.host?.lowercased(),
           host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return url
        }
        return nil
    }

    static func buildGoogleTranslateURL(text: String, targetLang: String = AppLanguage.resolveTranslateTargetLanguage()) -> URL? {
        var components = URLComponents(string: "https://translate.google.com/")
        components?.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: targetLang),
            URLQueryItem(name: "text", value: text)
        ]
        return components?.url
    }

    private static var configuredDaemonName: String {
        let envName = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_DAEMON"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return envName.isEmpty ? "gloss-daemon" : envName
    }

    private static func isTranslationDaemonRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", configuredDaemonName]
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    static func hasStoredWebTranslateConsent(for destinationHost: String, defaults: UserDefaults = .standard) -> Bool {
        let key = "ClipLineAllowWebTranslateFallback_\(destinationHost)"
        if defaults.bool(forKey: key) {
            return true
        }
        // Legacy global key is ONLY honored for the default Google Translate destination, never for custom hosts
        if destinationHost == "translate.google.com" && defaults.bool(forKey: "ClipLineAllowWebTranslateFallback") {
            return true
        }
        return false
    }

    private static func confirmWebTranslateIfNeeded(destinationHost: String = "translate.google.com") -> Bool {
        if hasStoredWebTranslateConsent(for: destinationHost) {
            return true
        }
        let key = "ClipLineAllowWebTranslateFallback_\(destinationHost)"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.alertWebTranslateTitle
        alert.informativeText = L10n.alertWebTranslateBody(destinationHost: destinationHost)
        alert.addButton(withTitle: L10n.alertWebTranslateAllowButton)
        alert.addButton(withTitle: L10n.alertWebTranslateCopyOnlyButton)
        if alert.runModal() == .alertFirstButtonReturn {
            UserDefaults.standard.set(true, forKey: key)
            return true
        }
        return false
    }

    private func triggerSmartTranslation(for text: String, pasteboard: NSPasteboard) {
        if Self.isTranslationDaemonRunning() {
            showToast(L10n.toastTranslatedViaDaemon)
            for channel in NotificationChannels.translateChannels {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name(channel),
                    object: nil,
                    userInfo: ["text": text],
                    deliverImmediately: true
                )
            }
            return
        }

        // Fallback 1: Custom URL template via CLIP_LINE_TRANSLATE_URL (only HTTPS or localhost HTTP)
        let customTemplate = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_URL"]
            ?? UserDefaults.standard.string(forKey: "TranslateURLTemplate")
        if let template = customTemplate,
           let url = Self.buildCustomTranslationURL(template: template, text: text) {
            let host = url.host ?? "custom-translate"
            let isLocal = (host == "localhost" || host == "127.0.0.1" || host == "::1")
            if !isLocal {
                guard Self.confirmWebTranslateIfNeeded(destinationHost: host) else {
                    showToast(L10n.toastOCRCopiedCancelledWebTranslate)
                    return
                }
            }
            showToast(L10n.toastOCRCopiedOpenedCustomTranslate)
            NSWorkspace.shared.open(url)
            return
        }

        // Fallback 2: macOS system Translation service if registered, else Google Translate web fallback (with first-time consent)
        if NSPerformService("Translate", pasteboard) {
            showToast(L10n.toastOCRCopiedOpenedSystemTranslate)
            return
        }

        guard Self.confirmWebTranslateIfNeeded(destinationHost: "translate.google.com") else {
            showToast(L10n.toastOCRCopiedCancelledWebTranslate)
            return
        }

        if let url = Self.buildGoogleTranslateURL(text: text) {
            showToast(L10n.toastOCRCopiedOpenedWebTranslate)
            NSWorkspace.shared.open(url)
        }
    }

    func cancelActiveOCR() {
        activeOCRTask?.cancel()
        activeOCRTask = nil
        isPerformingOCR = false
    }

    func applyOCRResult(_ recognized: String, andTranslate: Bool, expectedChangeCount: Int, pasteboard: NSPasteboard) {
        guard !isClosed else { return }
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showToast(L10n.toastOCRNoTextFound)
            return
        }
        guard pasteboard.changeCount == expectedChangeCount else {
            showToast(L10n.toastOCRClipboardChangedSkipped)
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(trimmed, forType: .string)
        if andTranslate {
            triggerSmartTranslation(for: trimmed, pasteboard: pasteboard)
        } else {
            showToast(L10n.toastOCRTextCopied)
        }
    }

    func runOCR(andTranslate: Bool = false) {
        guard !isPerformingOCR, !isClosed else { return }
        commitPendingText()
        guard let composite = renderCompositeImage(),
              let tiff = composite.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgImage = bitmap.cgImage
        else {
            showToast(L10n.toastUnableToReadImage)
            return
        }

        let initialChangeCount = ClotheslineManager.shared.pasteboardProvider().changeCount

        isPerformingOCR = true
        showToast(L10n.toastOCRInProgress(andTranslate: andTranslate))

        activeOCRTask = Task.detached { [weak self] in
            if Task.isCancelled { return }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, !self.isClosed else { return }
                    self.isPerformingOCR = false
                    self.activeOCRTask = nil
                    self.showToast(L10n.toastOCRError)
                }
                return
            }

            if Task.isCancelled { return }
            let recognized = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            await MainActor.run { [weak self] in
                guard let self = self, !self.isClosed, !Task.isCancelled else { return }
                self.isPerformingOCR = false
                self.activeOCRTask = nil
                self.applyOCRResult(
                    recognized,
                    andTranslate: andTranslate,
                    expectedChangeCount: initialChangeCount,
                    pasteboard: ClotheslineManager.shared.pasteboardProvider()
                )
            }
        }
    }

    func updateZoom(delta: CGFloat) {
        let newScale = max(0.35, min(3.0, scale + delta))
        scale = newScale
        guard let panel = hostingPanel else { return }
        let newW = round(baseSize.width * newScale + Self.canvasMargin * 2)
        let newH = round(baseSize.height * newScale + Self.canvasMargin * 2)
        var frame = panel.frame
        let center = CGPoint(x: frame.midX, y: frame.midY)
        frame.size = NSSize(width: newW, height: newH)
        frame.origin = CGPoint(x: round(center.x - frame.width / 2), y: round(center.y - frame.height / 2))
        panel.setFrame(frame, display: true)
        panel.canvasView?.needsDisplay = true
        updateToolbarPanelPosition()
    }
}
