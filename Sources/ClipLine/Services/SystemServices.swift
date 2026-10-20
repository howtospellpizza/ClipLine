import AppKit
import CoreImage
import Darwin
import Foundation

// MARK: - Single-Instance Lock Helper

enum SingleInstanceLock {
    private static var lockFD: Int32 = -1

    static var lockFilePath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = appSupport.appendingPathComponent("ClipLine", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("clipline_daemon.lock").path
    }

    static func acquireOrNotifyExisting(path: String = lockFilePath, notifyExisting: Bool = true) -> Bool {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            fputs("[ClipLine] Error: Unable to open lock file at \(path) (errno \(errno))\n", stderr)
            return false
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFD = fd
            let pidStr = "\(getpid())\n"
            _ = ftruncate(fd, 0)
            _ = pidStr.withCString { write(fd, $0, strlen($0)) }
            return true
        }
        close(fd)
        if notifyExisting {
            for channel in NotificationChannels.captureChannels {
                DistributedNotificationCenter.default().postNotificationName(
                    NSNotification.Name(channel),
                    object: nil,
                    userInfo: ["mode": "interactive"],
                    deliverImmediately: true
                )
            }
        }
        return false
    }

    static func releaseLockIfHeld() {
        guard lockFD >= 0 else { return }
        _ = flock(lockFD, LOCK_UN)
        close(lockFD)
        lockFD = -1
    }
}

enum NotificationChannels {
    static let settingsChannels = ["io.github.clipline.settings"]

    static func settingsAcknowledgementChannel(for requestID: String) -> String {
        "io.github.clipline.settings.ack.\(requestID)"
    }

    static var translateChannels: [String] {
        var list = ["io.github.clipline.translate"]
        if let extra = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_CHANNEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty, !list.contains(extra) {
            list.append(extra)
        }
        return list
    }

    static var captureChannels: [String] {
        var list = ["io.github.clipline.capture"]
        if let extra = ProcessInfo.processInfo.environment["CLIP_LINE_CAPTURE_CHANNEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !extra.isEmpty, !list.contains(extra) {
            list.append(extra)
        }
        return list
    }
}

enum SettingsRequestRetry {
    static func send(
        maxAttempts: Int,
        post: () -> Void,
        waitForAcknowledgement: () -> Bool
    ) -> Bool {
        guard maxAttempts > 0 else { return false }
        for _ in 0..<maxAttempts {
            post()
            if waitForAcknowledgement() { return true }
        }
        return false
    }
}

// MARK: - Clipboard Helper (Multi-format PNG + TIFF + FileURL)

