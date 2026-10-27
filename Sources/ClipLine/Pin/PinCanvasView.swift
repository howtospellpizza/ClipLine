import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Pure AppKit Native PinCanvasNSView (100% Exact Geometry, Native Cursor Rects, Zero SwiftUI Clipping)

/// Custom NSTextField whose entire frame can be dragged to reposition the inline text box before pressing Enter
final class DraggableInlineTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Let PinCanvasNSView receive mouse events across the entire text field frame so dragging anywhere on the box moves it,
        // while keeping this field as the window's firstResponder for keyboard typing!
        return nil
    }
}

final class PinCanvasNSView: NSView, NSTextFieldDelegate {
    let vm: PinSessionViewModel
    private var trackingArea: NSTrackingArea?
    private var activeResizeHandle: PinSessionViewModel.ResizeHandle?
    private var resizeStartMouseScreen: NSPoint = .zero
    private var resizeStartCropRect: NSRect = .zero

    private var draggingTextAnnotationID: UUID?
    private var textDragStartMouseView: NSPoint = .zero
    private var textDragStartNormalizedPoints: [CGPoint] = []
    private var textDragDidMove: Bool = false

    func cancelActiveAnnotationDrag() {
        draggingTextAnnotationID = nil
        textDragStartNormalizedPoints = []
        textDragDidMove = false
    }

    private var isDraggingPendingField: Bool = false
    private var pendingDragStartMouseView: NSPoint = .zero
    private var pendingDragStartNormalizedPos: CGPoint = .zero

    private var isDraggingWindow: Bool = false
    private var windowDragStartMouseScreen: NSPoint = .zero
    private var windowDragStartOrigin: NSPoint = .zero

    private(set) var textField: NSTextField?

