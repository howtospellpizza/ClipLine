import AppKit
import Carbon
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - Lightweight Assertion Harness

@MainActor
final class TestHarness {
    var passed = 0
    var failed = 0

    func check(_ condition: @autoclosure () -> Bool, _ name: String, detail: String = "") {
        if condition() {
            passed += 1
            print("  ✅ PASS: \(name)")
        } else {
            failed += 1
            print("  ❌ FAIL: \(name) \(detail.isEmpty ? "" : "(\(detail))")")
        }
    }

    func summary() -> Int32 {
        print("\n========================================")
        print("📊 Test Summary: \(passed) passed, \(failed) failed")
        print("========================================")
        return failed == 0 ? 0 : 1
    }
}

@MainActor
final class ShortcutRecorderNavigationWindow: NSWindow {
    private(set) var selectedNextKeyView = false
    private(set) var selectedPreviousKeyView = false

    override func selectNextKeyView(_ sender: Any?) {
        selectedNextKeyView = true
        super.selectNextKeyView(sender)
    }

    override func selectPreviousKeyView(_ sender: Any?) {
        selectedPreviousKeyView = true
        super.selectPreviousKeyView(sender)
    }
}

// MARK: - Synthetic Test Image Builders & Shared Fixtures

struct DefaultCaptureTestFixtures {
    let screenFrame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let cgScreen = makeSyntheticScreenCGImage(width: 800, height: 600)
    let cropRect = NSRect(x: 100, y: 80, width: 160, height: 120)
    let cropped: NSImage?
    let baseImg: NSImage
    let panelFrame: NSRect

    @MainActor
    func makeViewModel() -> PinSessionViewModel {
        PinSessionViewModel(
            image: baseImg,
            fullScreenCGImage: cgScreen,
            fullScreenFrame: screenFrame,
            captureScaleFactor: 2.0,
            cropScreenRect: cropRect
        )
    }
}

@MainActor
func makeDefaultCaptureFixtures() -> DefaultCaptureTestFixtures {
    let screenFrame = NSRect(x: 0, y: 0, width: 400, height: 300)
    let cgScreen = makeSyntheticScreenCGImage(width: 800, height: 600)
    let cropRect = NSRect(x: 100, y: 80, width: 160, height: 120)
    let cropped = PixPinSelectionView.cropImage(
        cgImage: cgScreen,
        viewHeight: screenFrame.height,
        scaleFactor: 2.0,
        rect: cropRect
    )
    let panelFrame = PinSessionViewModel.panelFrameForImageScreenRect(cropRect)
    return DefaultCaptureTestFixtures(
        cropped: cropped,
        baseImg: cropped!,
        panelFrame: panelFrame
    )
}

func makeSyntheticScreenCGImage(width: Int = 800, height: Int = 600) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    // Top-left quadrant red, top-right green, bottom-left blue, bottom-right yellow
    ctx.setFillColor(NSColor.systemRed.cgColor)
    ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
    ctx.setFillColor(NSColor.systemGreen.cgColor)
    ctx.fill(CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2))
    ctx.setFillColor(NSColor.systemBlue.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
    ctx.setFillColor(NSColor.systemYellow.cgColor)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2))

    // Draw high-contrast horizontal stripes in center so mosaic pixelation changes pixel values
    for y in stride(from: 100, to: 500, by: 4) {
        ctx.setFillColor((y % 8 == 0) ? NSColor.black.cgColor : NSColor.white.cgColor)
        ctx.fill(CGRect(x: 100, y: y, width: 600, height: 2))
    }

    return ctx.makeImage()!
}

func makeTextImage(text: String, size: NSSize = NSSize(width: 320, height: 90)) -> NSImage {
    let img = NSImage(size: size)
    img.lockFocus()
    NSColor.white.setFill()
    NSBezierPath.fill(NSRect(origin: .zero, size: size))
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 32, weight: .bold),
        .foregroundColor: NSColor.black
    ]
    (text as NSString).draw(at: NSPoint(x: 24, y: 26), withAttributes: attrs)
    img.unlockFocus()
    return img
}

func sampleImageLuminanceVariance(_ image: NSImage, in normalizedRect: CGRect) -> Double {
    guard let tiff = image.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff) else { return 0 }
    let w = bmp.pixelsWide
    let h = bmp.pixelsHigh
    let minX = max(0, Int( CGFloat(w) * normalizedRect.minX ))
    let maxX = min(w - 1, Int( CGFloat(w) * normalizedRect.maxX ))
    let minY = max(0, Int( CGFloat(h) * normalizedRect.minY ))
    let maxY = min(h - 1, Int( CGFloat(h) * normalizedRect.maxY ))
    guard maxX >= minX, maxY >= minY else { return 0 }

    var diffs = 0.0
    var count = 0.0
    for x in stride(from: minX, through: maxX, by: 4) {
        var prevLuma: Double? = nil
        for y in minY...maxY {
            if let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                let luma = 0.299 * Double(c.redComponent) + 0.587 * Double(c.greenComponent) + 0.114 * Double(c.blueComponent)
                if let p = prevLuma {
                    diffs += abs(luma - p)
                    count += 1
                }
                prevLuma = luma
            }
        }
    }
    return count > 0 ? (diffs / count) : 0
}

