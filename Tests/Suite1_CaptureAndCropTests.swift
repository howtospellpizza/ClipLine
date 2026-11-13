import AppKit
import CoreGraphics
import Foundation

@MainActor
func runSuite1CaptureAndCropTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    // Suite 1: Coordinate Geometry & Crop Math
    // -------------------------------------------------------------------------
    print("🔹 Suite 1: Geometry & Crop Math")
    let screenFrame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let cgScreen = makeSyntheticScreenCGImage(width: 800, height: 600) // 2x Retina

    let cropRect = NSRect(x: 100, y: 80, width: 160, height: 120)
    let cropped = PixPinSelectionView.cropImage(
        cgImage: cgScreen,
        viewHeight: screenFrame.height,
        scaleFactor: 2.0,
        rect: cropRect
    )
    t.check(cropped != nil, "PixPinSelectionView.cropImage returns non-nil image")
    t.check(cropped?.size == NSSize(width: 160, height: 120), "Cropped image preserves logical point size 160x120")

    let panelFrame = PinSessionViewModel.panelFrameForImageScreenRect(cropRect)
    t.check(
        panelFrame == NSRect(x: 84, y: 64, width: 192, height: 152),
        "panelFrameForImageScreenRect adds exact 16pt canvasMargin on all 4 sides",
        detail: "got \(panelFrame)"
    )

    let deniedCaptureController = ScreenCaptureOverlayController()
    var preflightChecks = 0
    var requestAttempts = 0
    var alertPresentations = 0
    deniedCaptureController.preflightAccess = {
        preflightChecks += 1
        return false
    }
    deniedCaptureController.requestAccess = {
        requestAttempts += 1
        return false
    }
    deniedCaptureController.presentPermissionAlert = {
        alertPresentations += 1
    }
    let launchPermissionGranted = deniedCaptureController.ensureScreenCaptureAccess(showAlertOnDenial: false)
    t.check(
        !launchPermissionGranted && requestAttempts == 1 && alertPresentations == 0,
        "Launch permission check triggers CGRequestScreenCaptureAccess without blocking on modal alert"
    )
    var deniedCaptureCompletedWithNil = false
    deniedCaptureController.beginCapture { result in
        deniedCaptureCompletedWithNil = (result == nil)
    }
    t.check(
        deniedCaptureCompletedWithNil && requestAttempts == 2 && alertPresentations == 1 && preflightChecks >= 2,
        "beginCapture aborts before showing wallpaper-only fullscreen overlay when Screen Recording permission is denied"
    )
    // Verify stale TCC scenario: preflightAccess (live check) returns false, even if requestAccess() returns cached true
    let staleTCCController = ScreenCaptureOverlayController()
    var stalePreflightCalls = 0
    var staleRequestCalls = 0
    var staleAlertCalls = 0
    staleTCCController.preflightAccess = {
        stalePreflightCalls += 1
        return false
    }
    staleTCCController.requestAccess = {
        staleRequestCalls += 1
        return true
    }
    staleTCCController.presentPermissionAlert = {
        staleAlertCalls += 1
    }
    var staleCaptureCompletedWithNil = false
    staleTCCController.beginCapture { result in
        staleCaptureCompletedWithNil = (result == nil)
    }
    t.check(
        staleCaptureCompletedWithNil && stalePreflightCalls == 2 && staleRequestCalls == 1 && staleAlertCalls == 1,
        "ensureScreenCaptureAccess re-verifies live preflightAccess after requestAccess() returns true and presents permission HUD on stale TCC"
    )
    t.check(
        !ScreenCaptureOverlayController.canReadWindowNamesFromWindowList([
            [kCGWindowOwnerPID as String: pid_t(1255), kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar"],
            [kCGWindowOwnerPID as String: pid_t(1256), kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 20, kCGWindowName as String: "Desktop Picture"],
            [kCGWindowOwnerPID as String: pid_t(2566), kCGWindowOwnerName as String: "Google Chrome", kCGWindowLayer as String: 0]
        ], ownPID: 999) &&
        ScreenCaptureOverlayController.canReadWindowNamesFromWindowList([
            [kCGWindowOwnerPID as String: pid_t(1255), kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar"],
            [kCGWindowOwnerPID as String: pid_t(2566), kCGWindowOwnerName as String: "Google Chrome", kCGWindowLayer as String: 0, kCGWindowName as String: ""]
        ], ownPID: 999) &&
        ScreenCaptureOverlayController.canReadWindowNamesFromWindowList([
            [kCGWindowOwnerPID as String: pid_t(1255), kCGWindowOwnerName as String: "Window Server", kCGWindowLayer as String: 24, kCGWindowName as String: "Menubar"],
            [kCGWindowOwnerPID as String: pid_t(999), kCGWindowOwnerName as String: "clipline", kCGWindowLayer as String: 3, kCGWindowName as String: "Keyboard Shortcuts"]
        ], ownPID: 999),
        "canReadWindowNamesFromWindowList ignores Window Server/Dock names, denies nameless external windows, and treats desktops with no external app windows as inconclusive-authorized"
    )
    t.check(
        ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { true },
            windowListProvider: { nil }
        ) &&
        ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { true },
            windowListProvider: { [] }
        ) &&
        !ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { false },
            windowListProvider: { [] }
        ) &&
        ScreenCaptureOverlayController.hasLiveScreenCaptureAccess(
            preflight: { true },
            windowListProvider: {
                [[kCGWindowOwnerPID as String: pid_t(2566), kCGWindowOwnerName as String: "Google Chrome", kCGWindowName as String: "Tab"]]
            }
        ),
        "hasLiveScreenCaptureAccess treats empty/nil window list as inconclusive when preflight is true and succeeds when non-system kCGWindowName is present"
    )

    // Window auto-detection & single-click snap vs drag override
    let convertedWindowRect = ScreenCaptureOverlayController.convertCGWindowBoundsToViewRect(
        cgBounds: CGRect(x: 50, y: 40, width: 180, height: 100),
        primaryScreenHeight: 300,
        targetScreenFrame: screenFrame
    )
    t.check(
        convertedWindowRect == NSRect(x: 50, y: 160, width: 180, height: 100),
        "convertCGWindowBoundsToViewRect converts top-left CGWindow bounds to bottom-left AppKit view rect",
        detail: "got \(String(describing: convertedWindowRect))"
    )
    t.check(
        !ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 100,
            ownPID: 100,
            ownerName: "ClipLine",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 40, y: 30, width: 300, height: 220),
            screenSize: NSSize(width: 400, height: 300)
        ) &&
        !ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 200,
            ownPID: 100,
            ownerName: "Dock",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            screenSize: NSSize(width: 400, height: 300)
        ) &&
        ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 201,
            ownPID: 100,
            ownerName: "WindowManager",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 16, y: 195, width: 83, height: 120),
            screenSize: NSSize(width: 400, height: 300)
        ) &&
        ScreenCaptureOverlayController.shouldIncludeWindowForSnap(
            ownerPID: 202,
            ownPID: 100,
            ownerName: "Ghostty",
            layer: 0,
            alpha: 1.0,
            viewRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            screenSize: NSSize(width: 400, height: 300)
        ),
        "shouldIncludeWindowForSnap excludes own process and Dock backdrop while keeping Stage Manager thumbnails and fullscreen app windows"
    )
    var snappedResult: CaptureSelectionResult?
    let snapSelectionView = PixPinSelectionView(
        frame: screenFrame,
        screenOrigin: .zero,
        frozenImage: NSImage(cgImage: cgScreen, size: screenFrame.size),
        cgImage: cgScreen,
        scaleFactor: 2.0,
        candidateWindowRects: [
            NSRect(x: 60, y: 90, width: 140, height: 100),
            NSRect(x: 20, y: 20, width: 300, height: 240)
        ],
        onFinish: { snappedResult = $0 }
    )
    t.check(
        snapSelectionView.hoveredWindowRect(at: NSPoint(x: 100, y: 120)) == NSRect(x: 60, y: 90, width: 140, height: 100),
        "hoveredWindowRect returns the topmost front-to-back window containing cursor"
    )
    if let downSnap = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 100, y: 120), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1.0
    ),
       let upSnap = NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 101, y: 121), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1.0
       ) {
        snapSelectionView.mouseDown(with: downSnap)
        snapSelectionView.mouseUp(with: upSnap)
        t.check(
            snappedResult?.selectedScreenRect == NSRect(x: 60, y: 90, width: 140, height: 100),
            "Single-clicking (<4pt drag) on a hovered window snaps capture to that window's exact bounds",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }
    snappedResult = nil
    if let downDrag = NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 70, y: 100), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 1.0
    ),
       let moveDrag = NSEvent.mouseEvent(
        with: .leftMouseDragged, location: NSPoint(x: 150, y: 160), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 4, clickCount: 1, pressure: 1.0
       ),
       let upDrag = NSEvent.mouseEvent(
        with: .leftMouseUp, location: NSPoint(x: 150, y: 160), modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, eventNumber: 5, clickCount: 1, pressure: 1.0
       ) {
        snapSelectionView.mouseDown(with: downDrag)
        snapSelectionView.mouseDragged(with: moveDrag)
        snapSelectionView.mouseUp(with: upDrag)
        t.check(
            snappedResult?.selectedScreenRect == NSRect(x: 70, y: 100, width: 80, height: 60),
            "Dragging >=4pt overrides hovered window snap and captures the custom selection rect",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }
    snappedResult = nil
    if let repeatSpace = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49
    ) {
        snapSelectionView.keyDown(with: repeatSpace)
        t.check(
            snappedResult == nil,
            "Auto-repeated Space keyDown is ignored by capture overlay"
        )
    }
    if let spaceKey = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
    ) {
        snapSelectionView.keyDown(with: spaceKey)
        t.check(
            snappedResult?.selectedScreenRect == screenFrame,
            "Pressing Space in capture overlay captures the entire screen",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }
    snappedResult = nil
    if let cmdAKey = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0,
        context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0
    ) {
        snapSelectionView.keyDown(with: cmdAKey)
        t.check(
            snappedResult?.selectedScreenRect == screenFrame,
            "Pressing Cmd+A in capture overlay captures the entire screen",
            detail: "got \(String(describing: snappedResult?.selectedScreenRect))"
        )
    }

    // Verify Loupe HEX pixel sampling with deterministic quadrant colors & pressing 'C' copies #HEX color to pasteboard and exits capture
    snapSelectionView.pasteboardProvider = { testPasteboard }
    testPasteboard.clearContents()
    if let quadSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let quadCtx = CGContext(
        data: nil,
        width: 200,
        height: 100,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: quadSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
       ) {
        // CoreGraphics context origin is bottom-left:
        // Bottom half (CG y: 0..<50 => CGImage pixel y: 50..<100 => view y: 0..<25 at scale 2.0): pure BLUE (#0000FF)
        quadCtx.setFillColor(red: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
        quadCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 50))
        // Top-left (CG x: 0..<100, y: 50..<100 => CGImage pixel x: 0..<100, y: 0..<50 => view x: 0..<50, y: 25..<50): pure RED (#FF0000)
        quadCtx.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        quadCtx.fill(CGRect(x: 0, y: 50, width: 100, height: 50))
        // Top-right (CG x: 100..<200, y: 50..<100 => view x: 50..<100, y: 25..<50): pure GREEN (#00FF00)
        quadCtx.setFillColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        quadCtx.fill(CGRect(x: 100, y: 50, width: 100, height: 50))

        if let quadCG = quadCtx.makeImage() {
            let quadViewSize = NSSize(width: 100, height: 50)
            let sampledTopLeft = PixPinSelectionView.samplePixelHexColor(
                cgImage: quadCG,
                viewHeight: quadViewSize.height,
                scaleFactor: 2.0,
                viewPoint: NSPoint(x: 20, y: 40)
            )
            let sampledTopRight = PixPinSelectionView.samplePixelHexColor(
                cgImage: quadCG,
                viewHeight: quadViewSize.height,
                scaleFactor: 2.0,
                viewPoint: NSPoint(x: 75, y: 40)
            )
            let sampledBottom = PixPinSelectionView.samplePixelHexColor(
                cgImage: quadCG,
                viewHeight: quadViewSize.height,
                scaleFactor: 2.0,
                viewPoint: NSPoint(x: 20, y: 10)
            )
            t.check(
                sampledTopLeft?.hex == "#FF0000" &&
                sampledTopRight?.hex == "#00FF00" &&
                sampledBottom?.hex == "#0000FF",
                "samplePixelHexColor maps Retina scale and inverted Y view coordinates to exact deterministic #RRGGBB colors",
                detail: "topLeft=\(String(describing: sampledTopLeft?.hex)), topRight=\(String(describing: sampledTopRight?.hex)), bottom=\(String(describing: sampledBottom?.hex))"
            )
            var finishedOnColorCopy = false
            let colorPickView = PixPinSelectionView(
                frame: NSRect(origin: .zero, size: quadViewSize),
                screenOrigin: .zero,
                frozenImage: NSImage(cgImage: quadCG, size: quadViewSize),
                cgImage: quadCG,
                scaleFactor: 2.0,
                crosshairConfig: CrosshairConfiguration(style: .dotRing, color: .green, showLoupe: true),
                onFinish: { res in finishedOnColorCopy = (res == nil) }
            )
            colorPickView.pasteboardProvider = { testPasteboard }
            if let moveEv = NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: 75, y: 40), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 6, clickCount: 0, pressure: 0
            ),
               let cKey = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8
               ) {
                colorPickView.mouseMoved(with: moveEv)
                colorPickView.keyDown(with: cKey)
                let copiedHex = testPasteboard.string(forType: .string)
                t.check(
                    finishedOnColorCopy && copiedHex == "#00FF00",
                    "Pressing 'C' in capture overlay copies exact hovered pixel #00FF00 to pasteboard and exits capture cleanly",
                    detail: "copied=\(String(describing: copiedHex))"
                )
            } else {
                t.check(false, "Constructed mouseMoved and 'C' keyEvent for HEX color picker test")
            }
        } else {
            t.check(false, "Created quadrant CGImage for HEX color picker test")
        }
    } else {
        t.check(false, "Created sRGB CGContext for HEX color picker test")
    }

    // Shift-constrained square & 45-degree arrow math + Step Counter + Highlighter
    let constrainedSquareEnd = PinSessionViewModel.constrainedNormalizedEndPoint(
        for: .rect,
        start: CGPoint(x: 0.2, y: 0.2),
        rawEnd: CGPoint(x: 0.7, y: 0.4),
        canvasSize: NSSize(width: 200, height: 100)
    )
    let squareWidthPt = abs(constrainedSquareEnd.x - 0.2) * 200.0
    let squareHeightPt = abs(constrainedSquareEnd.y - 0.2) * 100.0
    t.check(
        abs(squareWidthPt - squareHeightPt) < 0.01 && squareWidthPt > 10,
        "Shift-constrained .rect locks 1:1 point-space square even on non-square canvases",
        detail: "w=\(squareWidthPt), h=\(squareHeightPt)"
    )

    let constrainedArrowEnd = PinSessionViewModel.constrainedNormalizedEndPoint(
        for: .arrow,
        start: CGPoint(x: 0.5, y: 0.5),
        rawEnd: CGPoint(x: 0.82, y: 0.53),
        canvasSize: NSSize(width: 200, height: 100)
    )
    let arrowDxPt = (constrainedArrowEnd.x - 0.5) * 200.0
    let arrowDyPt = (constrainedArrowEnd.y - 0.5) * 100.0
    t.check(
        abs(arrowDyPt) < 0.01 && arrowDxPt > 20,
        "Shift-constrained .arrow snaps near-horizontal drag to exact 0° horizontal angle",
        detail: "dx=\(arrowDxPt), dy=\(arrowDyPt)"
    )

    let featureBaseImage = makeTextImage(text: "HIGHLIGHT", size: NSSize(width: 200, height: 80))
    let featureVM = PinSessionViewModel(image: featureBaseImage)
    t.check(featureVM.nextCounterLabel == "1", "nextCounterLabel starts at 1 when no counter annotations exist")
    featureVM.annotations.append(PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.25, y: 0.28)], text: featureVM.nextCounterLabel))
    t.check(featureVM.nextCounterLabel == "2", "nextCounterLabel increments to 2 after placing first counter badge")
    featureVM.annotations.append(PinAnnotation(tool: .highlighter, color: .systemYellow, lineWidth: 22, points: [CGPoint(x: 0.15, y: 0.72), CGPoint(x: 0.85, y: 0.72)]))
    let renderedWithCounterAndHighlight = featureVM.renderCompositeImage()
    var counterAndHighlightRegionCheck = false
    if let renderedWithCounterAndHighlight,
       let baseTIFF = featureBaseImage.tiffRepresentation,
       let baseBMP = NSBitmapImageRep(data: baseTIFF),
       let outTIFF = renderedWithCounterAndHighlight.tiffRepresentation,
       let outBMP = NSBitmapImageRep(data: outTIFF),
       baseBMP.pixelsWide == outBMP.pixelsWide,
       baseBMP.pixelsHigh == outBMP.pixelsHigh {
        let w = outBMP.pixelsWide
        let h = outBMP.pixelsHigh
        // NSBitmapImageRep.colorAt(x:y:) uses top-left origin (y=0 at top), matching normalized top-down Y!
        // Counter badge is at normalized (0.25, 0.28); highlighter stroke is at normalized y=0.72 across x in [0.15, 0.85].
        var badgeRedInsideRegion = 0
        var badgeRedOutsideRegion = 0
        var highlightYellowInsideRegion = 0
        var highlightYellowOutsideRegion = 0
        var untouchedCornerMatchesBase = true

        for y in stride(from: 2, to: h - 2, by: 2) {
            let ny = CGFloat(y) / CGFloat(h)
            for x in stride(from: 2, to: w - 2, by: 2) {
                let nx = CGFloat(x) / CGFloat(w)
                guard let c = outBMP.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let bc = baseBMP.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }

                let isRed = c.redComponent > 0.75 && c.greenComponent < 0.35 && c.blueComponent < 0.35
                let isYellow = c.redComponent > 0.85 && c.greenComponent > 0.80 && c.blueComponent < 0.75

                let inBadgeBox = (nx >= 0.14 && nx <= 0.36 && ny >= 0.04 && ny <= 0.52)
                let inHighlightBox = (nx >= 0.10 && nx <= 0.90 && ny >= 0.54 && ny <= 0.90)

                if isRed {
                    if inBadgeBox { badgeRedInsideRegion += 1 } else { badgeRedOutsideRegion += 1 }
                }
                if isYellow {
                    if inHighlightBox { highlightYellowInsideRegion += 1 } else { highlightYellowOutsideRegion += 1 }
                }

                // Far top-right region (nx > 0.75, ny < 0.22) must remain identical to base image
                if nx > 0.75 && ny < 0.22 {
                    let diff = abs(c.redComponent - bc.redComponent) + abs(c.greenComponent - bc.greenComponent) + abs(c.blueComponent - bc.blueComponent)
                    if diff > 0.02 {
                        untouchedCornerMatchesBase = false
                    }
                }
            }
        }
        counterAndHighlightRegionCheck = (
            badgeRedInsideRegion >= 8 &&
            badgeRedOutsideRegion == 0 &&
            highlightYellowInsideRegion >= 8 &&
            highlightYellowOutsideRegion == 0 &&
            untouchedCornerMatchesBase
        )
    }
    t.check(
        renderedWithCounterAndHighlight?.size == NSSize(width: 200, height: 80) && counterAndHighlightRegionCheck,
        "renderCompositeImage paints .counter badge and .highlighter stroke inside their expected regions while leaving outside pixels untouched"
    )
    featureVM.undo()
    featureVM.undo()
    t.check(
        featureVM.nextCounterLabel == "1",
        "Undoing counter badge decrements nextCounterLabel back to 1"
    )
    let badge1 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.2, y: 0.3)], text: featureVM.nextCounterLabel)
    featureVM.annotations.append(badge1)
    let badge2 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.5, y: 0.3)], text: featureVM.nextCounterLabel)
    featureVM.annotations.append(badge2)
    let badge3 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.8, y: 0.3)], text: featureVM.nextCounterLabel)
    featureVM.annotations.append(badge3)
    featureVM.selectedTextAnnotationID = badge1.id
    let deletedFirstBadge = featureVM.deleteSelectedAnnotation()
    t.check(
        deletedFirstBadge &&
        featureVM.annotations.map(\.text) == ["1", "2"] &&
        featureVM.nextCounterLabel == "3",
        "Deleting counter badge #1 resequences remaining badges to [1, 2] so the next counter is 3 without duplicate 2s"
    )
    featureVM.undo()
    t.check(
        featureVM.annotations.map(\.id) == [badge1.id, badge2.id, badge3.id] &&
        featureVM.annotations.map(\.text) == ["1", "2", "3"] &&
        featureVM.nextCounterLabel == "4",
        "Undoing a counter deletion restores the deleted badge in place with original [1, 2, 3] sequence"
    )
    featureVM.annotations.removeAll()

    // Verify ScreenCaptureOverlayController multi-display lifecycle, focus handoff, cursor-screen failure guard, and cross-display drag cancel
    let multiController = ScreenCaptureOverlayController()
    var missingInitialAlertCount = 0
    multiController.presentPermissionAlert = { missingInitialAlertCount += 1 }
    var missingInitialResult: CaptureSelectionResult? = nil
    var missingInitialCompleted = false
    multiController.installCaptureOverlays(
        descriptors: [
            (screenFrame: NSRect(x: 400, y: 0, width: 400, height: 300), cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: false)
        ],
        hideSystemCursor: false,
        completion: { res in
            missingInitialResult = res
            missingInitialCompleted = true
        }
    )
    t.check(
        missingInitialCompleted && missingInitialResult == nil &&
        multiController.overlayWindows.isEmpty && missingInitialAlertCount == 1,
        "If capture fails on the cursor's display, controller aborts cleanly instead of silently activating another display"
    )

    var multiCaptureResult: CaptureSelectionResult? = nil
    var multiCaptureFinishedCount = 0
    multiController.installCaptureOverlays(
        descriptors: [
            (screenFrame: NSRect(x: 0, y: 0, width: 400, height: 300), cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: true),
            (screenFrame: NSRect(x: 400, y: 0, width: 400, height: 300), cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: false)
        ],
        hideSystemCursor: false,
        completion: { res in
            multiCaptureResult = res
            multiCaptureFinishedCount += 1
        }
    )
    if multiController.overlayWindows.count == 2,
       let panelA = multiController.overlayWindows.first,
       let panelB = multiController.overlayWindows.last,
       let viewA = panelA.contentView as? PixPinSelectionView,
       let viewB = panelB.contentView as? PixPinSelectionView {
        t.check(
            viewA.isCursorInsideScreen && !viewB.isCursorInsideScreen && panelA.firstResponder === viewA,
            "Initial cursor display starts active and owns first responder"
        )
        // Start a drag on Screen A and release 1pt outside Screen A's bounds (onto Screen B) -> cancels drag without finishing clipped capture
        if let downA = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: 350, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: panelA.windowNumber, context: nil, eventNumber: 31, clickCount: 1, pressure: 1.0
        ),
           let dragOutA = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: 401, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: panelA.windowNumber, context: nil, eventNumber: 32, clickCount: 1, pressure: 1.0
           ),
           let upOutA = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: 401, y: 150), modifierFlags: [],
            timestamp: 0, windowNumber: panelA.windowNumber, context: nil, eventNumber: 33, clickCount: 1, pressure: 1.0
           ) {
            viewA.mouseDown(with: downA)
            viewA.mouseDragged(with: dragOutA)
            viewA.mouseUp(with: upOutA)
            t.check(
                multiCaptureFinishedCount == 0 && multiController.overlayWindows.count == 2,
                "Releasing a drag even 1pt outside its originating display cancels the cross-screen drag instead of capturing a clipped strip"
            )
            // Also verify cross-screen activation handoff clearing Screen A's drag before mouseUp does not dismiss capture overlays
            viewA.mouseDown(with: downA)
            multiController.activateOverlayView(viewB)
            viewA.mouseUp(with: upOutA)
            t.check(
                multiCaptureFinishedCount == 0 && multiController.overlayWindows.count == 2,
                "Cross-screen overlay activation before mouseUp cancels only the active drag and keeps all capture overlays open"
            )
        } else {
            t.check(false, "Constructed cross-display drag events for Screen A")
        }
        // Move cursor onto Screen B -> real controller handoff updates cursor flags and first responder, then Space captures Screen B
        if let moveOntoB = NSEvent.mouseEvent(
            with: .mouseMoved, location: NSPoint(x: 80, y: 120), modifierFlags: [],
            timestamp: 0, windowNumber: panelB.windowNumber, context: nil, eventNumber: 34, clickCount: 0, pressure: 0
        ),
           let spaceB = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panelB.windowNumber,
            context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
           ) {
            viewB.mouseMoved(with: moveOntoB)
            t.check(
                viewB.isCursorInsideScreen && !viewA.isCursorInsideScreen && panelB.firstResponder === viewB,
                "Moving cursor onto secondary screen transfers controller active state and first responder to secondary overlay"
            )
            viewB.keyDown(with: spaceB)
            t.check(
                multiCaptureFinishedCount == 1 &&
                multiCaptureResult?.selectedScreenRect == NSRect(x: 400, y: 0, width: 400, height: 300) &&
                multiController.overlayWindows.isEmpty,
                "Pressing Space after moving to secondary screen captures secondary screen and closes all overlay windows"
            )
            t.check(
                panelA.hidesOnDeactivate == false && panelB.hidesOnDeactivate == false,
                "CaptureOverlayPanel sets hidesOnDeactivate = false so overlays do not silently vanish on transient deactivation"
            )
        } else {
            t.check(false, "Constructed mouseMoved and Space keyEvent for Screen B")
        }
    } else {
        t.check(false, "ScreenCaptureOverlayController created two overlay panels for multi-display test")
        multiController.finish(with: nil)
    }

    // Verify cancelActiveCapture(reason:) tears down overlays and invokes completion(nil) so isCapturing can never stay wedged
    let cancelController = ScreenCaptureOverlayController()
    var cancelCallbackFired = false
    cancelController.installCaptureOverlays(
        descriptors: [(screenFrame: screenFrame, cgImage: cgScreen, candidateWindowRects: [], isInitialCursorScreen: true)],
        hideSystemCursor: false,
        completion: { res in
            cancelCallbackFired = (res == nil)
        }
    )
    cancelController.cancelActiveCapture(reason: "test recovery")
    t.check(
        cancelCallbackFired && cancelController.overlayWindows.isEmpty && !cancelController.hasActiveOverlays,
        "cancelActiveCapture tears down active overlays and fires completion(nil) to clear capture session state"
    )

    var openedSettingsFromHUD = false
    var revealedBinaryFromHUD = false
    var dismissedHUD = false
    let hudPanel = ScreenCaptureOverlayController.makeScreenRecordingPermissionPanel(
        onOpenSettings: { openedSettingsFromHUD = true },
        onRevealBinary: { revealedBinaryFromHUD = true },
        onDismiss: {
            dismissedHUD = true
            ScreenCaptureOverlayController.dismissScreenRecordingPermissionAlert()
        }
    )
    t.check(
        hudPanel.styleMask.contains(.borderless) && !hudPanel.isOpaque && hudPanel.contentView != nil,
        "makeScreenRecordingPermissionPanel builds borderless translucent HUD card instead of default generic folder NSAlert"
    )
    hudPanel.cancelOperation(nil)
    t.check(
        dismissedHUD && !openedSettingsFromHUD && !revealedBinaryFromHUD,
        "Permission HUD card dismisses cleanly on Escape/cancelOperation"
    )

}
