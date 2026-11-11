import AppKit
import CoreGraphics
import Foundation

@MainActor
func runSuite2MosaicAndRedactionTests(_ t: TestHarness, testPasteboard: NSPasteboard, testTempDirURL: URL) {
    let f = makeDefaultCaptureFixtures()
    let cropped = f.cropped
    let cgScreen = f.cgScreen
    let screenFrame = f.screenFrame
    let cropRect = f.cropRect
    // Suite 2: Lazy CIPixellate Mosaic Pixel Verification & Fail-Closed Redaction
    // -------------------------------------------------------------------------
    print("\n🔹 Suite 2: Lazy Mosaic Pixel Verification, Fail-Closed Redaction & Window Drag Crop Invalidation")
    let baseImg = cropped!
    let vm = PinSessionViewModel(
        image: baseImg,
        fullScreenCGImage: cgScreen,
        fullScreenFrame: screenFrame,
        captureScaleFactor: 2.0,
        cropScreenRect: cropRect
    )
    t.check(vm.pixelatedBaseImage == nil, "pixelatedBaseImage is lazy (nil on init for fast capture)")
    t.check(vm.canAdjustCrop == true, "canAdjustCrop is true immediately after capture")

    let preMosaicStripeVariation = sampleImageLuminanceVariance(baseImg, in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
    vm.activeTool = .mosaic
    t.check(vm.pixelatedBaseImage != nil, "Selecting .mosaic lazily generates pixelatedBaseImage")
    if let pixImg = vm.pixelatedBaseImage {
        let postMosaicStripeVariation = sampleImageLuminanceVariance(pixImg, in: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        t.check(
            postMosaicStripeVariation < preMosaicStripeVariation * 0.65,
            "CIPixellate mosaic visibly reduces high-frequency stripe variation",
            detail: "before=\(String(format: "%.3f", preMosaicStripeVariation)), after=\(String(format: "%.3f", postMosaicStripeVariation))"
        )
    } else {
        t.check(false, "pixelatedBaseImage available for pixel comparison")
    }

    // Verify fail-closed mosaic redaction over a high-contrast patterned base image when pixelation fails
    let failClosedVM = PinSessionViewModel(image: baseImg)
    failClosedVM.pixelatedBaseImage = nil
    failClosedVM.forceMosaicFallbackForTesting = true
    failClosedVM.annotations = [
        PinAnnotation(
            tool: .mosaic,
            color: .red,
            lineWidth: 28,
            points: [CGPoint(x: 0.1, y: 0.5), CGPoint(x: 0.9, y: 0.5)]
        )
    ]
    let failClosedOut = failClosedVM.renderCompositeImage()!
    let failClosedLumaDiff = sampleImageLuminanceVariance(failClosedOut, in: CGRect(x: 0.3, y: 0.48, width: 0.4, height: 0.04))
    var centerPixelOpaqueDark = false
    if let tiff = failClosedOut.tiffRepresentation,
       let bmp = NSBitmapImageRep(data: tiff),
       let c = bmp.colorAt(x: bmp.pixelsWide / 2, y: bmp.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) {
        let luma = 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent)
        centerPixelOpaqueDark = (c.alphaComponent > 0.98 && luma > 0.05 && luma < 0.22)
    }
    t.check(
        failClosedLumaDiff < 0.01 && centerPixelOpaqueDark,
        "Mosaic stroke fails closed (paints uniform opaque dark redaction block over patterned source) if pixelation fails",
        detail: "variance=\(failClosedLumaDiff), centerPixelOpaqueDark=\(centerPixelOpaqueDark)"
    )

    // Verify renderCompositeImage fails closed (returns nil and leaves pasteboard untouched) when baseSize is invalid
    testPasteboard.clearContents()
    testPasteboard.setString("PRESERVED_ON_RENDER_FAILURE", forType: .string)
    let invalidSizeVM = PinSessionViewModel(image: baseImg)
    invalidSizeVM.baseSize = .zero
    t.check(
        invalidSizeVM.renderCompositeImage() == nil &&
        invalidSizeVM.copyToClipboard() == false &&
        testPasteboard.string(forType: .string) == "PRESERVED_ON_RENDER_FAILURE",
        "renderCompositeImage and copyToClipboard fail closed (return nil/false and leave pasteboard untouched) on invalid context"
    )

    vm.activeTool = nil

    // Simulate dragging the floating window -> must disable 8-handle screen re-crop
    vm.hasMovedWindow = true
    t.check(vm.canAdjustCrop == false, "Moving window sets hasMovedWindow=true and disables canAdjustCrop")
    vm.hasMovedWindow = false
    t.check(vm.canAdjustCrop == true, "Resetting hasMovedWindow restores canAdjustCrop when unannotated & scale==1")

}