enum ClipboardHelper {
    static var tempDir: String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipLine", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url.path
    }

    static func cleanupStaleTempFiles(olderThan ageSeconds: TimeInterval = 3600, in directoryPath: String = tempDir) {
        let dirURL = URL(fileURLWithPath: directoryPath, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-ageSeconds)
        for url in urls {
            let name = url.lastPathComponent
            guard (name.hasPrefix("ClipLine_") || name.hasPrefix("clipline_snap_")) && name.hasSuffix(".png") else {
                continue
            }
            if let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = vals.contentModificationDate,
               modDate < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    static func uniqueTempFileURL(prefix: String = "ClipLine", tempDir: String? = nil) -> URL {
        let dir = tempDir ?? Self.tempDir
        let ms = Int64((Date().timeIntervalSince1970 * 1000.0).rounded())
        let token = UUID().uuidString.prefix(8)
        return URL(fileURLWithPath: "\(dir)/\(prefix)_\(ms)_\(token).png")
    }

    static func copyImages(_ images: [NSImage], pasteboard: NSPasteboard = .general, tempDir: String? = nil) -> Bool {
        guard !images.isEmpty else { return false }
        let dir = tempDir ?? Self.tempDir
        cleanupStaleTempFiles(in: dir)

        var items: [NSPasteboardItem] = []
        items.reserveCapacity(images.count)

        for (index, image) in images.enumerated() {
            guard let png = pngData(from: image) else {
                return false
            }
            let prefix = images.count == 1 ? "ClipLine" : "ClipLine_\(index + 1)"
            let fileURL = uniqueTempFileURL(prefix: prefix, tempDir: dir)
            let wroteFile = (try? png.write(to: fileURL, options: .atomic)) != nil

            let item = NSPasteboardItem()
            item.setData(png, forType: .png)
            if let tiff = image.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            if wroteFile {
                item.setString(fileURL.absoluteString, forType: .fileURL)
            }
            items.append(item)
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }

    static func copyStitchedImage(_ images: [NSImage], pasteboard: NSPasteboard = .general, tempDir: String? = nil) -> Bool {
        guard !images.isEmpty else { return false }
        let dir = tempDir ?? Self.tempDir
        cleanupStaleTempFiles(in: dir)

        let stitched = stitchImagesGrid(images, gap: 0)
        guard let png = pngData(from: stitched) else {
            return false
        }
        let fileURL = uniqueTempFileURL(prefix: "ClipLine_Stitched", tempDir: dir)
        let wroteFile = (try? png.write(to: fileURL, options: .atomic)) != nil

        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = stitched.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
        if wroteFile {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    static func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    static func stitchImagesGrid(_ images: [NSImage], gap: CGFloat = 0) -> NSImage {
        guard images.count > 1 else { return images.first ?? NSImage() }
        let maxW = max(1, images.map { $0.size.width }.max() ?? 400)
        let totalH = max(1, images.map { $0.size.height }.reduce(0, +) + gap * CGFloat(images.count - 1))

        // Preserve maximum Retina backing scale factor across all input images so stitched output is never blurry
        let scaleFactor: CGFloat = images.reduce(1.0) { acc, img in
            let maxRepScale = img.representations.reduce(1.0) { repMax, rep in
                guard img.size.width > 0, rep.pixelsWide > 0 else { return repMax }
                return max(repMax, CGFloat(rep.pixelsWide) / img.size.width)
            }
            return max(acc, maxRepScale)
        }

        let targetSize = NSSize(width: maxW, height: totalH)
        let pixelW = max(1, Int((maxW * scaleFactor).rounded()))
        let pixelH = max(1, Int((totalH * scaleFactor).rounded()))

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
            return images.first ?? NSImage()
        }
        rep.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        if let gfxCtx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.current = gfxCtx
            gfxCtx.imageInterpolation = .high
            // AppKit bitmap context has origin at bottom-left; draw from top to bottom seamlessly
            var currentTopY = totalH
            for img in images {
                currentTopY -= img.size.height
                let xOffset = ((maxW - img.size.width) / 2.0).rounded()
                let destRect = NSRect(x: xOffset, y: currentTopY, width: img.size.width, height: img.size.height)
                img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
                currentTopY -= gap
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: targetSize)
        result.addRepresentation(rep)
        return result
    }
}

// MARK: - Real Pixelation / Mosaic Helper (CoreImage CIPixellate)

enum MosaicRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func createPixelatedImage(from image: NSImage, blockScale: CGFloat = 12.0) -> NSImage? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let cgIn = bitmap.cgImage else { return nil }

        let ciInput = CIImage(cgImage: cgIn)
        let extent = ciInput.extent
        let pixelScale = max(8.0, blockScale * (CGFloat(cgIn.width) / max(1.0, image.size.width)))

        guard let filter = CIFilter(name: "CIPixellate") else { return nil }
        filter.setValue(ciInput.clampedToExtent(), forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: extent.midX, y: extent.midY), forKey: kCIInputCenterKey)
        filter.setValue(pixelScale, forKey: kCIInputScaleKey)

        guard let output = filter.outputImage?.cropped(to: extent),
              let cgOut = ciContext.createCGImage(output, from: extent) else { return nil }

        return NSImage(cgImage: cgOut, size: image.size)
    }
}

// MARK: - Directional Resize Cursors (incl. Diagonal NE-SW and NW-SE)

enum DirectionalCursor {
    static let northSouth: NSCursor = makeResizeCursor(angleDegrees: 90)
    static let eastWest: NSCursor = makeResizeCursor(angleDegrees: 0)
    static let northWestSouthEast: NSCursor = makeResizeCursor(angleDegrees: -45)
    static let northEastSouthWest: NSCursor = makeResizeCursor(angleDegrees: 45)

    private static func makeResizeCursor(angleDegrees: CGFloat) -> NSCursor {
        let size = NSSize(width: 22, height: 22)
        let img = NSImage(size: size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: angleDegrees * .pi / 180.0)

            let path = CGMutablePath()
            let L: CGFloat = 8.5   // half-length to tip
            let H: CGFloat = 4.2   // arrowhead wing width
            let B: CGFloat = 4.0   // arrowhead base X
            let S: CGFloat = 1.35  // shaft half-thickness

            path.move(to: CGPoint(x: -L, y: 0))
            path.addLine(to: CGPoint(x: -B, y: H))
            path.addLine(to: CGPoint(x: -B, y: S))
            path.addLine(to: CGPoint(x: B, y: S))
            path.addLine(to: CGPoint(x: B, y: H))
            path.addLine(to: CGPoint(x: L, y: 0))
            path.addLine(to: CGPoint(x: B, y: -H))
            path.addLine(to: CGPoint(x: B, y: -S))
            path.addLine(to: CGPoint(x: -B, y: -S))
            path.addLine(to: CGPoint(x: -B, y: -H))
            path.closeSubpath()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.4)
            ctx.setLineJoin(.round)
            ctx.strokePath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()
        }
        img.unlockFocus()
        return NSCursor(image: img, hotSpot: NSPoint(x: 11, y: 11))
    }
}
