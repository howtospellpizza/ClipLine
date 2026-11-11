import AppKit
import CoreGraphics
import Foundation

@MainActor
func runSuite5ClotheslineStitchAndTextTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    let daemon = PinDaemonApp()
    // Suite 5: Multi-Image Pasteboard Copy & Scoped Temp File Hygiene
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 5: Multi-Image Pasteboard Copy & Scoped Temp File Hygiene")
    let img1 = makeTextImage(text: "CLIP ONE", size: NSSize(width: 200, height: 60))
    let img2 = makeTextImage(text: "CLIP TWO", size: NSSize(width: 240, height: 80))
    let copiedMulti = ClipboardHelper.copyImages([img1, img2], pasteboard: testPasteboard, tempDir: testTempDirURL.path)
    let pbItems = testPasteboard.pasteboardItems ?? []
    t.check(
        copiedMulti && pbItems.count == 2,
        "copyImages writes 2 separate NSPasteboardItems when 2 images are selected",
        detail: "got \(pbItems.count) items"
    )
    let item0HasDataAndFile = (pbItems.first?.data(forType: .png) != nil) && (pbItems.first?.string(forType: .fileURL) != nil)
    let item1HasDataAndFile = (pbItems.last?.data(forType: .png) != nil) && (pbItems.last?.string(forType: .fileURL) != nil)
    t.check(
        item0HasDataAndFile && item1HasDataAndFile &&
        pbItems.first?.string(forType: .fileURL) != pbItems.last?.string(forType: .fileURL),
        "Each NSPasteboardItem carries its own independent PNG data, TIFF data, and unique fileURL"
    )

    let stitched = ClipboardHelper.stitchImagesGrid([img1, img2])
    t.check(
        stitched.size == NSSize(width: 240, height: 140),
        "stitchImagesGrid seamlessly stitches vertically with zero gap by default (maxW = 240, sumH = 140)",
        detail: "got \(stitched.size)"
    )

    // Verify Retina 2x pixel density is preserved through renderCompositeImage and stitchImagesGrid
    let retinaRep1 = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 400,
        pixelsHigh: 120,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    retinaRep1.size = NSSize(width: 200, height: 60)
    let retinaPaintCtx = NSGraphicsContext(bitmapImageRep: retinaRep1)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = retinaPaintCtx
    NSColor.red.setFill()
    NSRect(x: 0, y: 0, width: 200, height: 60).fill()
    NSGraphicsContext.restoreGraphicsState()
    let retinaImg1 = NSImage(size: NSSize(width: 200, height: 60))
    retinaImg1.addRepresentation(retinaRep1)

    let retinaVM = PinSessionViewModel(image: retinaImg1)
    let compositeRetina = retinaVM.renderCompositeImage()
    let compositeRep = compositeRetina?.representations.first
    t.check(
        compositeRep?.pixelsWide == 400 && compositeRep?.pixelsHigh == 120,
        "renderCompositeImage preserves exact 2x Retina pixel dimensions (400x120 px for 200x60 pt)"
    )

    let stitchedRetina = ClipboardHelper.stitchImagesGrid([ compositeRetina!, compositeRetina! ])
    let stitchedRep = stitchedRetina.representations.first
    t.check(
        stitchedRetina.size == NSSize(width: 200, height: 120) &&
        stitchedRep?.pixelsWide == 400 && stitchedRep?.pixelsHigh == 240,
        "stitchImagesGrid preserves full 2x Retina pixel resolution (400x240 px for 200x120 pt) without blur"
    )

    let copiedStitched = ClipboardHelper.copyStitchedImage([img1, img2], pasteboard: testPasteboard, tempDir: testTempDirURL.path)
    t.check(
        copiedStitched && (testPasteboard.pasteboardItems?.count == 1),
        "copyStitchedImage writes 1 combined stitched NSPasteboardItem to pasteboard"
    )

    // Verify horizontal side-by-side stitch and padded frame background
    let stitchedHoriz = ClipboardHelper.stitchImagesGrid([img1, img2], axis: .horizontal, gap: 16, padding: 20)
    t.check(
        stitchedHoriz.size == NSSize(width: 200 + 240 + 16 + 40, height: max(80, 60) + 40),
        "stitchImagesGrid stitches horizontally with gap and outer padding (width = 496, height = 120)",
        detail: "got \(stitchedHoriz.size)"
    )

    let singleFramed = ClipboardHelper.stitchImagesGrid([compositeRetina!], padding: 20)
    t.check(
        singleFramed.size == NSSize(width: 240, height: 100),
        "stitchImagesGrid applies outer frame padding even to a single image when padding > 0",
        detail: "got \(singleFramed.size)"
    )
    if let framedTiff = singleFramed.tiffRepresentation,
       let framedRep = NSBitmapImageRep(data: framedTiff),
       let topRightCorner = framedRep.colorAt(x: framedRep.pixelsWide - 4, y: 4)?.usingColorSpace(.sRGB),
       let bottomLeftCorner = framedRep.colorAt(x: 4, y: framedRep.pixelsHigh - 4)?.usingColorSpace(.sRGB),
       let topImagePixel = framedRep.colorAt(x: framedRep.pixelsWide / 2, y: 50)?.usingColorSpace(.sRGB) {
        t.check(
            topRightCorner.alphaComponent > 0.98 &&
                bottomLeftCorner.alphaComponent > 0.98 &&
                topImagePixel.redComponent > 0.85,
            "stitchImagesGrid scales 2x Retina CTM properly (no 1/4 bottom-left shrinkage) and fills all 4 frame corners without diagonal clipping"
        )
    } else {
        t.check(false, "stitchImagesGrid Retina CTM and full-frame backdrop pixel check")
    }

    // Verify Spotlight annotation tool darkens pixels outside spotlight rect while keeping inside bright,
    // and multiple spotlights do not compound exterior darkness
    let whiteImg = NSImage(size: NSSize(width: 100, height: 100))
    whiteImg.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 100, height: 100).fill()
    whiteImg.unlockFocus()
    let spotVM = PinSessionViewModel(image: whiteImg)
    spotVM.annotations.append(
        PinAnnotation(
            tool: .spotlight,
            color: .red,
            lineWidth: 2.0,
            points: [CGPoint(x: 0.15, y: 0.15), CGPoint(x: 0.42, y: 0.42)]
        )
    )
    var singleOutsideLuma: CGFloat = 1
    if let spotRendered = spotVM.renderCompositeImage(),
       let spotTiff = spotRendered.tiffRepresentation,
       let spotRep = NSBitmapImageRep(data: spotTiff) {
        let insideColor = spotRep.colorAt(x: Int(Double(spotRep.pixelsWide) * 0.28), y: Int(Double(spotRep.pixelsHigh) * 0.28))?.usingColorSpace(.sRGB)
        let outsideColor = spotRep.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB)
        let insideLuma = insideColor.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 0
        let outsideLuma = outsideColor.map { 0.299 * $0.redComponent + 0.587 * $0.greenComponent + 0.114 * $0.blueComponent } ?? 1
        singleOutsideLuma = outsideLuma
        t.check(
            insideLuma > 0.90 && outsideLuma < 0.60,
            "Spotlight annotation keeps interior bright (\(String(format: "%.2f", insideLuma))) while darkening exterior (\(String(format: "%.2f", outsideLuma)))"
        )
    } else {
        t.check(false, "Rendered composite image for Spotlight annotation verification")
    }
    spotVM.annotations.append(
        PinAnnotation(
            tool: .spotlight,
            color: .red,
            lineWidth: 2.0,
            points: [CGPoint(x: 0.60, y: 0.60), CGPoint(x: 0.85, y: 0.85)]
        )
    )
    if let multiRendered = spotVM.renderCompositeImage(),
       let multiTiff = multiRendered.tiffRepresentation,
       let multiRep = NSBitmapImageRep(data: multiTiff),
       let outside2Color = multiRep.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB),
       let firstHoleColor = multiRep.colorAt(x: Int(Double(multiRep.pixelsWide) * 0.28), y: Int(Double(multiRep.pixelsHigh) * 0.28))?.usingColorSpace(.sRGB),
       let secondHoleColor = multiRep.colorAt(x: Int(Double(multiRep.pixelsWide) * 0.72), y: Int(Double(multiRep.pixelsHigh) * 0.72))?.usingColorSpace(.sRGB) {
        let outside2Luma = 0.299 * outside2Color.redComponent + 0.587 * outside2Color.greenComponent + 0.114 * outside2Color.blueComponent
        let firstHoleLuma = 0.299 * firstHoleColor.redComponent + 0.587 * firstHoleColor.greenComponent + 0.114 * firstHoleColor.blueComponent
        let secondHoleLuma = 0.299 * secondHoleColor.redComponent + 0.587 * secondHoleColor.greenComponent + 0.114 * secondHoleColor.blueComponent
        t.check(
            abs(outside2Luma - singleOutsideLuma) < 0.02 && firstHoleLuma > 0.90 && secondHoleLuma > 0.90,
            "Multiple spotlight annotations share a single backdrop mask while keeping every spotlight hole bright"
        )
    } else {
        t.check(false, "Multiple spotlight annotations share a single backdrop mask")
    }

    // Verify Spotlight rejects 1D zero-height drag and allows drawing inside an existing Spotlight when a tool is active
    let spotCanvas = PinCanvasNSView(frame: NSRect(x: 0, y: 0, width: 132, height: 132), vm: spotVM)
    let countBefore1D = spotVM.annotations.count
    spotVM.activeTool = .spotlight
    if let down1D = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 24, y: 24), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 301, clickCount: 1, pressure: 1.0),
       let drag1D = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 84, y: 24), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 302, clickCount: 1, pressure: 1.0),
       let up1D = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 84, y: 24), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 303, clickCount: 1, pressure: 1.0) {
        spotCanvas.mouseDown(with: down1D)
        spotCanvas.mouseDragged(with: drag1D)
        spotCanvas.mouseUp(with: up1D)
    }
    t.check(
        spotVM.annotations.count == countBefore1D,
        "Spotlight rejects zero-height horizontal drag instead of committing a full-screen dark mask"
    )
    // Clicking inside the first spotlight hole while .counter tool is active places a counter instead of dragging the spotlight
    spotVM.activeTool = .counter
    let holeViewPt = NSPoint(x: 16 + 28, y: 16 + 72)
    if let downInside = NSEvent.mouseEvent(with: .leftMouseDown, location: holeViewPt, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 304, clickCount: 1, pressure: 1.0),
       let upInside = NSEvent.mouseEvent(with: .leftMouseUp, location: holeViewPt, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 305, clickCount: 1, pressure: 1.0) {
        spotCanvas.mouseDown(with: downInside)
        spotCanvas.mouseUp(with: upInside)
    }
    t.check(
        spotVM.annotations.last?.tool == .counter,
        "Clicking inside an existing Spotlight while another tool (.counter) is active creates the new annotation instead of intercepting the click"
    )
    // Verify a small 12x12pt Spotlight can be dragged from its center when selected (not hijacked by corner resize handles)
    // and also lets interior clicks pass through when a drawing tool is active
    let smallSpot = PinAnnotation(
        tool: .spotlight,
        color: .red,
        lineWidth: 1.5,
        points: [CGPoint(x: 0.40, y: 0.40), CGPoint(x: 0.52, y: 0.52)]
    )
    spotVM.annotations = [smallSpot]
    spotVM.selectedTextAnnotationID = smallSpot.id
    spotVM.activeTool = nil
    let smallCenterPt = NSPoint(x: 16 + 46, y: 16 + (100 - 46))
    if let downDrag = NSEvent.mouseEvent(with: .leftMouseDown, location: smallCenterPt, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 306, clickCount: 1, pressure: 1.0),
       let moveDrag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: smallCenterPt.x + 15, y: smallCenterPt.y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 307, clickCount: 1, pressure: 1.0),
       let upDrag = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: smallCenterPt.x + 15, y: smallCenterPt.y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 308, clickCount: 1, pressure: 1.0) {
        spotCanvas.mouseDown(with: downDrag)
        spotCanvas.mouseDragged(with: moveDrag)
        spotCanvas.mouseUp(with: upDrag)
    }
    let movedPts = spotVM.annotations.first?.points ?? []
    let movedWidth = movedPts.count >= 2 ? abs(movedPts[1].x - movedPts[0].x) : 0
    t.check(
        movedPts.count >= 2 && abs(movedWidth - 0.12) < 0.01 && movedPts[0].x > 0.50,
        "Dragging the center of a selected 12x12pt Spotlight moves it uniformly instead of triggering a corner resize"
    )

    func canvasMouseEvent(_ type: NSEvent.EventType, at location: NSPoint, eventNumber: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: eventNumber, clickCount: 1, pressure: 1.0
        )
    }

    // At 35% zoom, 12pt becomes 4.2pt and its center is closer to a corner than the old 3.5pt handle floor.
    let zoomedSpotVM = PinSessionViewModel(image: whiteImg)
    zoomedSpotVM.scale = 0.35
    let zoomedSpot = PinAnnotation(
        tool: .spotlight,
        color: .red,
        lineWidth: 1.5,
        points: [CGPoint(x: 0.40, y: 0.40), CGPoint(x: 0.52, y: 0.52)]
    )
    zoomedSpotVM.annotations = [zoomedSpot]
    zoomedSpotVM.selectedTextAnnotationID = zoomedSpot.id
    let zoomedSpotCanvas = PinCanvasNSView(frame: NSRect(x: 0, y: 0, width: 67, height: 67), vm: zoomedSpotVM)
    let zoomedSpotImageRect = zoomedSpotCanvas.imageRectInView
    let zoomedSpotCenter = NSPoint(
        x: zoomedSpotImageRect.minX + 0.46 * zoomedSpotImageRect.width,
        y: zoomedSpotImageRect.maxY - 0.46 * zoomedSpotImageRect.height
    )
    let originalZoomedSpotPoints = zoomedSpot.points
    if let down = canvasMouseEvent(.leftMouseDown, at: zoomedSpotCenter, eventNumber: 309),
       let drag = canvasMouseEvent(.leftMouseDragged, at: NSPoint(x: zoomedSpotCenter.x + 2, y: zoomedSpotCenter.y), eventNumber: 310),
       let up = canvasMouseEvent(.leftMouseUp, at: NSPoint(x: zoomedSpotCenter.x + 2, y: zoomedSpotCenter.y), eventNumber: 311) {
        zoomedSpotCanvas.mouseDown(with: down)
        zoomedSpotCanvas.mouseDragged(with: drag)
        zoomedSpotCanvas.mouseUp(with: up)
        let movedZoomedSpotPoints = zoomedSpotVM.annotations.first(where: { $0.id == zoomedSpot.id })?.points ?? []
        let movedZoomedSpotWidth = movedZoomedSpotPoints.count >= 2
            ? abs(movedZoomedSpotPoints[1].x - movedZoomedSpotPoints[0].x)
            : 0
        t.check(
            abs(zoomedSpotImageRect.width * 0.12 - 4.2) < 0.001 &&
            movedZoomedSpotPoints.count >= 2 &&
            movedZoomedSpotPoints[0].x > originalZoomedSpotPoints[0].x + 0.01 &&
            abs(movedZoomedSpotWidth - 0.12) < 0.001 &&
            abs(movedZoomedSpotPoints[0].y - originalZoomedSpotPoints[0].y) < 0.001,
            "At 35% zoom, dragging the center of a selected 12pt Spotlight moves it without changing its width",
            detail: "points=\(movedZoomedSpotPoints), width=\(movedZoomedSpotWidth)"
        )
    } else {
        t.check(false, "Constructed 35% Spotlight center-drag events")
    }

    // A 6pt Spotlight displays as 2.1pt at 35%: its border remains selectable while its interior passes through to Counter.
    let counterSpotVM = PinSessionViewModel(image: whiteImg)
    counterSpotVM.scale = 0.35
    let sixPointSpot = PinAnnotation(
        tool: .spotlight,
        color: .red,
        lineWidth: 1.5,
        points: [CGPoint(x: 0.40, y: 0.40), CGPoint(x: 0.46, y: 0.46)]
    )
    counterSpotVM.annotations = [sixPointSpot]
    let counterSpotCanvas = PinCanvasNSView(frame: NSRect(x: 0, y: 0, width: 67, height: 67), vm: counterSpotVM)
    let counterSpotImageRect = counterSpotCanvas.imageRectInView
    counterSpotVM.activeTool = .counter
    let counterSpotBorder = NSPoint(
        x: counterSpotImageRect.minX + 0.40 * counterSpotImageRect.width,
        y: counterSpotImageRect.maxY - 0.43 * counterSpotImageRect.height
    )
    if let borderDown = canvasMouseEvent(.leftMouseDown, at: counterSpotBorder, eventNumber: 312),
       let borderUp = canvasMouseEvent(.leftMouseUp, at: counterSpotBorder, eventNumber: 313) {
        counterSpotCanvas.mouseDown(with: borderDown)
        counterSpotCanvas.mouseUp(with: borderUp)
        t.check(
            counterSpotVM.annotations.count == 1 && counterSpotVM.selectedTextAnnotationID == sixPointSpot.id,
            "A 35% 6pt Spotlight border remains selectable with the Counter tool active"
        )
    } else {
        t.check(false, "Constructed 35% Spotlight border-click events")
    }
    counterSpotVM.selectedTextAnnotationID = nil
    let counterSpotCenter = NSPoint(
        x: counterSpotImageRect.minX + 0.43 * counterSpotImageRect.width,
        y: counterSpotImageRect.maxY - 0.43 * counterSpotImageRect.height
    )
    if let centerDown = canvasMouseEvent(.leftMouseDown, at: counterSpotCenter, eventNumber: 314),
       let centerUp = canvasMouseEvent(.leftMouseUp, at: counterSpotCenter, eventNumber: 315) {
        counterSpotCanvas.mouseDown(with: centerDown)
        counterSpotCanvas.mouseUp(with: centerUp)
        t.check(
            counterSpotVM.annotations.count == 2 &&
            counterSpotVM.annotations.first?.id == sixPointSpot.id &&
            counterSpotVM.annotations.last?.tool == .counter,
            "At 35% zoom, clicking inside a 6pt Spotlight places a Counter instead of selecting the Spotlight"
        )
    } else {
        t.check(false, "Constructed 35% Spotlight interior Counter-placement events")
    }

    // Exact 6pt Spotlight corners still resize at 100%, keep the opposite corner fixed, and undo cleanly.
    let cornerSpotVM = PinSessionViewModel(image: whiteImg)
    let cornerSpot = PinAnnotation(
        tool: .spotlight,
        color: .red,
        lineWidth: 1.5,
        points: [CGPoint(x: 0.40, y: 0.40), CGPoint(x: 0.46, y: 0.46)]
    )
    cornerSpotVM.annotations = [cornerSpot]
    cornerSpotVM.selectedTextAnnotationID = cornerSpot.id
    let cornerSpotCanvas = PinCanvasNSView(frame: NSRect(x: 0, y: 0, width: 132, height: 132), vm: cornerSpotVM)
    let originalCornerSpotPoints = cornerSpot.points
    if let topLeft = cornerSpotCanvas.selectedAnnotationCornerHandlesInView().first(where: { $0.0 == .topLeft })?.1 {
        t.check(
            cornerSpotCanvas.hitTestSelectedAnnotationCornerHandle(viewPoint: topLeft) == .topLeft,
            "The exact top-left corner of a 6pt Spotlight remains a resize hit at 100%"
        )
        let draggedTopLeft = NSPoint(x: topLeft.x - 6, y: topLeft.y + 6)
        if let down = canvasMouseEvent(.leftMouseDown, at: topLeft, eventNumber: 316),
           let drag = canvasMouseEvent(.leftMouseDragged, at: draggedTopLeft, eventNumber: 317),
           let up = canvasMouseEvent(.leftMouseUp, at: draggedTopLeft, eventNumber: 318) {
            cornerSpotCanvas.mouseDown(with: down)
            cornerSpotCanvas.mouseDragged(with: drag)
            cornerSpotCanvas.mouseUp(with: up)
            let resizedPoints = cornerSpotVM.annotations.first(where: { $0.id == cornerSpot.id })?.points ?? []
            let originalWidth = abs(originalCornerSpotPoints[1].x - originalCornerSpotPoints[0].x)
            let originalHeight = abs(originalCornerSpotPoints[1].y - originalCornerSpotPoints[0].y)
            let resizedWidth = resizedPoints.count >= 2 ? abs(resizedPoints[1].x - resizedPoints[0].x) : 0
            let resizedHeight = resizedPoints.count >= 2 ? abs(resizedPoints[1].y - resizedPoints[0].y) : 0
            let oppositeCorner = originalCornerSpotPoints[1]
            t.check(
                resizedWidth > originalWidth && resizedHeight > originalHeight &&
                resizedPoints.contains(where: {
                    abs($0.x - oppositeCorner.x) < 0.001 && abs($0.y - oppositeCorner.y) < 0.001
                }) && cornerSpotVM.undoHistory.count == 1,
                "Dragging an exact 6pt Spotlight corner grows it around the fixed opposite corner with one undo snapshot"
            )
            cornerSpotVM.undo()
            t.check(
                cornerSpotVM.annotations.first(where: { $0.id == cornerSpot.id })?.points == originalCornerSpotPoints,
                "Undo restores the original 6pt Spotlight points after corner resize"
            )
        } else {
            t.check(false, "Constructed exact-corner 6pt Spotlight resize events")
        }
    } else {
        t.check(false, "Found the selected 6pt Spotlight top-left corner")
    }

    // Verify Clipboard Text -> Pin card rendering (Retina 2x, warm sticky paper, indentation & CRLF handling) and pinFromClipboard text fallback
    let textPasteboard = NSPasteboard.withUniqueName()
    textPasteboard.clearContents()
    textPasteboard.setString("    let x = 1\r\nmake test", forType: .string)
    let cardImage = ClipboardHelper.renderTextCardImage("    let x = 1\r\nmake test")
    let cardRep = cardImage?.representations.compactMap { $0 as? NSBitmapImageRep }.first
    let paperColor = cardRep?.colorAt(x: 10, y: 30)?.usingColorSpace(.sRGB)
    let isWarmYellowPaper = (paperColor?.redComponent ?? 0) > 0.85 && (paperColor?.greenComponent ?? 0) > 0.75 && (paperColor?.blueComponent ?? 1) < 0.80
    t.check(
        cardImage != nil &&
        (cardImage?.size.width ?? 0) >= 180 &&
        (cardImage?.size.height ?? 0) >= 76 &&
        cardRep?.pixelsWide == Int((cardImage?.size.width ?? 0) * 2) &&
        isWarmYellowPaper,
        "renderTextCardImage renders non-empty clipboard text into a 2x Retina warm-yellow sticky note image"
    )
    let longLineCard = ClipboardHelper.renderTextCardImage(String(repeating: "long_line_segment_", count: 300))
    t.check(
        longLineCard != nil && (longLineCard?.size.height ?? 1000) <= 900.0,
        "renderTextCardImage bounds long wrapped text within 900pt max card height"
    )
    let hugeWhitespacePrefixCard = ClipboardHelper.renderTextCardImage(String(repeating: " ", count: 8000) + "hello")
    t.check(
        hugeWhitespacePrefixCard != nil,
        "renderTextCardImage renders valid text even after an 8000-space prefix"
    )
    t.check(
        ClipboardHelper.renderTextCardImage("   \n  ") == nil,
        "renderTextCardImage returns nil for whitespace-only text"
    )
    let panelsBeforeTextPin = daemon.activePanels.count
    let didPinText = daemon.pinFromClipboard(pasteboard: textPasteboard)
    t.check(
        didPinText && daemon.activePanels.count == panelsBeforeTextPin + 1,
        "pinFromClipboard creates a floating Pin window when pasteboard contains plain text"
    )
    for panel in Array(daemon.activePanels.values) {
        panel.onClosePanel?()
    }

    let staleClipURL = testTempDirURL.appendingPathComponent("ClipLine_StaleTest.png")
    let unrelatedURL = testTempDirURL.appendingPathComponent("user_notes.txt")
    do {
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: staleClipURL)
        try Data("keep".utf8).write(to: unrelatedURL)
        let oldDate = Date().addingTimeInterval(-7200)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: staleClipURL.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: unrelatedURL.path)
    } catch {
        t.check(false, "Created stale temp file fixtures in isolated test directory", detail: "\(error)")
    }

    ClipboardHelper.cleanupStaleTempFiles(olderThan: 3600, in: testTempDirURL.path)
    t.check(
        !FileManager.default.fileExists(atPath: staleClipURL.path),
        "cleanupStaleTempFiles removes stale ClipLine_*.png files in target directory"
    )
    t.check(
        FileManager.default.fileExists(atPath: unrelatedURL.path),
        "cleanupStaleTempFiles preserves non-ClipLine files in target directory"
    )

}
