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
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
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

enum StitchAxis: String, CaseIterable {
    case vertical
    case horizontal
}

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

    static func copyStitchedImage(
        _ images: [NSImage],
        axis: StitchAxis = .vertical,
        gap: CGFloat = 0,
        padding: CGFloat = 0,
        pasteboard: NSPasteboard = .general,
        tempDir: String? = nil
    ) -> Bool {
        guard !images.isEmpty else { return false }
        let dir = tempDir ?? Self.tempDir
        cleanupStaleTempFiles(in: dir)

        let stitched = stitchImagesGrid(images, axis: axis, gap: gap, padding: padding)
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

    static func stitchImagesGrid(
        _ images: [NSImage],
        axis: StitchAxis = .vertical,
        gap: CGFloat = 0,
        padding: CGFloat = 0
    ) -> NSImage {
        guard !images.isEmpty else { return NSImage() }
        if images.count == 1 && padding <= 0 {
            return images[0]
        }

        let safeGap = max(0, gap)
        let safePad = max(0, padding)
        let count = CGFloat(max(0, images.count - 1))
        let contentW: CGFloat
        let contentH: CGFloat
        switch axis {
        case .vertical:
            contentW = max(1, images.map { $0.size.width }.max() ?? 400)
            contentH = max(1, images.map { $0.size.height }.reduce(0, +) + safeGap * count)
        case .horizontal:
            contentW = max(1, images.map { $0.size.width }.reduce(0, +) + safeGap * count)
            contentH = max(1, images.map { $0.size.height }.max() ?? 300)
        }
        let totalW = contentW + safePad * 2
        let totalH = contentH + safePad * 2

        // Preserve maximum Retina backing scale factor across all input images so stitched output is never blurry
        let scaleFactor: CGFloat = images.reduce(1.0) { acc, img in
            let maxRepScale = img.representations.reduce(1.0) { repMax, rep in
                guard img.size.width > 0, rep.pixelsWide > 0 else { return repMax }
                return max(repMax, CGFloat(rep.pixelsWide) / img.size.width)
            }
            return max(acc, maxRepScale)
        }

        let targetSize = NSSize(width: totalW, height: totalH)
        let pixelW = max(1, Int((totalW * scaleFactor).rounded()))
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
            return NSImage()
        }
        rep.size = targetSize
        guard let gfxCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            return NSImage()
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gfxCtx
        gfxCtx.imageInterpolation = .high
        let ctx = gfxCtx.cgContext

        if safePad > 0 {
            let colors = [
                NSColor(calibratedRed: 0.14, green: 0.16, blue: 0.22, alpha: 1.0).cgColor,
                NSColor(calibratedRed: 0.22, green: 0.26, blue: 0.34, alpha: 1.0).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                ctx.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: totalH),
                    end: CGPoint(x: totalW, y: 0),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            } else {
                NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.24, alpha: 1.0).setFill()
                NSRect(origin: .zero, size: targetSize).fill()
            }
        }

        switch axis {
        case .vertical:
            // AppKit bitmap context has origin at bottom-left; draw from top to bottom
            var currentTopY = totalH - safePad
            for img in images {
                currentTopY -= img.size.height
                let xOffset = safePad + ((contentW - img.size.width) / 2.0).rounded()
                let destRect = NSRect(x: xOffset, y: currentTopY, width: img.size.width, height: img.size.height)
                drawImageItem(img, in: destRect, framed: safePad > 0, ctx: ctx)
                currentTopY -= safeGap
            }
        case .horizontal:
            var currentLeftX = safePad
            for img in images {
                let yOffset = safePad + ((contentH - img.size.height) / 2.0).rounded()
                let destRect = NSRect(x: currentLeftX, y: yOffset, width: img.size.width, height: img.size.height)
                drawImageItem(img, in: destRect, framed: safePad > 0, ctx: ctx)
                currentLeftX += img.size.width + safeGap
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let result = NSImage(size: targetSize)
        result.addRepresentation(rep)
        return result
    }

    private static func drawImageItem(_ img: NSImage, in destRect: NSRect, framed: Bool, ctx: CGContext) {
        if framed {
            let cornerRadius: CGFloat = min(10.0, min(destRect.width, destRect.height) * 0.12)
            let clipPath = CGPath(roundedRect: destRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 12, color: NSColor.black.withAlphaComponent(0.38).cgColor)
            ctx.addPath(clipPath)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath()
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(clipPath)
            ctx.clip()
            img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGState()

            ctx.saveGState()
            ctx.addPath(clipPath)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokePath()
            ctx.restoreGState()
        } else {
            img.draw(in: destRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    static func renderTextCardImage(_ rawText: String, scaleFactor: CGFloat = 2.0) -> NSImage? {
        guard let firstNonWS = rawText.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let lineStart = rawText[..<firstNonWS].lastIndex(where: { $0.isNewline }).map { rawText.index(after: $0) } ?? rawText.startIndex
        let leadingIndentCount = rawText.distance(from: lineStart, to: firstNonWS)
        let effectiveStart = leadingIndentCount > 120
            ? rawText.index(firstNonWS, offsetBy: -120)
            : lineStart
        let trimmedSource = rawText[effectiveStart...]

        let maxCharBudget = 8000
        let didTruncateChars = trimmedSource.count > maxCharBudget
        let boundedSource = didTruncateChars ? String(trimmedSource.prefix(maxCharBudget)) : String(trimmedSource)
        let normalized = boundedSource
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized.components(separatedBy: "\n")
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return nil }

        let didTruncateLines = lines.count > 40
        let cappedLines = Array(lines.prefix(40))
        var wasTruncated = didTruncateChars || didTruncateLines

        let font = NSFont.systemFont(ofSize: 14.0, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5.0
        paragraph.lineBreakMode = .byWordWrapping

        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.22, green: 0.19, blue: 0.14, alpha: 1.0),
            .paragraphStyle: paragraph
        ]

        let maxTextWidth: CGFloat = 520.0
        let padX: CGFloat = 22.0
        let padTop: CGFloat = 34.0
        let padBottom: CGFloat = 20.0
        let maxCardHeight: CGFloat = 900.0
        let maxTextHeight = maxCardHeight - padTop - padBottom

        func measure(_ s: String) -> NSRect {
            (s as NSString).boundingRect(
                with: NSSize(width: maxTextWidth, height: 10000.0),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: textAttrs
            )
        }

        var workingText = cappedLines.joined(separator: "\n")
        if ceil(measure(workingText + (wasTruncated ? "\n…" : "")).height) > maxTextHeight {
            wasTruncated = true
            var low = 1
            var high = workingText.count
            var best = String(workingText.prefix(1))
            while low <= high {
                let mid = (low + high) / 2
                let candidate = String(workingText.prefix(mid)).trimmingCharacters(in: .newlines)
                if ceil(measure(candidate + "\n…").height) <= maxTextHeight {
                    best = candidate
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            workingText = best
        }

        let displayText = workingText + (wasTruncated ? "\n…" : "")
        let bounding = measure(displayText)

        let cardW = max(200.0, min(maxTextWidth + padX * 2, ceil(bounding.width) + padX * 2))
        let cardH = max(92.0, min(maxCardHeight, ceil(bounding.height) + padTop + padBottom))
        let targetSize = NSSize(width: cardW, height: cardH)

        let pixelW = max(1, Int((cardW * scaleFactor).rounded()))
        let pixelH = max(1, Int((cardH * scaleFactor).rounded()))

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

        let cardRect = CGRect(origin: .zero, size: targetSize)
        let foldSize: CGFloat = 18.0
        let cornerR: CGFloat = 8.0

        // Sticky note outline with a folded bottom-right corner
        let notePath = CGMutablePath()
        notePath.move(to: CGPoint(x: 0, y: cornerR))
        notePath.addArc(tangent1End: CGPoint(x: 0, y: cardH), tangent2End: CGPoint(x: cornerR, y: cardH), radius: cornerR)
        notePath.addArc(tangent1End: CGPoint(x: cardW, y: cardH), tangent2End: CGPoint(x: cardW, y: cardH - cornerR), radius: cornerR)
        notePath.addLine(to: CGPoint(x: cardW, y: foldSize))
        notePath.addLine(to: CGPoint(x: cardW - foldSize, y: 0))
        notePath.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: 0, y: cornerR), radius: cornerR)
        notePath.closeSubpath()

        ctx.saveGState()
        ctx.addPath(notePath)
        ctx.clip()

        // Warm sticky-note paper gradient
        let bgColors = [
            NSColor(calibratedRed: 1.00, green: 0.96, blue: 0.72, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.99, green: 0.92, blue: 0.56, alpha: 1.0).cgColor
        ] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: cardH), end: CGPoint(x: 0, y: 0), options: [])
        } else {
            ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.64, alpha: 1.0).cgColor)
            ctx.fill(cardRect)
        }

        // Darker yellow adhesive header strip at the top
        let headerH: CGFloat = 20.0
        let headerRect = CGRect(x: 0, y: cardH - headerH, width: cardW, height: headerH)
        ctx.setFillColor(NSColor(calibratedRed: 0.96, green: 0.84, blue: 0.36, alpha: 0.72).cgColor)
        ctx.fill(headerRect)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.85, green: 0.70, blue: 0.22, alpha: 0.45).cgColor)
        ctx.setLineWidth(0.8)
        ctx.move(to: CGPoint(x: 0, y: cardH - headerH))
        ctx.addLine(to: CGPoint(x: cardW, y: cardH - headerH))
        ctx.strokePath()

        // Subtle ruled horizontal lines across the sticky note body
        ctx.setStrokeColor(NSColor(calibratedRed: 0.82, green: 0.70, blue: 0.28, alpha: 0.22).cgColor)
        ctx.setLineWidth(0.7)
        let lineStep: CGFloat = 22.0
        var ruleY = cardH - padTop - 16.0
        while ruleY > padBottom {
            ctx.move(to: CGPoint(x: padX - 4, y: ruleY))
            ctx.addLine(to: CGPoint(x: cardW - padX + 4, y: ruleY))
            ruleY -= lineStep
        }
        ctx.strokePath()

        // Folded corner triangle in bottom-right
        let flapPath = CGMutablePath()
        flapPath.move(to: CGPoint(x: cardW - foldSize, y: 0))
        flapPath.addLine(to: CGPoint(x: cardW - foldSize, y: foldSize))
        flapPath.addLine(to: CGPoint(x: cardW, y: foldSize))
        flapPath.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -1.5, height: 1.5), blur: 3.0, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.addPath(flapPath)
        ctx.setFillColor(NSColor(calibratedRed: 0.93, green: 0.81, blue: 0.38, alpha: 1.0).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.restoreGState()

        // Paper border stroke
        ctx.saveGState()
        ctx.addPath(notePath)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.82, green: 0.68, blue: 0.22, alpha: 0.65).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokePath()
        ctx.restoreGState()

        let textRect = NSRect(
            x: padX,
            y: padBottom,
            width: cardW - padX * 2,
            height: cardH - padTop - padBottom
        )
        (displayText as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttrs
        )

        NSGraphicsContext.restoreGraphicsState()

        let out = NSImage(size: targetSize)
        out.addRepresentation(rep)
        return out
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