// MARK: - Modular Suite Runner & Filter

struct RegisteredTestSuite {
    let id: String
    let title: String
    let run: @MainActor (TestHarness, NSPasteboard, URL) -> Void
}

@MainActor
func parseTestSuiteFilter(arguments: [String] = CommandLine.arguments) -> String? {
    for (idx, arg) in arguments.enumerated() {
        if arg == "--filter", idx + 1 < arguments.count {
            let val = arguments[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { return val }
        } else if arg.hasPrefix("--filter=") {
            let val = String(arg.dropFirst("--filter=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !val.isEmpty { return val }
        }
    }
    if let envFilter = ProcessInfo.processInfo.environment["CLIPLINE_TEST_FILTER"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !envFilter.isEmpty {
        return envFilter
    }
    return nil
}

@MainActor
func runAllTests(filter explicitFilter: String? = nil) -> Int32 {
    let t = TestHarness()
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)

    let testPasteboard = NSPasteboard.withUniqueName()
    let testTempDirURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipLineTests_\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: testTempDirURL, withIntermediateDirectories: true)

    ClotheslineManager.shared.pasteboardProvider = { testPasteboard }
    ClotheslineManager.shared.tempDirOverride = testTempDirURL.path

    defer {
        ClotheslineManager.shared.pasteboardProvider = { .general }
        ClotheslineManager.shared.tempDirOverride = nil
        testPasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: testTempDirURL)
    }

    let suites: [RegisteredTestSuite] = [
        RegisteredTestSuite(
            id: "suite1-capture-crop",
            title: "Suite 1: Geometry & Crop Math",
            run: runSuite1CaptureAndCropTests
        ),
        RegisteredTestSuite(
            id: "suite2-mosaic-redaction",
            title: "Suite 2: Lazy Mosaic Pixel Verification, Fail-Closed Redaction & Window Drag Crop Invalidation",
            run: runSuite2MosaicAndRedactionTests
        ),
        RegisteredTestSuite(
            id: "suite3-translate-ocr-lock",
            title: "Suite 3: URL Encoding, OCR Pasteboard Guard & Single-Instance Lock",
            run: runSuite3TranslateOCRAndLockTests
        ),
        RegisteredTestSuite(
            id: "suite4-pin-toolbar-canvas",
            title: "Suite 4: Native AppKit + SwiftUI Dual-Panel GUI Regression",
            run: runSuite4PinToolbarAndCanvasTests
        ),
        RegisteredTestSuite(
            id: "suite5-clothesline-stitch-text",
            title: "Suite 5: Multi-Image Pasteboard Copy & Scoped Temp File Hygiene",
            run: runSuite5ClotheslineStitchAndTextTests
        ),
        RegisteredTestSuite(
            id: "suite6-shortcuts-settings",
            title: "Suite 6: Editable Global Shortcuts & Transactional Registration",
            run: runSuite6ShortcutSettingsTests
        ),
        RegisteredTestSuite(
            id: "suite7-localization-qr-drag",
            title: "Suite 7: Localization (EN & Simplified Chinese)",
            run: runSuite7LocalizationQRAndDragTests
        ),
        RegisteredTestSuite(
            id: "suite8-updater",
            title: "Suite 8: Explicit Updater (Offline, Isolated Fixtures)",
            run: { harness, _, _ in runClipLineUpdaterTests(harness) }
        ),
        RegisteredTestSuite(
            id: "suite9-version-diagnostics",
            title: "Suite 9: Version Metadata & Local Diagnostics",
            run: runSuite9VersionAndDiagnosticsTests
        )
    ]

    let activeFilter = explicitFilter ?? parseTestSuiteFilter()
    let matchedSuites: [RegisteredTestSuite]
    if let q = activeFilter?.lowercased() {
        matchedSuites = suites.filter {
            $0.id.lowercased().contains(q) || $0.title.lowercased().contains(q)
        }
        guard !matchedSuites.isEmpty else {
            fputs("❌ No test suites matched filter '\(activeFilter!)'. Available suites:\n", stderr)
            for s in suites {
                fputs("  - \(s.id): \(s.title)\n", stderr)
            }
            return 1
        }
        print("🚀 Running ClipLine Test Suites matching '\(activeFilter!)' (\(matchedSuites.count)/\(suites.count))...\n")
    } else {
        matchedSuites = suites
        print("🚀 Running ClipLine In-Process Unit & AppKit Regression Suite (Isolated Pasteboard & TempDir)...\n")
    }

    for suite in matchedSuites {
        suite.run(t, testPasteboard, testTempDirURL)
    }

    return t.summary()
}
