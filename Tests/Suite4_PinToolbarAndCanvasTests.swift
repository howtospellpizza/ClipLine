import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
func runSuite4PinToolbarAndCanvasTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    let f = makeDefaultCaptureFixtures()
    let baseImg = f.baseImg
    let panelFrame = f.panelFrame
    let vm = f.makeViewModel()
    // Suite 4: Native Dual-Panel GUI Lifecycle, 8-Handle Resize & Keyboard Forwarding
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 4: Native AppKit + SwiftUI Dual-Panel GUI Regression")
    let daemon = PinDaemonApp()
    daemon.presentPinPanel(vm: vm, frame: panelFrame)

    guard let pinPanel = vm.hostingPanel,
          let canvas = pinPanel.canvasView,
          let tbPanel = vm.toolbarPanel as? PinToolbarPanel else {
        t.check(false, "presentPinPanel creates PinFloatingPanel, PinCanvasNSView, and PinToolbarPanel")
        return
    }

    t.check(pinPanel.isVisible, "PinFloatingPanel is visible on screen")
    t.check(tbPanel.isVisible, "Detached PinToolbarPanel is visible on screen")
    t.check(
        tbPanel.level == pinPanel.level && pinPanel.childWindows?.contains(tbPanel) == true,
        "PinToolbarPanel shares .floating level and is attached as an ordered-above child window of its own PinFloatingPanel"
    )
    t.check(tbPanel.viewModel === vm, "PinToolbarPanel.viewModel is wired to PinSessionViewModel")
    t.check(
        !pinPanel.styleMask.contains(.nonactivatingPanel) &&
        !tbPanel.styleMask.contains(.nonactivatingPanel) &&
        tbPanel.becomesKeyOnlyIfNeeded,
        "PinFloatingPanel and PinToolbarPanel omit .nonactivatingPanel so WindowServer CPS focus stack stays consistent and clicking Pin retains keyboard focus"
    )

    // Verify multi-pin overlapping stacking: Pin B and its toolbar stay above Pin A and Pin A's toolbar when B is active,
    // and clicking/activating Pin A brings Pin A and Pin A's toolbar above Pin B and Pin B's toolbar!
    let secondPinVM = PinSessionViewModel(image: baseImg)
    let overlappingFrame = panelFrame.offsetBy(dx: 24, dy: -18)
    daemon.presentPinPanel(vm: secondPinVM, frame: overlappingFrame)
    if let pinPanelB = secondPinVM.hostingPanel,
       let tbPanelB = secondPinVM.toolbarPanel as? PinToolbarPanel {
        func currentWindowNumOrder() -> [Int] {
            NSWindow.windowNumbers(options: [])?.map(\.intValue) ?? []
        }
        let orderedAfterB = currentWindowNumOrder()
        let idxPinA1 = orderedAfterB.firstIndex(of: pinPanel.windowNumber) ?? -1
        let idxTbA1 = orderedAfterB.firstIndex(of: tbPanel.windowNumber) ?? -1
        let idxPinB1 = orderedAfterB.firstIndex(of: pinPanelB.windowNumber) ?? -1
        let idxTbB1 = orderedAfterB.firstIndex(of: tbPanelB.windowNumber) ?? -1
        t.check(
            idxTbB1 >= 0 && idxPinB1 >= 0 && idxTbA1 >= 0 && idxPinA1 >= 0 &&
            idxTbB1 < idxPinB1 && idxPinB1 < idxTbA1,
            "Presenting second overlapping pin orders Pin B + Toolbar B above Pin A's toolbar",
            detail: "ordered indices: tbB=\(idxTbB1), pinB=\(idxPinB1), tbA=\(idxTbA1), pinA=\(idxPinA1)"
        )

        // Now activate Pin A via canvas click and verify Pin A + Toolbar A rise above Pin B + Toolbar B
        if let clickPinA = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pinPanel.windowNumber,
            context: nil,
            eventNumber: 90,
            clickCount: 1,
            pressure: 1.0
        ),
           let upPinA = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 40, y: 40),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pinPanel.windowNumber,
            context: nil,
            eventNumber: 91,
            clickCount: 1,
            pressure: 1.0
           ) {
            canvas.mouseDown(with: clickPinA)
            canvas.mouseUp(with: upPinA)
            let orderedAfterClickA = currentWindowNumOrder()
            let idxPinA2 = orderedAfterClickA.firstIndex(of: pinPanel.windowNumber) ?? -1
            let idxTbA2 = orderedAfterClickA.firstIndex(of: tbPanel.windowNumber) ?? -1
            let idxPinB2 = orderedAfterClickA.firstIndex(of: pinPanelB.windowNumber) ?? -1
            let idxTbB2 = orderedAfterClickA.firstIndex(of: tbPanelB.windowNumber) ?? -1
            t.check(
                idxTbA2 >= 0 && idxPinA2 >= 0 && idxTbB2 >= 0 && idxPinB2 >= 0 &&
                idxTbA2 < idxPinA2 && idxPinA2 < idxTbB2,
                "Clicking Pin A brings Pin A + Toolbar A above overlapping Pin B + Toolbar B",
                detail: "ordered indices: tbA=\(idxTbA2), pinA=\(idxPinA2), tbB=\(idxTbB2), pinB=\(idxPinB2)"
            )
        }

        // Clip Pin B to Clothesline and restore it, verifying child-window attachment and front ordering are restored
        ClotheslineManager.shared.clipToLine(vm: secondPinVM)
        let detachedWhileClipped = (pinPanelB.childWindows?.contains(tbPanelB) != true) && !pinPanelB.isVisible && !tbPanelB.isVisible
        if let clippedB = ClotheslineManager.shared.items.first(where: { $0.id == secondPinVM.id }) {
            ClotheslineManager.shared.restoreToCanvas(clippedB)
        }
        let orderedAfterRestoreB = currentWindowNumOrder()
        let idxTbB3 = orderedAfterRestoreB.firstIndex(of: tbPanelB.windowNumber) ?? -1
        let idxPinB3 = orderedAfterRestoreB.firstIndex(of: pinPanelB.windowNumber) ?? -1
        let idxTbA3 = orderedAfterRestoreB.firstIndex(of: tbPanel.windowNumber) ?? -1
        t.check(
            detachedWhileClipped &&
            pinPanelB.childWindows?.contains(tbPanelB) == true &&
            idxTbB3 >= 0 && idxPinB3 >= 0 && idxTbA3 >= 0 &&
            idxTbB3 < idxPinB3 && idxPinB3 < idxTbA3,
            "Clipping and restoring Pin B reattaches Toolbar B above Pin B and orders both above Pin A",
            detail: "detachedWhileClipped=\(detachedWhileClipped), indices: tbB=\(idxTbB3), pinB=\(idxPinB3), tbA=\(idxTbA3)"
        )

        // Verify visible Permission HUD does NOT trigger handleEscapeOnActivePin fallback to close a background Pin
        ScreenCaptureOverlayController.presentScreenRecordingPermissionAlertIfNeeded()
        let handledEscapeWhilePermissionHUDVisible = daemon.handleEscapeOnActivePin()
        t.check(
            !handledEscapeWhilePermissionHUDVisible && !secondPinVM.isClosed && pinPanelB.isVisible,
            "handleEscapeOnActivePin does not close a background Pin panel when the Permission HUD is visible"
        )
        ScreenCaptureOverlayController.dismissScreenRecordingPermissionAlert()

        // Ensure Pin B is frontmost, then verify handleEscapeOnActivePin() closes Pin B
        pinPanelB.makeKeyAndOrderFront(nil)
        secondPinVM.updateToolbarPanelPosition()
        let handledEscapeOnPinB = daemon.handleEscapeOnActivePin()
        t.check(
            handledEscapeOnPinB && secondPinVM.isClosed && !pinPanelB.isVisible,
            "handleEscapeOnActivePin closes the frontmost visible Pin B panel"
        )
        if !secondPinVM.isClosed {
            pinPanelB.onClosePanel?()
        }
        pinPanel.makeKeyAndOrderFront(nil)
        vm.updateToolbarPanelPosition()
    }

    // Verify 4A: Image rect & all 8 handle hit-testing
    let imgRect = canvas.imageRectInView
    t.check(
        imgRect == NSRect(x: 16, y: 16, width: 160, height: 120),
        "canvas.imageRectInView sits inside 16pt margin (16, 16, 160, 120)"
    )

    let bottomHandleScreenY = pinPanel.frame.minY + imgRect.minY
    let toolbarMaxY = tbPanel.frame.maxY
    t.check(
        toolbarMaxY <= bottomHandleScreenY - 8 || tbPanel.frame.minY >= pinPanel.frame.maxY - 8,
        "Detached toolbar panel never overlaps bottom resize handles",
        detail: "toolbarMaxY=\(toolbarMaxY), bottomHandleScreenY=\(bottomHandleScreenY)"
    )

    // Verify full-screen pin keeps toolbar panel within visible screen bounds and dodges bottom inline text editor
    let mainScreen = pinPanel.screen ?? NSScreen.main ?? NSScreen.screens.first
    if let mainScreen {
        let fullFrame = PinSessionViewModel.panelFrameForImageScreenRect(mainScreen.frame)
        pinPanel.setFrame(fullFrame, display: false)
        vm.updateToolbarPanelPosition()
        t.check(
            tbPanel.frame.minY >= mainScreen.visibleFrame.minY &&
            tbPanel.frame.maxY <= mainScreen.visibleFrame.maxY,
            "Full-screen pin clamps toolbar panel inside visible screen bounds instead of off-screen above menu bar",
            detail: "tbPanel.frame=\(tbPanel.frame), visibleFrame=\(mainScreen.visibleFrame)"
        )
        canvas.showInlineTextField(atNormalized: CGPoint(x: 0.05, y: 0.96), in: canvas.imageRectInView, initialText: "Bottom Edit")
        if let fieldRect = canvas.pendingFieldHitRect() {
            let fieldOnScreen = pinPanel.convertToScreen(canvas.convert(fieldRect, to: nil))
            t.check(
                !tbPanel.frame.intersects(fieldOnScreen),
                "Full-screen toolbar dodges bottom inline text editor so it never covers active text input",
                detail: "tbPanel.frame=\(tbPanel.frame), fieldOnScreen=\(fieldOnScreen)"
            )
        }
        vm.cancelPendingTextEditing()
        pinPanel.setFrame(panelFrame, display: false)
        vm.updateToolbarPanelPosition()
    }
    if let repeatPinSpace = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49
    ) {
        let initialToolbarVisible = vm.showToolbar
        pinPanel.keyDown(with: repeatPinSpace)
        t.check(
            vm.showToolbar == initialToolbarVisible,
            "Auto-repeated Space keyDown on PinFloatingPanel does not toggle toolbar visibility"
        )
    }

    let handlePts = canvas.handlePointsInView()
    t.check(handlePts.count == 8, "handlePointsInView returns all 8 resize handles")
    for (expectedHandle, pt) in handlePts {
        let hit = canvas.hitTestResizeHandle(viewPoint: pt)
        t.check(hit == expectedHandle, "hitTestResizeHandle hits \(expectedHandle) at \(pt)")
    }

    // Verify 4B: Post-capture live 8-handle resize across all 8 directions
    let baseCrop = NSRect(x: 100, y: 80, width: 160, height: 120)
    let directionCases: [(PinSessionViewModel.ResizeHandle, NSPoint, NSPoint, NSRect)] = [
        (.topLeft, NSPoint(x: 100, y: 200), NSPoint(x: 90, y: 215), NSRect(x: 90, y: 80, width: 170, height: 135)),
        (.topCenter, NSPoint(x: 180, y: 200), NSPoint(x: 180, y: 210), NSRect(x: 100, y: 80, width: 160, height: 130)),
        (.topRight, NSPoint(x: 260, y: 200), NSPoint(x: 275, y: 210), NSRect(x: 100, y: 80, width: 175, height: 130)),
        (.middleLeft, NSPoint(x: 100, y: 140), NSPoint(x: 85, y: 140), NSRect(x: 85, y: 80, width: 175, height: 120)),
        (.middleRight, NSPoint(x: 260, y: 140), NSPoint(x: 280, y: 140), NSRect(x: 100, y: 80, width: 180, height: 120)),
        (.bottomLeft, NSPoint(x: 100, y: 80), NSPoint(x: 90, y: 70), NSRect(x: 90, y: 70, width: 170, height: 130)),
        (.bottomCenter, NSPoint(x: 180, y: 80), NSPoint(x: 180, y: 65), NSRect(x: 100, y: 65, width: 160, height: 135)),
        (.bottomRight, NSPoint(x: 260, y: 80), NSPoint(x: 280, y: 65), NSRect(x: 100, y: 65, width: 180, height: 135))
    ]
    for (handle, startPt, dragPt, expectedRect) in directionCases {
        vm.applyResize(handle: handle, startMouse: startPt, startCropRect: baseCrop, currentMouse: dragPt)
        vm.finishResize()
        t.check(
            vm.cropScreenRect == expectedRect,
            "applyResize(\(handle)) updates cropScreenRect to \(expectedRect)",
            detail: "got \(String(describing: vm.cropScreenRect))"
        )
    }

    t.check(
        pinPanel.frame.size == NSSize(width: 212, height: 167),
        "PinFloatingPanel resizes synchronously to 212x167 (180+32 x 135+32)"
    )

    // Verify dragging right handle past left edge clamps only right edge (never shifts anchored left edge X=100)
    vm.applyResize(handle: .middleRight, startMouse: NSPoint(x: 280, y: 140), startCropRect: NSRect(x: 100, y: 65, width: 180, height: 135), currentMouse: NSPoint(x: 20, y: 140))
    t.check(
        vm.cropScreenRect == NSRect(x: 100, y: 65, width: 24, height: 135),
        "Dragging right handle past left edge clamps at minCropSize (width=24) without shifting anchored left edge X=100",
        detail: "got \(String(describing: vm.cropScreenRect))"
    )
    // Restore to (100, 65, 180, 135)
    vm.applyResize(handle: .bottomRight, startMouse: NSPoint(x: 260, y: 80), startCropRect: baseCrop, currentMouse: NSPoint(x: 280, y: 65))
    vm.finishResize()

    let secondBottomCenterPt = NSPoint(x: canvas.imageRectInView.midX, y: canvas.imageRectInView.minY)
    t.check(
        canvas.hitTestResizeHandle(viewPoint: secondBottomCenterPt) == .bottomCenter,
        "Bottom-center handle remains hit-testable after resize completes"
    )

    // Verify 4C: Toolbar expansion when selecting tools does NOT clip image canvas
    let canvasFrameBeforeTool = pinPanel.frame
    let tbWidthBeforeTool = tbPanel.frame.width
    vm.activeTool = .pen
    let tbWidthAfterTool = tbPanel.frame.width
    t.check(
        pinPanel.frame == canvasFrameBeforeTool,
        "Selecting .pen tool does NOT alter or clip PinFloatingPanel frame"
    )
    t.check(
        tbWidthAfterTool > tbWidthBeforeTool,
        "Detached toolbar panel auto-expands width (\(Int(tbWidthBeforeTool))pt -> \(Int(tbWidthAfterTool))pt) to show 细/中/粗 + colors"
    )

    // Verify 4D: Drawing annotations & Cmd+Z Undo via PinToolbarPanel key forwarding
    vm.annotations.append(
        PinAnnotation(
            tool: .rect,
            color: .red,
            lineWidth: vm.currentToolLineWidth,
            points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.8, y: 0.8)]
        )
    )
    t.check(vm.annotations.count == 1, "Annotation appended to session")

    if let cmdZEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: tbPanel.windowNumber,
        context: nil,
        characters: "z",
        charactersIgnoringModifiers: "z",
        isARepeat: false,
        keyCode: 6 // kVK_ANSI_Z
    ) {
        tbPanel.keyDown(with: cmdZEvent)
        t.check(
            vm.annotations.isEmpty,
            "Pressing Cmd+Z while PinToolbarPanel is key window forwards to PinFloatingPanel and undoes annotation"
        )
    } else {
        t.check(false, "Constructed Cmd+Z keyEvent")
    }

    // Verify 4E: Composite rendering with annotations + inline text clamping + live color/background sync + text dragging
    vm.activeTool = .text
    if let canvas = pinPanel.canvasView {
        canvas.showInlineTextField(atNormalized: CGPoint(x: 0.30, y: 0.30), in: canvas.imageRectInView, initialText: "LiveColorText")
        let openSettings = pinPanel.onOpenSettings
        var settingsOpenCount = 0
        pinPanel.onOpenSettings = { settingsOpenCount += 1 }
        let originalTextPosition = vm.pendingTextNormalizedPos
        func commaEvent(modifiers: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber, context: nil,
                characters: ",", charactersIgnoringModifiers: ",",
                isARepeat: false, keyCode: UInt16(kVK_ANSI_Comma)
            )!
        }
        t.check(
            pinPanel.firstResponder is NSTextView && vm.pendingTextNormalizedPos != nil,
            "Settings shortcut regression starts with an active inline field editor"
        )
        let settingsEvent = commaEvent(modifiers: [.command])
        let settingsHandled = pinPanel.performKeyEquivalent(with: settingsEvent)
        t.check(
            settingsHandled && settingsOpenCount == 1,
            "Cmd+, opens settings through window key equivalents while the inline field editor is active"
        )
        tbPanel.keyDown(with: settingsEvent)
        t.check(
            settingsOpenCount == 2,
            "Toolbar key forwarding opens settings even with pending inline text"
        )
        _ = pinPanel.performKeyEquivalent(with: commaEvent(modifiers: []))
        _ = pinPanel.performKeyEquivalent(with: commaEvent(modifiers: [.command, .shift]))
        t.check(
            settingsOpenCount == 2,
            "Plain comma and modified Cmd+comma do not trigger settings"
        )
        t.check(
            vm.pendingTextNormalizedPos == originalTextPosition &&
                canvas.textField?.stringValue == "LiveColorText" && vm.annotations.isEmpty,
            "Routing the settings shortcut preserves pending text without committing or discarding it"
        )
        pinPanel.onOpenSettings = openSettings
        t.check(
            canvas.textField?.drawsBackground == false && canvas.textField?.backgroundColor == .clear,
            "Inline text field has transparent background by default (no gray box)"
        )
        vm.selectedColor = .green
        let tfColorMatch = canvas.textField?.textColor == NSColor(.green)
        let editor = pinPanel.fieldEditor(false, for: canvas.textField) as? NSTextView
        let editorColorMatch = (editor == nil) || (editor?.textColor == NSColor(.green))
        t.check(
            tfColorMatch && editorColorMatch,
            "Changing vm.selectedColor while editing immediately updates NSTextField & active fieldEditor textColor"
        )
        vm.textBackgroundStyle = .black
        t.check(
            canvas.textField?.layer?.borderWidth == 0,
            "Inline textField layer stays borderless (pill & neutral selection frame are rendered cleanly by canvas)"
        )
        t.check(
            canvas.textField?.hitTest(NSPoint(x: 10, y: 10)) == nil,
            "DraggableInlineTextField returns nil from hitTest so dragging anywhere on the box moves it"
        )
        let fieldFrameBeforeCommit = canvas.textField?.frame ?? .zero
        vm.commitPendingText()
        t.check(
            vm.annotations.count == 1 && vm.annotations.first?.text == "LiveColorText" && vm.annotations.first?.textBackgroundStyle == .black,
            "commitPendingText commits text annotation with selected textBackgroundStyle and auto-selects it"
        )
        if let committedHitRect = canvas.textAnnotationHitRectInView(vm.annotations[0]) {
            let deltaMidY = abs(committedHitRect.midY - fieldFrameBeforeCommit.midY)
            t.check(
                deltaMidY <= 4.0,
                "Pressing Enter keeps committed text at exact vertical position of inline textField (no jump)",
                detail: "fieldMidY=\(fieldFrameBeforeCommit.midY), committedMidY=\(committedHitRect.midY)"
            )
        }
        t.check(
            vm.selectedTextAnnotationID == vm.annotations.first?.id,
            "Committed text annotation remains selected (selectedTextAnnotationID) for post-commit color/background changes"
        )

        // Post-commit color & background changes update the selected committed text annotation!
        vm.selectedColor = .yellow
        vm.textBackgroundStyle = .white
        t.check(
            vm.annotations[0].color == NSColor(.yellow) && vm.annotations[0].textBackgroundStyle == .white,
            "Changing selectedColor or textBackgroundStyle after pressing Enter updates the selected committed text annotation"
        )

        // Verify committed text hit-testing & dragging (even if user switches tool e.g. to .pen)
        vm.activeTool = .pen
        if let hitRect = canvas.textAnnotationHitRectInView(vm.annotations[0]) {
            let hitCenter = NSPoint(x: hitRect.midX, y: hitRect.midY)
            t.check(
                canvas.hitTestTextAnnotationIndex(viewPoint: hitCenter) == 0,
                "hitTestTextAnnotationIndex hits committed text annotation at its rendered position"
            )
            if let downEv = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pinPanel.convertPoint(fromScreen: pinPanel.convertPoint(toScreen: hitCenter)),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1.0
            ),
               let dragEv = NSEvent.mouseEvent(
                with: .leftMouseDragged,
                location: NSPoint(x: hitCenter.x + 40, y: hitCenter.y - 20),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 2,
                clickCount: 1,
                pressure: 1.0
            ),
               let upEv = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: NSPoint(x: hitCenter.x + 40, y: hitCenter.y - 20),
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 3,
                clickCount: 1,
                pressure: 1.0
            ) {
                let beforePt = vm.annotations[0].points[0]
                canvas.mouseDown(with: downEv)
                canvas.mouseDragged(with: dragEv)
                canvas.mouseUp(with: upEv)
                let afterPt = vm.annotations[0].points[0]
                t.check(
                    afterPt.x > beforePt.x && afterPt.y > beforePt.y,
                    "Dragging committed text annotation moves its normalized coordinates regardless of activeTool",
                    detail: "before=\(beforePt), after=\(afterPt)"
                )
            }
        }
        vm.activeTool = .text

        // Verify typing a long caption near right edge syncs pendingTextNormalizedPos with clampedX and commits via controlTextDidEndEditing (Return) without jumping
        canvas.showInlineTextField(atNormalized: CGPoint(x: 0.72, y: 0.25), in: canvas.imageRectInView, initialText: "A")
        let initialNormX = vm.pendingTextNormalizedPos?.x ?? 0
        if let tf = canvas.textField {
            tf.stringValue = "LongRightEdgeCaptionThatClampsLeft"
            canvas.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: tf))
            let clampedFieldMinX = tf.frame.minX
            let syncedNormX = vm.pendingTextNormalizedPos?.x ?? 0
            let expectedGlyphX = canvas.imageRectInView.minX + syncedNormX * canvas.imageRectInView.width
            // Commit through NSTextField's controlTextDidEndEditing path (same delegate callback triggered by Return in field editor)
            canvas.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: tf))
            let committedLong = vm.annotations.last
            let committedRect = committedLong.flatMap { canvas.textAnnotationHitRectInView($0) } ?? .zero
            let padX: CGFloat = committedLong?.textBackgroundStyle == .transparent ? 8.0 : 10.0
            t.check(
                syncedNormX < initialNormX &&
                abs(expectedGlyphX - (clampedFieldMinX + 2.0)) <= 1.0 &&
                committedLong?.text == "LongRightEdgeCaptionThatClampsLeft" &&
                abs((committedRect.minX + padX) - expectedGlyphX) <= 1.5,
                "Typing long text near right edge syncs pendingTextNormalizedPos with clamped field origin and commits via controlTextDidEndEditing without jumping",
                detail: "initialNormX=\(initialNormX), syncedNormX=\(syncedNormX), expectedGlyphX=\(expectedGlyphX), committedGlyphX=\(committedRect.minX + padX)"
            )
            // Remove the second test annotation so subsequent tests start with 1 annotation
            if vm.annotations.count > 1 {
                vm.annotations.removeLast()
            }
        }

        // Verify double-click re-edit preserves color/font preset/background even if style is mutated while editing, and cancelling restores original snapshot
        vm.selectedTextAnnotationID = nil
        vm.annotations[0].color = NSColor(.orange)
        vm.annotations[0].lineWidth = StrokePreset.thick.textFontSize
        vm.annotations[0].textBackgroundStyle = .black
        vm.selectedColor = .blue
        vm.strokePreset = .thin
        vm.textBackgroundStyle = .transparent
        if let hitRect2 = canvas.textAnnotationHitRectInView(vm.annotations[0]) {
            let center2 = NSPoint(x: hitRect2.midX, y: hitRect2.midY)
            if let dblClickEv = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: center2,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: pinPanel.windowNumber,
                context: nil,
                eventNumber: 10,
                clickCount: 2,
                pressure: 1.0
            ) {
                canvas.mouseDown(with: dblClickEv)
                t.check(
                    vm.editingExistingTextAnnotationID == vm.annotations[0].id && vm.strokePreset == .thick && vm.textBackgroundStyle == .black,
                    "Double-clicking committed text restores original strokePreset (.thick) and textBackgroundStyle (.black) for in-place re-editing"
                )
                // Mutate color, preset, background, and text during active re-edit, then cancel via Escape command selector
                vm.selectedColor = .purple
                vm.strokePreset = .thin
                vm.textBackgroundStyle = .white
                canvas.textField?.stringValue = "DiscardedEdit"
                if let tf = canvas.textField {
                    _ = canvas.control(tf, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
                } else {
                    vm.cancelPendingTextEditing()
                }
                t.check(
                    vm.annotations.count == 1 &&
                    vm.annotations[0].text == "LiveColorText" &&
                    vm.annotations[0].color == NSColor(.orange) &&
                    vm.annotations[0].lineWidth == StrokePreset.thick.textFontSize &&
                    vm.annotations[0].textBackgroundStyle == .black &&
                    vm.editingExistingTextAnnotationID == nil,
                    "Pressing Esc during double-click re-edit restores the original text, color, font size, and background style"
                )
            }
        }

        // Verify clicking a second text annotation while an empty re-edit on the first annotation is committed does NOT crash or select stale index
        let secondAnnotation = PinAnnotation(
            tool: .text,
            color: NSColor(.cyan),
            lineWidth: StrokePreset.medium.textFontSize,
            points: [CGPoint(x: 0.2, y: 0.75)],
            text: "SecondItem",
            textBackgroundStyle: .black
        )
        vm.annotations.append(secondAnnotation)
        let firstID = vm.annotations[0].id
        let secondID = secondAnnotation.id
        vm.editingExistingTextAnnotationID = firstID
        vm.editingOriginalAnnotationSnapshot = vm.annotations[0]
        canvas.showInlineTextField(atNormalized: vm.annotations[0].points[0], in: canvas.imageRectInView, initialText: "")
        if let secondHitRect = canvas.textAnnotationHitRectInView(secondAnnotation),
           let clickSecondEv = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: secondHitRect.midX, y: secondHitRect.midY),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: pinPanel.windowNumber,
            context: nil,
            eventNumber: 11,
            clickCount: 1,
            pressure: 1.0
           ) {
            canvas.mouseDown(with: clickSecondEv)
            canvas.mouseUp(with: clickSecondEv)
            t.check(
                vm.annotations.count == 1 &&
                vm.annotations[0].id == secondID &&
                vm.selectedTextAnnotationID == secondID,
                "Clicking a second text annotation while committing an empty re-edit on the first deletes the first and safely selects the second without index out-of-range"
            )
        }

        // Verify Feature 3: Selecting, dragging, restyling, right-click erasing, and Delete-key removing non-text shapes (.rect / .arrow) even while a drawing tool is active
        vm.activeTool = .arrow
        let rectAnnotation = PinAnnotation(
            tool: .rect,
            color: NSColor(.red),
            lineWidth: StrokePreset.thin.strokeLineWidth,
            points: [CGPoint(x: 0.20, y: 0.20), CGPoint(x: 0.50, y: 0.50)]
        )
        let arrowAnnotation = PinAnnotation(
            tool: .arrow,
            color: NSColor(.blue),
            lineWidth: StrokePreset.medium.strokeLineWidth,
            points: [CGPoint(x: 0.60, y: 0.30), CGPoint(x: 0.85, y: 0.60)]
        )
        vm.annotations.append(rectAnnotation)
        vm.annotations.append(arrowAnnotation)
        let imgR = canvas.imageRectInView
        let rectTopBorderPt = NSPoint(
            x: imgR.minX + 0.35 * imgR.width,
            y: imgR.maxY - 0.20 * imgR.height
        )
        let rectInteriorPt = NSPoint(
            x: imgR.minX + 0.35 * imgR.width,
            y: imgR.maxY - 0.35 * imgR.height
        )
        t.check(
            canvas.hitTestTextAnnotationIndex(viewPoint: rectTopBorderPt) != nil &&
            canvas.hitTestTextAnnotationIndex(viewPoint: rectInteriorPt) == nil,
            "Hollow .rect annotation hits on its border stroke even when another drawing tool (.arrow) is active, and ignores clicks inside its hollow interior"
        )
        if let downRect = NSEvent.mouseEvent(
            with: .leftMouseDown, location: rectTopBorderPt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 20, clickCount: 1, pressure: 1.0
        ),
           let dragRect = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: rectTopBorderPt.x + 24, y: rectTopBorderPt.y - 18), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 21, clickCount: 1, pressure: 1.0
           ),
           let upRect = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: rectTopBorderPt.x + 24, y: rectTopBorderPt.y - 18), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 22, clickCount: 1, pressure: 1.0
           ) {
            canvas.mouseDown(with: downRect)
            canvas.mouseDragged(with: dragRect)
            canvas.mouseUp(with: upRect)
            let movedRect = vm.annotations.first(where: { $0.id == rectAnnotation.id })
            let dx0 = (movedRect?.points[0].x ?? 0) - 0.20
            let dx1 = (movedRect?.points[1].x ?? 0) - 0.50
            let dy0 = (movedRect?.points[0].y ?? 0) - 0.20
            let dy1 = (movedRect?.points[1].y ?? 0) - 0.50
            t.check(
                vm.selectedTextAnnotationID == rectAnnotation.id &&
                dx0 > 0.05 && abs(dx0 - dx1) < 0.001 &&
                dy0 > 0.05 && abs(dy0 - dy1) < 0.001,
                "Selecting and dragging apreviously drawn .rect annotation while .arrow is still active translates both corners uniformly without starting a new arrow",
                detail: "movedPts=\(String(describing: movedRect?.points))"
            )
            // Restyle selected .rect color & stroke preset
            vm.selectedColor = .green
            vm.strokePreset = .thick
            let restyledRect = vm.annotations.first(where: { $0.id == rectAnnotation.id })
            t.check(
                restyledRect?.color == NSColor(.green) && restyledRect?.lineWidth == StrokePreset.thick.strokeLineWidth,
                "Changing selectedColor and strokePreset updates a selected non-text shape (.rect)"
            )
            // Switching activeTool clears selection so preparing the next tool does NOT mutate the previous shape
            vm.activeTool = .mosaic
            vm.strokePreset = .thin
            let preservedRect = vm.annotations.first(where: { $0.id == rectAnnotation.id })
            t.check(
                vm.selectedTextAnnotationID == nil &&
                preservedRect?.lineWidth == StrokePreset.thick.strokeLineWidth,
                "Switching activeTool clears selection so changing strokePreset for the next tool does not mutate the previously selected annotation"
            )
            // Reselect .rect and press Delete (keyCode 51) to remove it, then verify Undo restores it
            vm.selectedTextAnnotationID = rectAnnotation.id
            if let deleteEv = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: pinPanel.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51
            ) {
                pinPanel.keyDown(with: deleteEv)
                t.check(
                    !vm.annotations.contains(where: { $0.id == rectAnnotation.id }) &&
                    vm.selectedTextAnnotationID == nil &&
                    pinPanel.isVisible,
                    "Pressing Delete removes the selected annotation and keeps the pin panel open"
                )
                vm.undo()
                t.check(
                    vm.annotations.contains(where: { $0.id == rectAnnotation.id }),
                    "Invoking Undo after Delete restores the deleted annotation instead of popping another annotation"
                )
                // Delete it again so subsequent composite check stays clean
                vm.selectedTextAnnotationID = rectAnnotation.id
                _ = vm.deleteSelectedAnnotation()
            } else {
                t.check(false, "Constructed Delete keyEvent for .rect removal test")
            }
        } else {
            t.check(false, "Constructed mouse events for .rect drag test")
        }
        // Also verify dragging the second annotation (.arrow) by its arrowhead while .arrow tool is active, then right-click erasing and undoing
        let arrowTipWingPt = NSPoint(
            x: imgR.minX + 0.85 * imgR.width - 6.0,
            y: imgR.maxY - 0.60 * imgR.height + 8.0
        )
        if let downArrow = NSEvent.mouseEvent(
            with: .leftMouseDown, location: arrowTipWingPt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 25, clickCount: 1, pressure: 1.0
        ),
           let dragArrow = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: arrowTipWingPt.x - 16, y: arrowTipWingPt.y + 12), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 26, clickCount: 1, pressure: 1.0
           ),
           let upArrow = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: arrowTipWingPt.x - 16, y: arrowTipWingPt.y + 12), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 27, clickCount: 1, pressure: 1.0
           ) {
            vm.activeTool = .arrow
            canvas.mouseDown(with: downArrow)
            canvas.mouseDragged(with: dragArrow)
            canvas.mouseUp(with: upArrow)
            let movedArrow = vm.annotations.first(where: { $0.id == arrowAnnotation.id })
            t.check(
                vm.selectedTextAnnotationID == arrowAnnotation.id &&
                (movedArrow?.points[0].x ?? 1.0) < 0.58 &&
                (movedArrow?.points[1].x ?? 1.0) < 0.83,
                "Clicking and dragging the second annotation (.arrow) near its arrowhead while .arrow tool is active moves the existing arrow instead of drawing a third shape"
            )
            vm.undo()
        } else {
            t.check(false, "Constructed mouse events for .arrow arrowhead drag test")
        }
        // Right-click on the arrow annotation to erase it in one step, then verify Undo can restore it
        let arrowMidPt = NSPoint(
            x: imgR.minX + 0.725 * imgR.width,
            y: imgR.maxY - 0.45 * imgR.height
        )
        if let rightClickArrow = NSEvent.mouseEvent(
            with: .rightMouseDown, location: arrowMidPt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 23, clickCount: 1, pressure: 1.0
        ) {
            canvas.rightMouseDown(with: rightClickArrow)
            t.check(
                !vm.annotations.contains(where: { $0.id == arrowAnnotation.id }),
                "Right-clicking any annotation immediately erases that annotation"
            )
            vm.undo()
            t.check(
                vm.annotations.contains(where: { $0.id == arrowAnnotation.id }),
                "Undoing after right-click erase restores the erased annotation"
            )
            canvas.rightMouseDown(with: rightClickArrow)
        } else {
            t.check(false, "Constructed rightMouseDown event for .arrow erase test")
        }
        // Verify placing and dragging a counter badge in a single mouseDown->mouseDragged->mouseUp gesture is undone in ONE Undo step
        vm.activeTool = .counter
        let counterPlacePt = NSPoint(x: imgR.minX + 0.30 * imgR.width, y: imgR.maxY - 0.30 * imgR.height)
        if let cDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: counterPlacePt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 28, clickCount: 1, pressure: 1.0
        ),
           let cDrag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: counterPlacePt.x + 20, y: counterPlacePt.y - 15), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 29, clickCount: 1, pressure: 1.0
           ),
           let cUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: counterPlacePt.x + 20, y: counterPlacePt.y - 15), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 30, clickCount: 1, pressure: 1.0
           ) {
            let countBeforeCounter = vm.annotations.count
            canvas.mouseDown(with: cDown)
            canvas.mouseDragged(with: cDrag)
            canvas.mouseUp(with: cUp)
            vm.undo()
            t.check(
                vm.annotations.count == countBeforeCounter,
                "Placing and dragging a counter badge in one gesture is completely removed by a single Undo"
            )
        } else {
            t.check(false, "Constructed mouse events for single-gesture counter place+drag Undo test")
        }
        // Verify right-click erasing a counter badge resequences remaining counters and Undo restores them
        let rcBadge1 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.25, y: 0.75)], text: "1")
        let rcBadge2 = PinAnnotation(tool: .counter, color: .systemRed, lineWidth: 28, points: [CGPoint(x: 0.55, y: 0.75)], text: "2")
        vm.annotations.append(rcBadge1)
        vm.annotations.append(rcBadge2)
        vm.selectedTextAnnotationID = rcBadge1.id
        let rcBadge1Pt = NSPoint(
            x: imgR.minX + 0.25 * imgR.width,
            y: imgR.maxY - 0.75 * imgR.height
        )
        if let rightClickCounter = NSEvent.mouseEvent(
            with: .rightMouseDown, location: rcBadge1Pt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 24, clickCount: 1, pressure: 1.0
        ) {
            canvas.rightMouseDown(with: rightClickCounter)
            t.check(
                vm.selectedTextAnnotationID == nil &&
                vm.annotations.filter({ $0.tool == .counter }).map(\.text) == ["1"] &&
                vm.nextCounterLabel == "2",
                "Right-clicking a selected counter badge clears selection and resequences remaining counter badges"
            )
            vm.undo()
            t.check(
                vm.annotations.filter({ $0.tool == .counter }).map(\.text) == ["1", "2"] &&
                vm.nextCounterLabel == "3",
                "Undoing a right-click counter deletion restores both counter badges in sequence"
            )
            vm.annotations.removeAll(where: { $0.id == rcBadge1.id || $0.id == rcBadge2.id })
        } else {
            t.check(false, "Constructed rightMouseDown event for counter erase test")
        }
        // Verify restyling .highlighter and .mosaic annotations and mosaic color exclusion
        let hiAnn = PinAnnotation(tool: .highlighter, color: .systemYellow, lineWidth: StrokePreset.thin.highlighterBrushWidth, points: [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.4, y: 0.8)])
        let mosAnn = PinAnnotation(tool: .mosaic, color: .clear, lineWidth: StrokePreset.thin.mosaicBrushWidth, points: [CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.8, y: 0.8)])
        vm.annotations.append(hiAnn)
        vm.annotations.append(mosAnn)
        vm.selectedTextAnnotationID = hiAnn.id
        vm.strokePreset = .thick
        vm.selectedColor = .orange
        let updatedHi = vm.annotations.first(where: { $0.id == hiAnn.id })
        vm.selectedTextAnnotationID = mosAnn.id
        vm.strokePreset = .medium
        vm.selectedColor = .blue
        let updatedMos = vm.annotations.first(where: { $0.id == mosAnn.id })
        t.check(
            updatedHi?.lineWidth == StrokePreset.thick.highlighterBrushWidth &&
            updatedHi?.color == NSColor(.orange) &&
            updatedMos?.lineWidth == StrokePreset.medium.mosaicBrushWidth &&
            updatedMos?.color == .clear,
            "Restyling .highlighter and .mosaic maps to tool-specific brush widths and preserves .mosaic color exclusion"
        )
        vm.annotations.removeAll(where: { $0.id == hiAnn.id || $0.id == mosAnn.id })
        vm.selectedTextAnnotationID = nil
        vm.activeTool = nil

        // Verify thick (.thick = 7.5pt) arrow outer wing tip is hit-testable
        let thickArrow = PinAnnotation(tool: .arrow, color: .systemRed, lineWidth: StrokePreset.thick.strokeLineWidth, points: [CGPoint(x: 0.2, y: 0.5), CGPoint(x: 0.8, y: 0.5)])
        vm.annotations.append(thickArrow)
        let thickHeadLength: CGFloat = StrokePreset.thick.strokeLineWidth * 3.4 * vm.scale
        let thickWingPt = NSPoint(
            x: imgR.minX + imgR.width * 0.8 - thickHeadLength * cos(.pi / 6),
            y: imgR.maxY - imgR.height * 0.5 + thickHeadLength * sin(.pi / 6)
        )
        t.check(
            canvas.hitTestTextAnnotationIndex(viewPoint: thickWingPt) != nil,
            "Thick arrow outer arrowhead wing tips are hit-testable for dragging and right-click erasing"
        )
        vm.annotations.removeAll(where: { $0.id == thickArrow.id })

        // Verify double-clicking a text annotation and committing without changes does not push a no-op undo snapshot
        let unchangedTextAnn = PinAnnotation(
            tool: .text,
            color: NSColor(vm.selectedColor),
            lineWidth: vm.strokePreset.textFontSize,
            points: [CGPoint(x: 0.3, y: 0.4)],
            text: "NoOpCheck",
            textBackgroundStyle: vm.textBackgroundStyle
        )
        vm.recordUndoSnapshot()
        vm.annotations.append(unchangedTextAnn)
        let undoCountBeforeNoOpText = vm.undoHistory.count
        vm.editingExistingTextAnnotationID = unchangedTextAnn.id
        vm.editingOriginalAnnotationSnapshot = unchangedTextAnn
        vm.pendingTextNormalizedPos = unchangedTextAnn.points[0]
        vm.pendingTextString = unchangedTextAnn.text
        vm.commitPendingText()
        t.check(
            vm.undoHistory.count == undoCountBeforeNoOpText,
            "Committing an existing text annotation without changes does not push a redundant undo snapshot"
        )

        // Verify pressing Undo mid-drag cancels the active drag so subsequent mouseDragged events do not overwrite the undo
        let midDragStartPt = NSPoint(
            x: imgR.minX + 0.3 * imgR.width + 6,
            y: imgR.maxY - 0.4 * imgR.height - 6
        )
        if let mdDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: midDragStartPt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 40, clickCount: 1, pressure: 1.0
        ),
           let mdMove1 = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: midDragStartPt.x + 25, y: midDragStartPt.y - 20), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 41, clickCount: 1, pressure: 1.0
           ),
           let mdMove2 = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: midDragStartPt.x + 50, y: midDragStartPt.y - 40), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 42, clickCount: 1, pressure: 1.0
           ),
           let mdUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: midDragStartPt.x + 50, y: midDragStartPt.y - 40), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 43, clickCount: 1, pressure: 1.0
           ) {
            canvas.mouseDown(with: mdDown)
            canvas.mouseDragged(with: mdMove1)
            vm.undo()
            let posAfterMidDragUndo = vm.annotations.first(where: { $0.id == unchangedTextAnn.id })?.points.first
            canvas.mouseDragged(with: mdMove2)
            canvas.mouseUp(with: mdUp)
            let posAfterContinuedMove = vm.annotations.first(where: { $0.id == unchangedTextAnn.id })?.points.first
            t.check(
                posAfterMidDragUndo == CGPoint(x: 0.3, y: 0.4) &&
                posAfterContinuedMove == CGPoint(x: 0.3, y: 0.4),
                "Invoking Undo during an active annotation drag cancels the drag so further mouse movement does not overwrite the restored position"
            )
        } else {
            t.check(false, "Constructed mouse events for mid-drag Undo cancellation test")
        }
        vm.annotations.removeAll(where: { $0.id == unchangedTextAnn.id })

        // Verify Emoji Sticker (.emoji) placement, quick emoji selection, system picker insertText, and composite rendering
        vm.activeTool = .emoji
        vm.selectedEmoji = "🔥"
        let emojiPlacePt = NSPoint(x: imgR.minX + 0.45 * imgR.width, y: imgR.maxY - 0.55 * imgR.height)
        if let eDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: emojiPlacePt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 50, clickCount: 1, pressure: 1.0
        ),
           let eUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: emojiPlacePt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 51, clickCount: 1, pressure: 1.0
           ) {
            canvas.mouseDown(with: eDown)
            canvas.mouseUp(with: eUp)
            let placedEmoji = vm.annotations.last
            t.check(
                placedEmoji?.tool == .emoji &&
                placedEmoji?.text == "🔥" &&
                placedEmoji?.lineWidth == PinAnnotation.defaultEmojiFontSize &&
                vm.selectedTextAnnotationID == placedEmoji?.id,
                "Clicking canvas with .emoji tool places emoji sticker and auto-selects it"
            )
            // Changing selectedEmoji while an emoji sticker is selected deselects the placed sticker and leaves its emoji unchanged
            vm.selectedEmoji = "🚀"
            let updatedEmoji = vm.annotations.last
            t.check(
                updatedEmoji?.text == "🔥" && vm.selectedTextAnnotationID == nil,
                "Changing selectedEmoji deselects the previously placed .emoji annotation without overwriting its emoji"
            )
            // System Character Palette insertText(_:) or hidden emojiCaptureInputView text insertion updates selectedEmoji for the next sticker without mutating existing ones
            vm.selectedTextAnnotationID = updatedEmoji?.id
            canvas.openSystemEmojiPicker()
            if let responderView = pinPanel.firstResponder as? NSTextView {
                responderView.insertText("🦄", replacementRange: NSRange(location: 0, length: 0))
            } else {
                canvas.insertText("🦄")
            }
            t.check(
                vm.selectedEmoji == "🦄" && vm.selectedTextAnnotationID == nil && vm.annotations.last?.text == "🔥",
                "insertText from macOS Character Palette updates selectedEmoji and deselects the previous emoji sticker"
            )
        } else {
            t.check(false, "Constructed mouse events for .emoji placement test")
        }

        // Verify 4-corner drag resizing on committed .emoji, .counter, and .text annotations (with custom size preservation on double-click re-edit)
        if let emojiID = vm.annotations.last(where: { $0.tool == .emoji })?.id,
           let emojiItem = vm.annotations.first(where: { $0.id == emojiID }),
           let emojiHitRect = canvas.textAnnotationHitRectInView(emojiItem),
           let reselectDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: NSPoint(x: emojiHitRect.midX, y: emojiHitRect.midY), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 51, clickCount: 1, pressure: 1.0
           ),
           let reselectUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: emojiHitRect.midX, y: emojiHitRect.midY), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 51, clickCount: 1, pressure: 1.0
           ) {
            // Clicking an earlier emoji sticker on canvas re-selects it (preserving selection for corner resize)
            canvas.mouseDown(with: reselectDown)
            canvas.mouseUp(with: reselectUp)
            let handles = canvas.selectedAnnotationCornerHandlesInView()
            t.check(
                vm.selectedTextAnnotationID == emojiID && handles.count == 4,
                "Clicking an existing .emoji annotation re-selects it and exposes 4 corner resize handles"
            )
            if let brHandlePt = handles.first(where: { $0.0 == .bottomRight })?.1,
               let rDown = NSEvent.mouseEvent(
                with: .leftMouseDown, location: brHandlePt, modifierFlags: [],
                timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 52, clickCount: 1, pressure: 1.0
               ),
               let rDrag = NSEvent.mouseEvent(
                with: .leftMouseDragged, location: NSPoint(x: brHandlePt.x + 25, y: brHandlePt.y - 25), modifierFlags: [],
                timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 53, clickCount: 1, pressure: 1.0
               ),
               let rUp = NSEvent.mouseEvent(
                with: .leftMouseUp, location: NSPoint(x: brHandlePt.x + 25, y: brHandlePt.y - 25), modifierFlags: [],
                timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 54, clickCount: 1, pressure: 1.0
               ) {
                let startEmojiWidth = vm.annotations.first(where: { $0.id == emojiID })?.lineWidth ?? 0
                let undoBeforeEmojiResize = vm.undoHistory.count
                canvas.mouseDown(with: rDown)
                canvas.mouseDragged(with: rDrag)
                canvas.mouseUp(with: rUp)
                let resizedEmojiWidth = vm.annotations.first(where: { $0.id == emojiID })?.lineWidth ?? 0
                t.check(
                    resizedEmojiWidth > startEmojiWidth + 4.0 &&
                    vm.undoHistory.count == undoBeforeEmojiResize + 1,
                    "Dragging a corner handle on a selected .emoji annotation scales its size smoothly and records a single undo snapshot",
                    detail: "start=\(startEmojiWidth), resized=\(resizedEmojiWidth)"
                )
                vm.undo()
                let restoredEmojiWidth = vm.annotations.first(where: { $0.id == emojiID })?.lineWidth ?? 0
                t.check(
                    abs(restoredEmojiWidth - startEmojiWidth) < 0.01,
                    "Undoing a corner-handle resize restores the previous annotation size"
                )
            }
            vm.annotations.removeAll(where: { $0.id == emojiID })
        }

        // Verify corner-handle resize on committed .text annotation AND preserving custom size across double-click re-edit
        let resizableText = PinAnnotation(
            tool: .text,
            color: NSColor(.white),
            lineWidth: StrokePreset.medium.textFontSize,
            points: [CGPoint(x: 0.25, y: 0.45)],
            text: "ScaleMe",
            textBackgroundStyle: .black
        )
        vm.annotations.append(resizableText)
        vm.selectedTextAnnotationID = resizableText.id
        _ = canvas.selectedAnnotationCornerHandlesInView()
        func dragTextTopLeft(by delta: NSPoint, eventBase: Int) -> Bool {
            guard let tlPt = canvas.selectedAnnotationCornerHandlesInView().first(where: { $0.0 == .topLeft })?.1,
                  let down = NSEvent.mouseEvent(with: .leftMouseDown, location: tlPt, modifierFlags: [], timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: eventBase, clickCount: 1, pressure: 1.0),
                  let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: tlPt.x + delta.x, y: tlPt.y + delta.y), modifierFlags: [], timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: eventBase + 1, clickCount: 1, pressure: 1.0),
                  let up = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: tlPt.x + delta.x, y: tlPt.y + delta.y), modifierFlags: [], timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: eventBase + 2, clickCount: 1, pressure: 1.0) else { return false }
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: drag)
            canvas.mouseUp(with: up)
            return true
        }
        let tlRectBefore = vm.annotations.first(where: { $0.id == resizableText.id }).flatMap { canvas.textAnnotationHitRectInView($0) } ?? .zero
        let tlSizeBefore = vm.annotations.first(where: { $0.id == resizableText.id })?.lineWidth ?? 0
        t.check(dragTextTopLeft(by: NSPoint(x: -14, y: 10), eventBase: 58), "Constructed top-left text handle outward drag events")
        let tlItemOut = vm.annotations.first(where: { $0.id == resizableText.id })
        let tlRectOut = tlItemOut.flatMap { canvas.textAnnotationHitRectInView($0) } ?? .zero
        t.check(
            (tlItemOut?.lineWidth ?? 0) > tlSizeBefore + 1.0 &&
            abs(tlRectOut.maxX - tlRectBefore.maxX) < 4.0 && abs(tlRectOut.minY - tlRectBefore.minY) < 4.0,
            "Dragging a .text top-left handle outward grows the font while the opposite (bottom-right) corner stays fixed",
            detail: "size \(tlSizeBefore)->\(tlItemOut?.lineWidth ?? 0), rect \(tlRectBefore)->\(tlRectOut)"
        )
        let tlSizeOut = tlItemOut?.lineWidth ?? 0
        t.check(dragTextTopLeft(by: NSPoint(x: 10, y: -8), eventBase: 61), "Constructed top-left text handle inward drag events")
        t.check(
            (vm.annotations.first(where: { $0.id == resizableText.id })?.lineWidth ?? 0) < tlSizeOut - 1.0,
            "Dragging a .text top-left handle inward shrinks the font"
        )
        if let brTextPt = canvas.selectedAnnotationCornerHandlesInView().first(where: { $0.0 == .bottomRight })?.1,
           let trDown = NSEvent.mouseEvent(
            with: .leftMouseDown, location: brTextPt, modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 55, clickCount: 1, pressure: 1.0
           ),
           let trDrag = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: NSPoint(x: brTextPt.x + 36, y: brTextPt.y - 24), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 56, clickCount: 1, pressure: 1.0
           ),
           let trUp = NSEvent.mouseEvent(
            with: .leftMouseUp, location: NSPoint(x: brTextPt.x + 36, y: brTextPt.y - 24), modifierFlags: [],
            timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 57, clickCount: 1, pressure: 1.0
           ) {
            let beforeTextWidth = vm.annotations.first(where: { $0.id == resizableText.id })?.lineWidth ?? 0
            canvas.mouseDown(with: trDown)
            canvas.mouseDragged(with: trDrag)
            canvas.mouseUp(with: trUp)
            let customTextWidth = vm.annotations.first(where: { $0.id == resizableText.id })?.lineWidth ?? 0
            t.check(
                customTextWidth > beforeTextWidth + 3.0,
                "Dragging a corner handle on a committed .text annotation scales its font size",
                detail: "before=\(beforeTextWidth), after=\(customTextWidth)"
            )
            // Double-click to re-edit text content without touching S/M/L preset: custom font size must be preserved!
            if let hitRectAfterResize = vm.annotations.first(where: { $0.id == resizableText.id }).flatMap({ canvas.textAnnotationHitRectInView($0) }),
               let dblEv = NSEvent.mouseEvent(
                with: .leftMouseDown, location: NSPoint(x: hitRectAfterResize.midX, y: hitRectAfterResize.midY), modifierFlags: [],
                timestamp: 0, windowNumber: pinPanel.windowNumber, context: nil, eventNumber: 58, clickCount: 2, pressure: 1.0
               ) {
                canvas.mouseDown(with: dblEv)
                canvas.textField?.stringValue = "ScaleMeEdited"
                vm.commitPendingText()
                let editedItem = vm.annotations.first(where: { $0.id == resizableText.id })
                t.check(
                    editedItem?.text == "ScaleMeEdited" &&
                    abs((editedItem?.lineWidth ?? 0) - customTextWidth) < 0.01,
                    "Double-clicking and editing a custom-resized .text annotation preserves its custom font size unless S/M/L is clicked",
                    detail: "customTextWidth=\(customTextWidth), editedLineWidth=\(String(describing: editedItem?.lineWidth))"
                )
            }
            // Clicking S/M/L preset while selected snaps back to the preset size
            vm.selectedTextAnnotationID = resizableText.id
            vm.strokePreset = .thin
            let snappedItem = vm.annotations.first(where: { $0.id == resizableText.id })
            t.check(
                snappedItem?.lineWidth == StrokePreset.thin.textFontSize,
                "Selecting S/M/L preset on a custom-resized .text annotation snaps it to the chosen preset font size"
            )
        }
        vm.annotations.removeAll(where: { $0.id == resizableText.id })
        vm.selectedTextAnnotationID = nil
        vm.activeTool = nil
    }
    let composite = vm.renderCompositeImage()
    t.check(composite?.size == vm.baseSize, "renderCompositeImage outputs exact baseSize")

    let tinyImg = makeTextImage(text: "TINY", size: NSSize(width: 48, height: 36))
    let tinyVM = PinSessionViewModel(image: tinyImg)
    let tinyCanvas = PinCanvasNSView(frame: NSRect(x: 0, y: 0, width: 80, height: 68), vm: tinyVM)
    tinyCanvas.showInlineTextField(atNormalized: CGPoint(x: 0.95, y: 0.95), in: tinyCanvas.imageRectInView)
    if let tfFrame = tinyCanvas.textField?.frame {
        t.check(
            tfFrame.minX >= 4 && tfFrame.maxX <= tinyCanvas.bounds.width - 4 && tfFrame.width >= 56,
            "showInlineTextField clamps NSTextField safely inside tiny (<160pt) canvas bounds",
            detail: "tfFrame=\(tfFrame), bounds=\(tinyCanvas.bounds)"
        )
    } else {
        t.check(false, "showInlineTextField creates NSTextField on tiny canvas")
    }

    // Verify 4F: Clipping to Clothesline Dock (`P` key) & Unclipping (using isolated testPasteboard)
    if let pKeyEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: tbPanel.windowNumber,
        context: nil,
        characters: "p",
        charactersIgnoringModifiers: "p",
        isARepeat: false,
        keyCode: 35 // kVK_ANSI_P
    ) {
        tbPanel.keyDown(with: pKeyEvent)
        t.check(ClotheslineManager.shared.items.count == 1, "Pressing 'P' on toolbar panel clips item onto ClotheslineManager")
        t.check(!pinPanel.isVisible && !tbPanel.isVisible, "Clipping hides both floating canvas panel and toolbar panel")
        t.check(ClotheslineManager.shared.dockPanel?.isVisible == true, "Clothesline dock panel is visible at top of screen")
    } else {
        t.check(false, "Constructed P keyEvent")
    }

    if let clippedItem = ClotheslineManager.shared.items.first {
        ClotheslineManager.shared.restoreToCanvas(clippedItem)
        t.check(ClotheslineManager.shared.items.isEmpty, "restoreToCanvas removes item from clothesline")
        t.check(pinPanel.isVisible && tbPanel.isVisible, "restoreToCanvas makes both pinPanel and tbPanel visible again")
    } else {
        t.check(false, "Clipped item present for restoreToCanvas")
    }

    // Verify 4G: Esc key discards/closes both panels without writing to clipboard
    testPasteboard.clearContents()
    testPasteboard.setString("SENTINEL_CLIPBOARD_STRING", forType: .string)
    if let escEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: pinPanel.windowNumber,
        context: nil,
        characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}",
        isARepeat: false,
        keyCode: 53 // kVK_Escape
    ) {
        pinPanel.keyDown(with: escEvent)
        t.check(!pinPanel.isVisible && !tbPanel.isVisible, "Pressing Esc closes both PinFloatingPanel and PinToolbarPanel")
        t.check(vm.isClosed == true, "Closing panel marks PinSessionViewModel.isClosed = true to block late OCR callbacks")
        t.check(daemon.activePanels.isEmpty && daemon.activeToolbars.isEmpty, "Closing panel removes references from PinDaemonApp")
        t.check(
            testPasteboard.string(forType: .string) == "SENTINEL_CLIPBOARD_STRING",
            "Pressing Esc discards screenshot WITHOUT overwriting pasteboard"
        )
    } else {
        t.check(false, "Constructed Esc keyEvent")
    }

    // Verify 4H: Pressing Return/Enter copies to pasteboard and closes synchronously (no 150ms race window)
    let enterVM = PinSessionViewModel(image: baseImg)
    daemon.presentPinPanel(vm: enterVM, frame: panelFrame)
    if let enterPanel = enterVM.hostingPanel,
       let returnEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: enterPanel.windowNumber,
        context: nil,
        characters: "\r",
        charactersIgnoringModifiers: "\r",
        isARepeat: false,
        keyCode: 36 // kVK_Return
    ) {
        enterPanel.keyDown(with: returnEvent)
        t.check(
            !enterPanel.isVisible && daemon.activePanels.isEmpty && enterVM.isClosed,
            "Pressing Return copies image and closes PinFloatingPanel synchronously (no delayed close race)"
        )
    }

}
