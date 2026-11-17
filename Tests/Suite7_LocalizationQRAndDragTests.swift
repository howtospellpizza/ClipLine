import AppKit
import CoreGraphics
import Foundation

@MainActor
func runSuite7LocalizationQRAndDragTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    let f = makeDefaultCaptureFixtures()
    let baseImg = f.baseImg
    let panelFrame = f.panelFrame
    let daemon = PinDaemonApp()
    // Suite 7: Localization (Language Tag Matching, Exhaustive EN/zh-Hans Copy & Toolbar Layout)
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 7: Localization (EN & Simplified Chinese)")
    let originalLang = AppLanguage.current
    defer { AppLanguage.current = originalLang }

    t.check(
        AppLanguage.resolveLanguage(envOverride: "zh-CN", preferredLanguages: ["en-US"]) == .zhHans &&
        AppLanguage.resolveLanguage(envOverride: "en_US", preferredLanguages: ["zh-Hans-CN"]) == .en,
        "CLIP_LINE_LANG environment override takes precedence over preferredLanguages"
    )
    t.check(
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["zh-Hant-HK", "en-US"]) == .en &&
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["zh-Hans-CN", "en-US"]) == .zhHans &&
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["ja-JP", "zh-SG"]) == .zhHans &&
        AppLanguage.resolveLanguage(envOverride: nil, preferredLanguages: ["fr-FR", "de-DE"]) == .en,
        "Preferred language resolution matches first supported tag and does not misclassify Traditional Chinese (zh-Hant) as zh-Hans"
    )
    t.check(
        AppLanguage.resolveTranslateTargetLanguage(envOverride: "ja", uiLanguage: .en) == "ja" &&
        AppLanguage.resolveTranslateTargetLanguage(envOverride: nil, uiLanguage: .en) == "en" &&
        AppLanguage.resolveTranslateTargetLanguage(envOverride: nil, uiLanguage: .zhHans) == "zh-CN",
        "CLIP_LINE_TRANSLATE_TARGET overrides default translate target while keeping UI language independent"
    )

    AppLanguage.current = .en
    t.check(
        PinAnnotation.Tool.rect.localizedName == "Rectangle" &&
        StrokePreset.thin.localizedShortLabel == "S" &&
        TextBackgroundStyle.transparent.localizedShortLabel == "Clear" &&
        L10n.toolbarTranslateShortLabel == "Trans" &&
        L10n.toastCopiedPhotos(1) == "Copied 1 image to clipboard" &&
        L10n.toastCopiedPhotos(3) == "Copied 3 images to clipboard",
        "English localization produces compact labels and proper singular/plural toasts"
    )

    // Verify English toolbar layout with .text tool active (widest configuration: tools + S/M/L + 6 colors + Clear/Dark/Light + actions)
    let enVM = PinSessionViewModel(image: baseImg)
    daemon.presentPinPanel(vm: enVM, frame: panelFrame)
    enVM.activeTool = .text
    let enToolbarWidth = enVM.toolbarPanel?.frame.width ?? 0
    let screenVisibleWidth = max(1280, (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.width ?? 1440)
    t.check(
        enToolbarWidth > 500 && enToolbarWidth < min(1100, screenVisibleWidth - 16),
        "English toolbar in widest (.text) state fits cleanly within screen bounds (\(Int(enToolbarWidth))pt)"
    )
    enVM.hostingPanel?.onClosePanel?()

    AppLanguage.current = .zhHans
    t.check(
        PinAnnotation.Tool.rect.localizedName == "框选" &&
        StrokePreset.thin.localizedShortLabel == "细" &&
        TextBackgroundStyle.transparent.localizedShortLabel == "透明" &&
        L10n.toolbarTranslateShortLabel == "译" &&
        L10n.toastCopiedPhotos(2) == "已复制 2 张照片到剪贴板",
        "Simplified Chinese localization produces expected native labels and toasts"
    )

    // Verify Clothesline photo drag-out file export (single & multi-selected) & window-background drag isolation, plus QR Code detection
    let pinFeatureVM = PinSessionViewModel(image: baseImg)
    let pinFeatureVM2 = PinSessionViewModel(image: baseImg)
    daemon.presentPinPanel(vm: pinFeatureVM, frame: panelFrame)
    daemon.presentPinPanel(vm: pinFeatureVM2, frame: panelFrame)
    pinFeatureVM.clipToClothesline()
    pinFeatureVM2.clipToClothesline()
    if ClotheslineManager.shared.items.count == 2 {
        let firstClipped = ClotheslineManager.shared.items[0]
        let secondClipped = ClotheslineManager.shared.items[1]
        let multiDragFiles = ClotheslineManager.shared.writeDragExportFiles(startingFrom: firstClipped, tempDir: testTempDirURL.path)
        t.check(
            multiDragFiles.count == 2 &&
            multiDragFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) } &&
            multiDragFiles[0].url != multiDragFiles[1].url,
            "Dragging a selected photo on Clothesline exports all currently selected photos together for multi-item drag-and-drop"
        )
        // Deselect the second photo, then verify dragging the unselected second photo exports only that photo
        ClotheslineManager.shared.toggleSelection(secondClipped.id)
        let unselectedSecond = ClotheslineManager.shared.items[1]
        let singleUnselectedDrag = ClotheslineManager.shared.writeDragExportFiles(startingFrom: unselectedSecond, tempDir: testTempDirURL.path)
        t.check(
            singleUnselectedDrag.count == 1 && singleUnselectedDrag.first?.item.id == secondClipped.id,
            "Dragging an unselected photo exports only that photo without including other selected items"
        )
        t.check(
            ClotheslineManager.shared.dockPanel?.isMovableByWindowBackground == false,
            "Clothesline dockPanel sets isMovableByWindowBackground = false so photo drags are not intercepted by AppKit window moving"
        )
        let photoDragView = ClotheslinePhotoDragNSView(frame: NSRect(x: 0, y: 0, width: 90, height: 64))
        let ropeDragView = ClotheslineRopeDragNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        t.check(
            photoDragView.mouseDownCanMoveWindow == false &&
            ropeDragView.mouseDownCanMoveWindow == true,
            "ClotheslinePhotoDragNSView disables window moving for photo drag-out while ClotheslineRopeDragNSView keeps the top rope draggable"
        )
        // Verify double-click cancels pending single-tap so selection is not mutated before restore
        var singleTapFiredCount = 0
        var doubleTapFiredCount = 0
        photoDragView.singleTapDelaySeconds = 0.05
        photoDragView.onSingleTap = { singleTapFiredCount += 1 }
        photoDragView.onDoubleTap = { doubleTapFiredCount += 1 }
        if let down1 = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
           let up1 = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0.01, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 0),
           let down2 = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0.02, windowNumber: 0, context: nil, eventNumber: 3, clickCount: 2, pressure: 1),
           let up2 = NSEvent.mouseEvent(with: .leftMouseUp, location: NSPoint(x: 20, y: 20), modifierFlags: [], timestamp: 0.03, windowNumber: 0, context: nil, eventNumber: 4, clickCount: 2, pressure: 0) {
            photoDragView.mouseDown(with: down1)
            photoDragView.mouseUp(with: up1)
            photoDragView.mouseDown(with: down2)
            photoDragView.mouseUp(with: up2)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.09))
        }
        t.check(
            singleTapFiredCount == 0 && doubleTapFiredCount == 1,
            "Double-clicking a clothesline photo fires only onDoubleTap and cancels pending onSingleTap"
        )
        // Verify fail-closed group drag when any item's PNG conversion fails
        ClotheslineManager.shared.toggleSelection(secondClipped.id)
        ClotheslineManager.shared.items[1].compositeImage = NSImage(size: .zero)
        let failedGroupDrag = ClotheslineManager.shared.writeDragExportFiles(startingFrom: firstClipped, tempDir: testTempDirURL.path)
        t.check(
            failedGroupDrag.isEmpty &&
            ClotheslineManager.shared.toastMessage == L10n.toastSaveFailedCheckPermissions,
            "Multi-photo drag fails closed and shows an error toast if any selected photo fails to export"
        )
        ClotheslineManager.shared.restoreToCanvas(secondClipped)
        ClotheslineManager.shared.restoreToCanvas(firstClipped)
    } else {
        t.check(false, "Clipped items present for Clothesline multi-drag export test")
    }
    pinFeatureVM2.hostingPanel?.onClosePanel?()

    // Verify QR Code generator + Vision barcode detector + safe URL parsing & clipboard copy
    t.check(
        PinSessionViewModel.parseSafeWebURL(from: "https://on-running.com/shoes") != nil &&
        PinSessionViewModel.parseSafeWebURL(from: "http://localhost:8080/test") != nil &&
        PinSessionViewModel.parseSafeWebURL(from: "javascript:alert(1)") == nil &&
        PinSessionViewModel.parseSafeWebURL(from: "file:///etc/passwd") == nil,
        "parseSafeWebURL accepts HTTP/HTTPS URLs and rejects unsafe schemes"
    )

    if let qrFilter = CIFilter(name: "CIQRCodeGenerator") {
        let expectedQRText = "https://github.com/howtospellpizza/ClipLine"
        qrFilter.setValue(Data(expectedQRText.utf8), forKey: "inputMessage")
        qrFilter.setValue("M", forKey: "inputCorrectionLevel")
        if let ciOut = qrFilter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
           let qrCG = CIContext().createCGImage(ciOut, from: ciOut.extent) {
            let detectedPayloads = (try? PinSessionViewModel.detectBarcodePayloads(in: qrCG)) ?? []
            t.check(
                detectedPayloads == [expectedQRText],
                "detectBarcodePayloads accurately decodes QR code payload via Vision",
                detail: "detected=\(detectedPayloads)"
            )
            var promptedURL: URL?
            var openedURL: URL?
            pinFeatureVM.qrURLOpenConfirmHandler = { url in
                promptedURL = url
                return true
            }
            pinFeatureVM.qrURLOpenAction = { url in
                openedURL = url
                return true
            }
            let qrPB = NSPasteboard.withUniqueName()
            defer { qrPB.releaseGlobally() }
            let qrCountBefore = qrPB.changeCount
            pinFeatureVM.applyBarcodePayloads(detectedPayloads, expectedChangeCount: qrCountBefore, pasteboard: qrPB)
            t.check(
                qrPB.string(forType: .string) == expectedQRText &&
                promptedURL?.absoluteString == expectedQRText &&
                openedURL?.absoluteString == expectedQRText,
                "applyBarcodePayloads copies QR payload to pasteboard and invokes confirmed URL open handler"
            )
            // Verify declining confirmation copies payload without opening URL
            openedURL = nil
            pinFeatureVM.qrURLOpenConfirmHandler = { _ in false }
            let qrCountDecline = qrPB.changeCount
            pinFeatureVM.applyBarcodePayloads(detectedPayloads, expectedChangeCount: qrCountDecline, pasteboard: qrPB)
            t.check(
                openedURL == nil &&
                pinFeatureVM.toastMessage == L10n.toastQRCopied(count: 1, openedURL: false),
                "Declining QR URL confirmation copies payload without opening browser"
            )
            pinFeatureVM.qrURLOpenConfirmHandler = nil
            pinFeatureVM.qrURLOpenAction = { NSWorkspace.shared.open($0) }
        } else {
            t.check(false, "CIQRCodeGenerator produced valid CGImage for QR scan test")
        }
    } else {
        t.check(false, "CIQRCodeGenerator available for QR scan test")
    }
    // Verify modified Cmd+Q / Option+Q does not trigger QR scan on PinHostingPanel
    if let panel = pinFeatureVM.hostingPanel,
       let cmdQEvent = NSEvent.keyEvent(
           with: .keyDown,
           location: .zero,
           modifierFlags: [.command],
           timestamp: 0,
           windowNumber: panel.windowNumber,
           context: nil,
           characters: "q",
           charactersIgnoringModifiers: "q",
           isARepeat: false,
           keyCode: 12
       ) {
        panel.keyDown(with: cmdQEvent)
        t.check(
            pinFeatureVM.isPerformingOCR == false && pinFeatureVM.activeOCRTask == nil,
            "Cmd+Q does not trigger unmodified Q QR code scan on PinHostingPanel"
        )
    } else {
        t.check(false, "PinHostingPanel present for modified-Q shortcut guard test")
    }
    pinFeatureVM.hostingPanel?.onClosePanel?()
}