    init(frame: NSRect, vm: PinSessionViewModel) {
        self.vm = vm
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clearTextFieldReference() {
        self.textField = nil
    }

    func syncActiveTextStyle() {
        let nsColor = NSColor(vm.selectedColor)
        let font = NSFont.systemFont(ofSize: vm.strokePreset.textFontSize * vm.scale, weight: .bold)
        if let tf = textField {
            tf.textColor = nsColor
            tf.font = font
            // Keep NSTextField layer completely borderless & transparent — background pill and selection dash are drawn cleanly by PinCanvasNSView!
            tf.layer?.backgroundColor = NSColor.clear.cgColor
            tf.layer?.borderWidth = 0
            tf.layer?.borderColor = NSColor.clear.cgColor
            if let editor = window?.fieldEditor(false, for: tf) as? NSTextView {
                editor.textColor = nsColor
                editor.font = font
                editor.insertionPointColor = nsColor
                editor.drawsBackground = false
                var typing = editor.typingAttributes
                typing[.foregroundColor] = nsColor
                typing[.font] = font
                editor.typingAttributes = typing
                if let storage = editor.textStorage, storage.length > 0 {
                    let fullRange = NSRange(location: 0, length: storage.length)
                    storage.addAttributes([.foregroundColor: nsColor, .font: font], range: fullRange)
                }
            }
            updateInlineTextFieldPosition()
        }
        needsDisplay = true
    }

    func applyStyleChangeToSelectionOrField(updateColor: Bool, updatePreset: Bool, updateBackground: Bool) {
        if textField != nil {
            syncActiveTextStyle()
            return
        }
        if let selID = vm.selectedTextAnnotationID,
           let idx = vm.annotations.firstIndex(where: { $0.id == selID }) {
            let current = vm.annotations[idx]
            let tool = current.tool
            let nextColor = (updateColor && tool != .mosaic) ? NSColor(vm.selectedColor) : current.color
            let nextWidth: CGFloat = {
                guard updatePreset else { return current.lineWidth }
                return PinSessionViewModel.presetLineWidth(vm.strokePreset, for: tool)
            }()
            let nextBg: TextBackgroundStyle = (updateBackground && tool == .text) ? vm.textBackgroundStyle : current.textBackgroundStyle
            let didChange = nextColor != current.color || abs(nextWidth - current.lineWidth) > 0.001 || nextBg != current.textBackgroundStyle
            guard didChange else {
                needsDisplay = true
                return
            }
            vm.recordUndoSnapshot()
            vm.annotations[idx].color = nextColor
            vm.annotations[idx].lineWidth = nextWidth
            vm.annotations[idx].textBackgroundStyle = nextBg
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        } else {
            needsDisplay = true
        }
    }

    func pendingFieldHitRect() -> NSRect? {
        guard let tf = textField else { return nil }
        return tf.frame.insetBy(dx: -8, dy: -6)
    }

    func updateInlineTextFieldPosition() {
        guard let tf = textField, let normPt = vm.pendingTextNormalizedPos else { return }
        let imgRect = imageRectInView
        let fontSize = vm.strokePreset.textFontSize * vm.scale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let sampleStr = vm.pendingTextString.isEmpty ? L10n.inlineTextPlaceholder : vm.pendingTextString
        let measured = (sampleStr as NSString).size(withAttributes: [.font: font])
        let maxAvailW = max(56, imgRect.width - 4)
        let fieldW = min(maxAvailW, max(92, ceil(measured.width) + 22))
        let textH = max(measured.height, ("Ag" as NSString).size(withAttributes: [.font: font]).height)
        let fieldH: CGFloat = max(24, ceil(textH + 6))
        let padY = max(2, round((fieldH - textH) / 2.0))
        // Align tf so that the glyph top-left inside tf (tf.minX + 2, tf.maxY - padY) matches (rawX, rawY) within imgRect
        let rawX = imgRect.minX + normPt.x * imgRect.width - 2.0
        let rawY = imgRect.maxY - normPt.y * imgRect.height - fieldH + padY
        let minFieldX = imgRect.minX - 2.0
        let maxFieldX = max(minFieldX, imgRect.maxX - fieldW)
        let minFieldY = imgRect.minY
        let maxFieldY = max(minFieldY, imgRect.maxY - fieldH + padY)
        let clampedX = max(minFieldX, min(rawX, maxFieldX))
        let clampedY = max(minFieldY, min(rawY, maxFieldY))
        let actualNormX = max(0, min(1, (clampedX + 2.0 - imgRect.minX) / max(1, imgRect.width)))
        let actualNormY = max(0, min(1, (imgRect.maxY - (clampedY + fieldH - padY)) / max(1, imgRect.height)))
        vm.pendingTextNormalizedPos = CGPoint(x: actualNormX, y: actualNormY)
        tf.frame = NSRect(x: clampedX, y: clampedY, width: fieldW, height: fieldH)
        window?.invalidateCursorRects(for: self)
        vm.updateToolbarPanelPosition()
    }

    /// Bounding rect in view coordinates (bottom-left origin) for any committed annotation
    func textAnnotationHitRectInView(_ item: PinAnnotation) -> NSRect? {
        guard let normPt = item.points.first else { return nil }
        let imgRect = imageRectInView
        if item.tool == .counter {
            let diameter = max(18.0, item.lineWidth) * vm.scale
            let radius = diameter / 2.0 + 4.0
            let vx = imgRect.minX + normPt.x * imgRect.width
            let vy = imgRect.maxY - normPt.y * imgRect.height
            return NSRect(x: vx - radius, y: vy - radius, width: radius * 2.0, height: radius * 2.0)
        }
        if item.tool == .text {
            let fontSize = max(12.0, item.lineWidth) * vm.scale
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .bold)
            ]
            let textSize = (item.text as NSString).size(withAttributes: attrs)
            // In drawAnnotationInCGContext, normPt is the TOP-LEFT corner of the text box,
            // so in bottom-left view coordinates the text box spans:
            // x: [vx, vx + textSize.width], y: [vy - textSize.height, vy]
            let vx = imgRect.minX + normPt.x * imgRect.width
            let vy = imgRect.maxY - normPt.y * imgRect.height
            let padX: CGFloat = item.textBackgroundStyle == .transparent ? 8 : 10
            let padY: CGFloat = item.textBackgroundStyle == .transparent ? 6 : 8
            return NSRect(
                x: vx - padX,
                y: vy - textSize.height - padY,
                width: max(32, textSize.width + padX * 2),
                height: max(24, textSize.height + padY * 2)
            )
        }
        guard item.points.count >= 2 else { return nil }
        let viewPts = item.points.map {
            NSPoint(
                x: imgRect.minX + $0.x * imgRect.width,
                y: imgRect.maxY - $0.y * imgRect.height
            )
        }
        let minX = viewPts.map(\.x).min() ?? 0
        let maxX = viewPts.map(\.x).max() ?? 0
        let minY = viewPts.map(\.y).min() ?? 0
        let maxY = viewPts.map(\.y).max() ?? 0
        let basePad = max(6.0, (item.lineWidth * vm.scale) / 2.0 + 4.0)
        let pad = item.tool == .arrow ? max(basePad, max(12.0, item.lineWidth * 3.4) * vm.scale * 0.5 + 4.0) : basePad
        return NSRect(x: minX - pad, y: minY - pad, width: max(12, maxX - minX + pad * 2), height: max(12, maxY - minY + pad * 2))
    }

    private func distanceFromPoint(_ p: NSPoint, toSegmentStart a: NSPoint, end b: NSPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0.0001 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0.0, min(1.0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
    }

    private func isPointInTriangle(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint, _ c: NSPoint) -> Bool {
        let d1 = (p.x - b.x) * (a.y - b.y) - (a.x - b.x) * (p.y - b.y)
        let d2 = (p.x - c.x) * (b.y - c.y) - (b.x - c.x) * (p.y - c.y)
        let d3 = (p.x - a.x) * (c.y - a.y) - (c.x - a.x) * (p.y - a.y)
        let hasNeg = (d1 < 0) || (d2 < 0) || (d3 < 0)
        let hasPos = (d1 > 0) || (d2 > 0) || (d3 > 0)
        return !(hasNeg && hasPos)
    }

    private func hitTestAnnotationItem(_ item: PinAnnotation, viewPoint: NSPoint) -> Bool {
        if item.tool == .text || item.tool == .counter {
            return textAnnotationHitRectInView(item)?.contains(viewPoint) == true
        }
        guard item.points.count >= 2 else { return false }
        let imgRect = imageRectInView
        let viewPts = item.points.map {
            NSPoint(
                x: imgRect.minX + $0.x * imgRect.width,
                y: imgRect.maxY - $0.y * imgRect.height
            )
        }
        let tol = max(7.0, (item.lineWidth * vm.scale) / 2.0 + 5.0)
        switch item.tool {
        case .rect:
            let p0 = viewPts[0]
            let p1 = viewPts[viewPts.count - 1]
            let rect = NSRect(
                x: min(p0.x, p1.x),
                y: min(p0.y, p1.y),
                width: abs(p1.x - p0.x),
                height: abs(p1.y - p0.y)
            )
            let outer = rect.insetBy(dx: -tol, dy: -tol)
            guard outer.contains(viewPoint) else { return false }
            if rect.width > tol * 2 && rect.height > tol * 2 {
                let inner = rect.insetBy(dx: tol, dy: tol)
                return !inner.contains(viewPoint)
            }
            return true
        case .arrow:
            let p0 = viewPts[0]
            let p1 = viewPts[viewPts.count - 1]
            if distanceFromPoint(viewPoint, toSegmentStart: p0, end: p1) <= tol + 2.0 {
                return true
            }
            let angle = atan2(p1.y - p0.y, p1.x - p0.x)
            let headLength = max(12.0, item.lineWidth * 3.4) * vm.scale
            let arrowAngle: CGFloat = .pi / 6
            let w1 = NSPoint(
                x: p1.x - headLength * cos(angle - arrowAngle),
                y: p1.y - headLength * sin(angle - arrowAngle)
            )
            let w2 = NSPoint(
                x: p1.x - headLength * cos(angle + arrowAngle),
                y: p1.y - headLength * sin(angle + arrowAngle)
            )
            let headPad = max(5.0, tol * 0.6)
            return isPointInTriangle(viewPoint, p1, w1, w2) ||
                distanceFromPoint(viewPoint, toSegmentStart: p1, end: w1) <= headPad ||
                distanceFromPoint(viewPoint, toSegmentStart: p1, end: w2) <= headPad ||
                distanceFromPoint(viewPoint, toSegmentStart: w1, end: w2) <= headPad
        case .pen, .highlighter, .mosaic:
            for i in 0..<(viewPts.count - 1) {
                if distanceFromPoint(viewPoint, toSegmentStart: viewPts[i], end: viewPts[i + 1]) <= tol {
                    return true
                }
            }
            return false
        case .text, .counter:
            return false
        }
    }

    func hitTestTextAnnotationIndex(viewPoint: NSPoint) -> Int? {
        for idx in vm.annotations.indices.reversed() {
            if hitTestAnnotationItem(vm.annotations[idx], viewPoint: viewPoint) {
                return idx
            }
        }
        return nil
    }

    /// Exact rect of the displayed image in view coordinates (bottom-left origin)
    var imageRectInView: NSRect {
        let m = PinSessionViewModel.canvasMargin
        return NSRect(
            x: m,
            y: m,
            width: max(1, bounds.width - m * 2),
            height: max(1, bounds.height - m * 2)
        )
    }

    /// The 8 handle positions in view coordinates (bottom-left origin)
    func handlePointsInView() -> [(PinSessionViewModel.ResizeHandle, NSPoint)] {
        let r = imageRectInView
        return [
            (.topLeft, NSPoint(x: r.minX, y: r.maxY)),
            (.topCenter, NSPoint(x: r.midX, y: r.maxY)),
            (.topRight, NSPoint(x: r.maxX, y: r.maxY)),
            (.middleLeft, NSPoint(x: r.minX, y: r.midY)),
            (.middleRight, NSPoint(x: r.maxX, y: r.midY)),
            (.bottomLeft, NSPoint(x: r.minX, y: r.minY)),
            (.bottomCenter, NSPoint(x: r.midX, y: r.minY)),
            (.bottomRight, NSPoint(x: r.maxX, y: r.minY))
        ]
    }

    /// Hit-tests the 8 resize handles AND 4 border edges in view coordinates
    func hitTestResizeHandle(viewPoint: NSPoint) -> PinSessionViewModel.ResizeHandle? {
        guard vm.canAdjustCrop, vm.activeTool == nil else { return nil }

        // 1. Check the 8 handle dots with a generous 15pt radius
        let handleRadius: CGFloat = 15.0
        var bestHandle: PinSessionViewModel.ResizeHandle? = nil
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for (handle, pt) in handlePointsInView() {
            let d = hypot(viewPoint.x - pt.x, viewPoint.y - pt.y)
            if d <= handleRadius && d < bestDist {
                bestDist = d
                bestHandle = handle
            }
        }
        if let found = bestHandle {
            return found
        }

        // 2. Also allow grabbing anywhere along the 4 edges (within 8pt of the border)
        let r = imageRectInView
        let edgeTol: CGFloat = 8.0
        let inX = viewPoint.x >= r.minX - edgeTol && viewPoint.x <= r.maxX + edgeTol
        let inY = viewPoint.y >= r.minY - edgeTol && viewPoint.y <= r.maxY + edgeTol

        if inX && abs(viewPoint.y - r.maxY) <= edgeTol { return .topCenter }
        if inX && abs(viewPoint.y - r.minY) <= edgeTol { return .bottomCenter }
        if inY && abs(viewPoint.x - r.minX) <= edgeTol { return .middleLeft }
        if inY && abs(viewPoint.x - r.maxX) <= edgeTol { return .middleRight }

        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for item in vm.annotations {
            if let rect = textAnnotationHitRectInView(item) {
                addCursorRect(rect, cursor: NSCursor.openHand)
            }
        }
        if let fieldRect = pendingFieldHitRect() {
            addCursorRect(fieldRect, cursor: NSCursor.openHand)
        }
        guard vm.canAdjustCrop, vm.activeTool == nil else { return }

        let r = imageRectInView
        // Edge cursor rects
        addCursorRect(NSRect(x: r.minX + 12, y: r.maxY - 7, width: max(0, r.width - 24), height: 14), cursor: DirectionalCursor.northSouth)
        addCursorRect(NSRect(x: r.minX + 12, y: r.minY - 7, width: max(0, r.width - 24), height: 14), cursor: DirectionalCursor.northSouth)
        addCursorRect(NSRect(x: r.minX - 7, y: r.minY + 12, width: 14, height: max(0, r.height - 24)), cursor: DirectionalCursor.eastWest)
        addCursorRect(NSRect(x: r.maxX - 7, y: r.minY + 12, width: 14, height: max(0, r.height - 24)), cursor: DirectionalCursor.eastWest)

        // 8 handle cursor rects (28x28 each, overrides edges at corners/midpoints)
        for (handle, pt) in handlePointsInView() {
            let hRect = NSRect(x: pt.x - 14, y: pt.y - 14, width: 28, height: 28)
            addCursorRect(hRect, cursor: handle.cursor)
        }
    }

    private func updateCursorForViewPoint(_ pt: NSPoint) {
        if let handle = activeResizeHandle {
            handle.cursor.set()
            return
        }
        if draggingTextAnnotationID != nil || isDraggingPendingField {
            NSCursor.closedHand.set()
            return
        }
        if let fieldRect = pendingFieldHitRect(), fieldRect.contains(pt) {
            NSCursor.openHand.set()
            return
        }
        if hitTestTextAnnotationIndex(viewPoint: pt) != nil {
            NSCursor.openHand.set()
            return
        }
        if let handle = hitTestResizeHandle(viewPoint: pt) {
            handle.cursor.set()
        } else if vm.activeTool != nil && imageRectInView.contains(pt) {
            NSCursor.crosshair.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursorForViewPoint(pt)
    }

    override func cursorUpdate(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        updateCursorForViewPoint(pt)
    }

    override func mouseExited(with event: NSEvent) {
        if activeResizeHandle == nil {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        window?.makeKeyAndOrderFront(nil)
        let pt = convert(event.locationInWindow, from: nil)
        let screenPt = NSEvent.mouseLocation

        // 0. If an inline text field is currently open, touching/dragging ANYWHERE on the text box repositions it BEFORE pressing Enter
        if let fieldRect = pendingFieldHitRect(), fieldRect.contains(pt),
           let normPos = vm.pendingTextNormalizedPos {
            isDraggingPendingField = true
            pendingDragStartMouseView = pt
            pendingDragStartNormalizedPos = normPos
            NSCursor.closedHand.set()
            return
        }

        // 1. Check 8 resize handles & 4 borders first!
        if let handle = hitTestResizeHandle(viewPoint: pt),
           let cropRect = vm.cropScreenRect {
            activeResizeHandle = handle
            resizeStartMouseScreen = screenPt
            resizeStartCropRect = cropRect
            handle.cursor.set()
            return
        }

        let imgRect = imageRectInView
        guard imgRect.contains(pt) else { return }

        // 2. Check if clicking/dragging ANY existing annotation
        if let initialHitIdx = hitTestTextAnnotationIndex(viewPoint: pt) {
            let clickedAnnotationID = vm.annotations[initialHitIdx].id
            vm.commitPendingText()
            guard let resolvedHitIdx = vm.annotations.firstIndex(where: { $0.id == clickedAnnotationID }) else {
                needsDisplay = true
                return
            }
            let hitItem = vm.annotations[resolvedHitIdx]
            vm.selectedTextAnnotationID = hitItem.id
            if hitItem.tool == .text && event.clickCount == 2 {
                // Double-click existing text annotation to re-edit in place (non-destructively until committed)
                vm.editingExistingTextAnnotationID = hitItem.id
                vm.editingOriginalAnnotationSnapshot = hitItem
                vm.selectedTextAnnotationID = nil
                vm.selectedColor = Color(nsColor: hitItem.color)
                if let matchedPreset = StrokePreset.allCases.min(by: { abs($0.textFontSize - hitItem.lineWidth) < abs($1.textFontSize - hitItem.lineWidth) }) {
                    vm.strokePreset = matchedPreset
                }
                vm.textBackgroundStyle = hitItem.textBackgroundStyle
                let normPt = hitItem.points.first ?? CGPoint(x: 0.5, y: 0.5)
                showInlineTextField(atNormalized: normPt, in: imgRect, initialText: hitItem.text)
                needsDisplay = true
                return
            }
            draggingTextAnnotationID = hitItem.id
            textDragStartMouseView = pt
            textDragStartNormalizedPoints = hitItem.points
            textDragDidMove = false
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        vm.selectedTextAnnotationID = nil

        // 3. If an annotation tool is active, start drawing or placing text / step counter
        if let tool = vm.activeTool {
            let nx = max(0, min(1, (pt.x - imgRect.minX) / imgRect.width))
            // Normalized Y is top-down (0 = top, 1 = bottom)
            let ny = max(0, min(1, (imgRect.maxY - pt.y) / imgRect.height))
            let normPt = CGPoint(x: nx, y: ny)

            if tool == .text {
                if textField != nil {
                    // Clicking outside while editing commits current text first without immediately opening a blank box
                    vm.commitPendingText()
                    return
                }
                showInlineTextField(atNormalized: normPt, in: imgRect)
                return
            }

            if tool == .counter {
                vm.commitPendingText()
                vm.recordUndoSnapshot()
                let label = vm.nextCounterLabel
                let newBadge = PinAnnotation(
                    tool: .counter,
                    color: NSColor(vm.selectedColor),
                    lineWidth: vm.strokePreset.counterBadgeDiameter,
                    points: [normPt],
                    text: label
                )
                vm.annotations.append(newBadge)
                vm.selectedTextAnnotationID = newBadge.id
                draggingTextAnnotationID = newBadge.id
                textDragStartMouseView = pt
                textDragStartNormalizedPoints = [normPt]
                textDragDidMove = true
                window?.invalidateCursorRects(for: self)
                needsDisplay = true
                return
            }

            vm.currentDragPoints = [normPt, normPt]
            needsDisplay = true
            return
        }

        // 4. Otherwise, single-drag moves the floating pin window (use Space to toggle toolbar)
        isDraggingWindow = true
        windowDragStartMouseScreen = screenPt
        windowDragStartOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let screenPt = NSEvent.mouseLocation

        if isDraggingPendingField {
            let pt = convert(event.locationInWindow, from: nil)
            let imgRect = imageRectInView
            let dxNorm = (pt.x - pendingDragStartMouseView.x) / max(1, imgRect.width)
            let dyNorm = (pendingDragStartMouseView.y - pt.y) / max(1, imgRect.height)
            let newX = max(0.0, min(0.95, pendingDragStartNormalizedPos.x + dxNorm))
            let newY = max(0.02, min(0.95, pendingDragStartNormalizedPos.y + dyNorm))
            vm.pendingTextNormalizedPos = CGPoint(x: newX, y: newY)
            updateInlineTextFieldPosition()
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        if let handle = activeResizeHandle {
            handle.cursor.set()
            vm.applyResize(
                handle: handle,
                startMouse: resizeStartMouseScreen,
                startCropRect: resizeStartCropRect,
                currentMouse: screenPt
            )
            return
        }

        if let dragID = draggingTextAnnotationID {
            guard let textIdx = vm.annotations.firstIndex(where: { $0.id == dragID }),
                  !textDragStartNormalizedPoints.isEmpty else {
                cancelActiveAnnotationDrag()
                return
            }
            if !textDragDidMove {
                vm.recordUndoSnapshot()
            }
            let pt = convert(event.locationInWindow, from: nil)
            let imgRect = imageRectInView
            let dxNorm = (pt.x - textDragStartMouseView.x) / max(1, imgRect.width)
            let dyNorm = (textDragStartMouseView.y - pt.y) / max(1, imgRect.height)
            let startPts = textDragStartNormalizedPoints
            if startPts.count == 1 {
                let newX = max(0.0, min(0.98, startPts[0].x + dxNorm))
                let newY = max(0.02, min(0.98, startPts[0].y + dyNorm))
                vm.annotations[textIdx].points = [CGPoint(x: newX, y: newY)]
            } else {
                let minX = startPts.map(\.x).min() ?? 0
                let maxX = startPts.map(\.x).max() ?? 1
                let minY = startPts.map(\.y).min() ?? 0
                let maxY = startPts.map(\.y).max() ?? 1
                let clampedDX = max(-minX, min(1.0 - maxX, dxNorm))
                let clampedDY = max(-minY, min(1.0 - maxY, dyNorm))
                vm.annotations[textIdx].points = startPts.map {
                    CGPoint(x: $0.x + clampedDX, y: $0.y + clampedDY)
                }
            }
            textDragDidMove = true
            NSCursor.closedHand.set()
            needsDisplay = true
            return
        }

        if let tool = vm.activeTool, tool != .text, tool != .counter, !vm.currentDragPoints.isEmpty {
            let pt = convert(event.locationInWindow, from: nil)
            let imgRect = imageRectInView
            let nx = max(0, min(1, (pt.x - imgRect.minX) / imgRect.width))
            let ny = max(0, min(1, (imgRect.maxY - pt.y) / imgRect.height))
            let rawNormPt = CGPoint(x: nx, y: ny)
            let isShiftPressed = event.modifierFlags.contains(.shift)

            if tool == .rect || tool == .arrow {
                let startNormPt = vm.currentDragPoints[0]
                let endNormPt = isShiftPressed
                    ? PinSessionViewModel.constrainedNormalizedEndPoint(
                        for: tool,
                        start: startNormPt,
                        rawEnd: rawNormPt,
                        canvasSize: imgRect.size
                    )
                    : rawNormPt
                vm.currentDragPoints[vm.currentDragPoints.count - 1] = endNormPt
            } else {
                vm.currentDragPoints.append(rawNormPt)
            }
            needsDisplay = true
            return
        }

        if isDraggingWindow, let win = window {
            let newOrigin = NSPoint(
                x: round(windowDragStartOrigin.x + (screenPt.x - windowDragStartMouseScreen.x)),
                y: round(windowDragStartOrigin.y + (screenPt.y - windowDragStartMouseScreen.y))
            )
            if newOrigin != windowDragStartOrigin {
                vm.hasMovedWindow = true
                needsDisplay = true
            }
            win.setFrameOrigin(newOrigin)
            vm.updateToolbarPanelPosition()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        if isDraggingPendingField {
            isDraggingPendingField = false
            window?.invalidateCursorRects(for: self)
            updateCursorForViewPoint(pt)
            return
        }

        if activeResizeHandle != nil {
            activeResizeHandle = nil
            vm.finishResize()
            updateCursorForViewPoint(pt)
            return
        }

        if draggingTextAnnotationID != nil {
            cancelActiveAnnotationDrag()
            window?.invalidateCursorRects(for: self)
            updateCursorForViewPoint(pt)
            return
        }

        if let tool = vm.activeTool, tool != .text, tool != .counter, !vm.currentDragPoints.isEmpty {
            if vm.currentDragPoints.count >= 2 {
                vm.recordUndoSnapshot()
                let created = PinAnnotation(
                    tool: tool,
                    color: NSColor(vm.selectedColor),
                    lineWidth: vm.currentToolLineWidth,
                    points: vm.currentDragPoints
                )
                vm.annotations.append(created)
                vm.selectedTextAnnotationID = created.id
            }
            vm.currentDragPoints = []
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            return
        }

        if isDraggingWindow {
            isDraggingWindow = false
            window?.invalidateCursorRects(for: self)
            updateCursorForViewPoint(pt)
        }
    }

    func showInlineTextField(atNormalized normPt: CGPoint, in imgRect: NSRect, initialText: String = "") {
        textField?.removeFromSuperview()
        vm.pendingTextNormalizedPos = normPt
        vm.pendingTextString = initialText

        let fontSize = vm.strokePreset.textFontSize * vm.scale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)
        let sampleStr = initialText.isEmpty ? L10n.inlineTextPlaceholder : initialText
        let measured = (sampleStr as NSString).size(withAttributes: [.font: font])
        let textH = max(measured.height, ("Ag" as NSString).size(withAttributes: [.font: font]).height)
        let maxAvailW = max(56, imgRect.width - 4)
        let fieldW = min(maxAvailW, max(92, ceil(measured.width) + 22))
        let fieldH: CGFloat = max(24, ceil(textH + 6))
        let padY = max(2, round((fieldH - textH) / 2.0))
        let rawX = imgRect.minX + normPt.x * imgRect.width - 2.0
        let rawY = imgRect.maxY - normPt.y * imgRect.height - fieldH + padY
        let minFieldX = imgRect.minX - 2.0
        let maxFieldX = max(minFieldX, imgRect.maxX - fieldW)
        let minFieldY = imgRect.minY
        let maxFieldY = max(minFieldY, imgRect.maxY - fieldH + padY)
        let clampedX = max(minFieldX, min(rawX, maxFieldX))
        let clampedY = max(minFieldY, min(rawY, maxFieldY))
        // Sync pendingTextNormalizedPos with any clamping so committing matches exact visual field position
        let actualNormX = max(0, min(1, (clampedX + 2.0 - imgRect.minX) / max(1, imgRect.width)))
        let actualNormY = max(0, min(1, (imgRect.maxY - (clampedY + fieldH - padY)) / max(1, imgRect.height)))
        vm.pendingTextNormalizedPos = CGPoint(x: actualNormX, y: actualNormY)

        let tf = DraggableInlineTextField(frame: NSRect(
            x: clampedX,
            y: clampedY,
            width: fieldW,
            height: fieldH
        ))
        tf.stringValue = initialText
        tf.font = font
        tf.textColor = NSColor(vm.selectedColor)
        tf.backgroundColor = .clear
        tf.drawsBackground = false
        tf.isBordered = false
        tf.focusRingType = .none
        tf.wantsLayer = true
        tf.layer?.backgroundColor = NSColor.clear.cgColor
        tf.layer?.borderWidth = 0
        tf.placeholderString = L10n.inlineTextPlaceholder
        tf.delegate = self
        addSubview(tf)
        window?.makeFirstResponder(tf)
        self.textField = tf
        syncActiveTextStyle()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            vm.cancelPendingTextEditing()
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        vm.pendingTextString = tf.stringValue
        updateInlineTextFieldPosition()
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let tf = obj.object as? NSTextField else { return }
        vm.pendingTextString = tf.stringValue
        tf.removeFromSuperview()
        self.textField = nil
        vm.commitPendingText()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard imageRectInView.contains(pt) else { return }
        if let hitIdx = hitTestTextAnnotationIndex(viewPoint: pt) {
            let targetID = vm.annotations[hitIdx].id
            vm.commitPendingText()
            _ = vm.removeAnnotation(id: targetID)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let imgRect = imageRectInView

        ctx.saveGState()
        ctx.setAlpha(CGFloat(vm.windowOpacity))

        // Subtle drop shadow around the image rect
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 8, color: NSColor.black.withAlphaComponent(0.38).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(imgRect)
        ctx.restoreGState()

        // 1. Draw base screenshot image
        vm.baseImage.draw(in: imgRect)

        // 2. Draw annotations clipped to imgRect (using top-left normalized coordinates)
        ctx.saveGState()
        ctx.clip(to: imgRect)
        ctx.translateBy(x: imgRect.minX, y: imgRect.maxY)
        ctx.scaleBy(x: 1.0, y: -1.0)

        for item in vm.annotations where item.id != vm.editingExistingTextAnnotationID {
            vm.drawAnnotationInCGContext(item, ctx: ctx, size: imgRect.size, scaleMultiplier: vm.scale)
        }
        if let tool = vm.activeTool, !vm.currentDragPoints.isEmpty {
            let temp = PinAnnotation(
                tool: tool,
                color: NSColor(vm.selectedColor),
                lineWidth: vm.currentToolLineWidth,
                points: vm.currentDragPoints
            )
            vm.drawAnnotationInCGContext(temp, ctx: ctx, size: imgRect.size, scaleMultiplier: vm.scale)
        }
        ctx.restoreGState()

        // 2b. Highlight selected committed text annotation OR active inline text field (using neutral system-blue dash, never text color!)
        let accent = NSColor(calibratedRed: 0.15, green: 0.62, blue: 1.0, alpha: 0.95)
        if let tf = textField {
            // If solid pill background is chosen (.black / .white), render the exact rounded pill behind the active text field
            if let bgFill = vm.textBackgroundStyle.fillNSColor {
                let pillRect = tf.frame.insetBy(dx: -4, dy: -1)
                let radius: CGFloat = 6.0 * vm.scale
                let pillPath = CGPath(roundedRect: pillRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 3.5, color: NSColor.black.withAlphaComponent(0.28).cgColor)
                ctx.addPath(pillPath)
                ctx.setFillColor(bgFill.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            // Subtle neutral selection frame while editing
            let frameRect = tf.frame.insetBy(dx: -4, dy: -1)
            ctx.saveGState()
            ctx.setStrokeColor(accent.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            let dashPath = CGPath(roundedRect: frameRect, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(dashPath)
            ctx.strokePath()
            ctx.restoreGState()
        } else if let selID = vm.selectedTextAnnotationID,
                  let selItem = vm.annotations.first(where: { $0.id == selID }),
                  let hitRect = textAnnotationHitRectInView(selItem) {
            ctx.saveGState()
            ctx.setStrokeColor(accent.withAlphaComponent(0.85).cgColor)
            ctx.setLineWidth(1.2)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            let dashPath: CGPath
            if selItem.tool == .counter {
                dashPath = CGPath(ellipseIn: hitRect.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            } else {
                dashPath = CGPath(roundedRect: hitRect.insetBy(dx: 2, dy: 2), cornerWidth: 5, cornerHeight: 5, transform: nil)
            }
            ctx.addPath(dashPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        // 3. Draw crisp 4-sided accent border around imageRectInView (never clipped!)
        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(imgRect)
        ctx.restoreGState()

        // 4. Draw 8 resize handle circles when in crop-adjust mode
        if vm.canAdjustCrop && vm.activeTool == nil {
            for (_, pt) in handlePointsInView() {
                let dotRect = CGRect(x: pt.x - 5.0, y: pt.y - 5.0, width: 10.0, height: 10.0)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dotRect)
                ctx.restoreGState()

                ctx.saveGState()
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(2.2)
                ctx.strokeEllipse(in: dotRect)
                ctx.restoreGState()
            }
        }

        // 5. Draw Toast or Zoom badge if present
        if let toast = vm.toastMessage {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let sz = (toast as NSString).size(withAttributes: attrs)
            let bRect = CGRect(x: imgRect.minX + 8, y: imgRect.maxY - sz.height - 14, width: sz.width + 16, height: sz.height + 6)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: bRect, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            (toast as NSString).draw(at: NSPoint(x: bRect.minX + 8, y: bRect.minY + 3), withAttributes: attrs)
        }

        ctx.restoreGState()
    }
}
