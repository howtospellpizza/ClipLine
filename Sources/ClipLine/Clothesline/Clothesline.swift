import AppKit
import Foundation
import SwiftUI

// MARK: - Skeuomorphic Clothesline Dock Manager

struct ClippedPinItem: Identifiable {
    let id: UUID
    let sessionVM: PinSessionViewModel
    var compositeImage: NSImage
    var isSelected: Bool = true
    let tiltAngle: Double
}

@MainActor
final class ClotheslineManager: ObservableObject {
    static let shared = ClotheslineManager()

    var pasteboardProvider: () -> NSPasteboard = { .general }
    var tempDirOverride: String? = nil

    @Published var items: [ClippedPinItem] = []
    @Published var toastMessage: String? = nil
    @Published var isFramedPaddingEnabled: Bool = false

    private(set) var dockPanel: NSPanel?

    var selectedItems: [ClippedPinItem] {
        items.filter(\.isSelected)
    }

    func clipToLine(vm: PinSessionViewModel) {
        vm.commitPendingText()
        guard let rendered = vm.renderCompositeImage() else {
            vm.showToast(L10n.toastRenderFailedRefusedExport)
            return
        }
        if let imgPanel = vm.hostingPanel, let tbPanel = vm.toolbarPanel, imgPanel.childWindows?.contains(tbPanel) == true {
            imgPanel.removeChildWindow(tbPanel)
        }
        vm.toolbarPanel?.orderOut(nil)
        vm.hostingPanel?.orderOut(nil)

        let angles: [Double] = [-2.2, 1.8, -1.4, 2.1, -1.8, 1.3]
        let angle = angles[items.count % angles.count]

        if let idx = items.firstIndex(where: { $0.id == vm.id }) {
            items[idx].compositeImage = rendered
            items[idx].isSelected = true
        } else {
            items.append(
                ClippedPinItem(
                    id: vm.id,
                    sessionVM: vm,
                    compositeImage: rendered,
                    isSelected: true,
                    tiltAngle: angle
                )
            )
        }

        syncSelectedToClipboard(silent: true)
        updateDockVisibility()
        showToast(L10n.toastClippedToLine(selectedCount: selectedItems.count))
    }

    func restoreToCanvas(_ item: ClippedPinItem) {
        items.removeAll { $0.id == item.id }
        updateDockVisibility()
        if let panel = item.sessionVM.hostingPanel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            item.sessionVM.updateToolbarPanelPosition()
        }
    }

    func itemsForDrag(startingFrom draggedItem: ClippedPinItem) -> [ClippedPinItem] {
        let currentItem = items.first(where: { $0.id == draggedItem.id }) ?? draggedItem
        if currentItem.isSelected {
            let chosen = selectedItems
            if !chosen.isEmpty {
                return chosen
            }
        }
        return [currentItem]
    }

    func writeDragExportFiles(startingFrom draggedItem: ClippedPinItem, tempDir: String? = nil) -> [(item: ClippedPinItem, url: URL)] {
        let dir = tempDir ?? tempDirOverride ?? ClipboardHelper.tempDir
        ClipboardHelper.cleanupStaleTempFiles(in: dir)
        let targetItems = itemsForDrag(startingFrom: draggedItem)
        var results: [(item: ClippedPinItem, url: URL)] = []
        for entry in targetItems {
            guard let png = ClipboardHelper.pngData(from: entry.compositeImage) else { continue }
            let tempURL = ClipboardHelper.uniqueTempFileURL(
                prefix: "ClipLine_Drag_\(entry.id.uuidString.prefix(6))",
                tempDir: dir
            )
            if (try? png.write(to: tempURL, options: .atomic)) != nil {
                results.append((item: entry, url: tempURL))
            }
        }
        if results.count != targetItems.count {
            for entry in results {
                try? FileManager.default.removeItem(at: entry.url)
            }
            showToast(L10n.toastSaveFailedCheckPermissions)
            return []
        }
        return results
    }

    func toggleSelection(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].isSelected.toggle()
        if !selectedItems.isEmpty {
            syncSelectedToClipboard(silent: true)
        }
    }

    func toggleSelectAll() {
        let allSelected = items.allSatisfy(\.isSelected)
        let newState = !allSelected
        for i in items.indices {
            items[i].isSelected = newState
        }
        if newState {
            syncSelectedToClipboard(silent: false)
        } else {
            showToast(L10n.toastDeselectedAll)
        }
    }

    func syncSelectedToClipboard(silent: Bool = false) {
        let chosen = selectedItems
        guard !chosen.isEmpty else {
            if !silent {
                showToast(L10n.toastSelectPhotosToCopy)
            }
            return
        }
        let imagesToCopy: [NSImage]
        if isFramedPaddingEnabled {
            imagesToCopy = chosen.map { ClipboardHelper.stitchImagesGrid([$0.compositeImage], padding: 20) }
        } else {
            imagesToCopy = chosen.map(\.compositeImage)
        }
        let ok = ClipboardHelper.copyImages(imagesToCopy, pasteboard: pasteboardProvider(), tempDir: tempDirOverride)
        if !silent {
            showToast(ok ? L10n.toastCopiedPhotos(chosen.count) : L10n.toastCopyFailed)
        }
    }

    func stitchSelectedToClipboard(axis: StitchAxis = .vertical) {
        let chosen = selectedItems
        guard !chosen.isEmpty else {
            showToast(L10n.toastSelectPhotosToCopy)
            return
        }
        let gap: CGFloat = isFramedPaddingEnabled ? 16 : 0
        let padding: CGFloat = isFramedPaddingEnabled ? 20 : 0
        let ok = ClipboardHelper.copyStitchedImage(
            chosen.map(\.compositeImage),
            axis: axis,
            gap: gap,
            padding: padding,
            pasteboard: pasteboardProvider(),
            tempDir: tempDirOverride
        )
        showToast(ok ? L10n.toastStitchedPhotos(chosen.count) : L10n.toastCopyFailed)
    }

    func saveSelectedToFolder() {
        let chosen = selectedItems
        guard !chosen.isEmpty else {
            showToast(L10n.toastSelectPhotosToSave)
            return
        }

        if chosen.count == 1, let single = chosen.first {
            single.sessionVM.saveToFile()
            return
        }

        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.canCreateDirectories = true
        openPanel.prompt = L10n.clotheslineSaveFolderPrompt(chosen.count)
        openPanel.level = .screenSaver

        if openPanel.runModal() == .OK, let dirURL = openPanel.url {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HH.mm.ss.SSS"
            let stamp = formatter.string(from: Date())
            var savedCount = 0
            for (i, item) in chosen.enumerated() {
                if let png = ClipboardHelper.pngData(from: item.compositeImage) {
                    let fileURL = dirURL.appendingPathComponent("ClipLine_\(stamp)_\(i + 1).png")
                    if (try? png.write(to: fileURL, options: .atomic)) != nil {
                        savedCount += 1
                    }
                }
            }
            if savedCount == chosen.count {
                showToast(L10n.toastSavedMultipleImages(savedCount))
            } else if savedCount > 0 {
                showToast(L10n.toastSavedPartialImages(saved: savedCount, total: chosen.count))
            } else {
                showToast(L10n.toastSaveFailedCheckPermissions)
            }
        }
    }

    func removeItem(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            item.sessionVM.hostingPanel?.onClosePanel?()
        }
        items.removeAll { $0.id == id }
        updateDockVisibility()
    }

    func clearAll() {
        for item in items {
            item.sessionVM.hostingPanel?.onClosePanel?()
        }
        items.removeAll()
        updateDockVisibility()
    }

    func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self.toastMessage == msg {
                self.toastMessage = nil
            }
        }
    }

    func updateDockVisibility() {
        if items.isEmpty {
            dockPanel?.orderOut(nil)
            return
        }

        if dockPanel == nil {
            createDockPanel()
        }

        guard let panel = dockPanel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let width = min(max(CGFloat(items.count) * 124 + 335, 510), visible.width - 40)
        let height: CGFloat = 148
        let origin = CGPoint(
            x: visible.midX - width / 2,
            y: visible.maxY - height + 4
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    private func createDockPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 148),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        // Do NOT set isMovableByWindowBackground = true here, because AppKit window-background dragging
        // intercepts left mouse drags on clipped photos before NSView/SwiftUI drag-and-drop can start.
        // Instead, dragging the top rope header moves the clothesline panel.
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let rootView = ClotheslineBarView(manager: self)
        panel.contentView = NSHostingView(rootView: rootView)
        self.dockPanel = panel
    }
}

// MARK: - Skeuomorphic Clothesline & Wooden Peg UI

struct WoodenClothespinView: View {
    var isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isSelected
                            ? [Color(red: 0.88, green: 0.68, blue: 0.42), Color(red: 0.72, green: 0.50, blue: 0.26)]
                            : [Color(red: 0.55, green: 0.52, blue: 0.48), Color(red: 0.40, green: 0.38, blue: 0.35)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 9, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 2.5)
                        .stroke(Color.black.opacity(0.35), lineWidth: 0.6)
                )

            RoundedRectangle(cornerRadius: 1)
                .fill(Color(white: 0.82))
                .frame(width: 11, height: 4)
                .offset(y: 1)
                .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
        }
        .shadow(color: .black.opacity(0.35), radius: 2, x: 1, y: 2)
    }
}

struct ClotheslineRopeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let start = CGPoint(x: 8, y: 12)
        let end = CGPoint(x: rect.width - 8, y: 12)
        let control = CGPoint(x: rect.width / 2, y: 21)
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }
}

struct ClotheslineBarView: View {
    @ObservedObject var manager: ClotheslineManager

    var body: some View {
        ZStack(alignment: .top) {
            ZStack(alignment: .top) {
                ClotheslineRopeShape()
                    .stroke(Color.black.opacity(0.35), style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .offset(y: 2)

                ClotheslineRopeShape()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.76, green: 0.62, blue: 0.44),
                                Color(red: 0.62, green: 0.48, blue: 0.32),
                                Color(red: 0.76, green: 0.62, blue: 0.44)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 3.0, lineCap: .round, dash: [6, 1.5])
                    )

                HStack {
                    Circle()
                        .fill(RadialGradient(colors: [.white, .gray, .black], center: .topLeading, startRadius: 1, endRadius: 6))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                    Spacer()
                    Circle()
                        .fill(RadialGradient(colors: [.white, .gray, .black], center: .topLeading, startRadius: 1, endRadius: 6))
                        .frame(width: 9, height: 9)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                }
                .padding(.horizontal, 4)
                .offset(y: 8)
            }
            .frame(height: 28)
            .background(ClotheslineWindowDragHandleView())

            HStack(alignment: .top, spacing: 14) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(manager.items) { item in
                            HangingPhotoView(
                                item: item,
                                onSingleTap: { manager.toggleSelection(item.id) },
                                onDoubleTap: { manager.restoreToCanvas(item) },
                                onDelete: { manager.removeItem(item.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }

                VStack(spacing: 5) {
                    WoodenClothespinView(isSelected: true)
                        .offset(y: 2)
                        .zIndex(2)

                    VStack(spacing: 5) {
                        HStack(spacing: 5) {
                            Button(action: { manager.syncSelectedToClipboard(silent: false) }) {
                                HStack(spacing: 3) {
                                    Image(systemName: "doc.on.doc.fill")
                                        .font(.system(size: 10, weight: .bold))
                                    Text(L10n.clotheslineCopyCountLabel(manager.selectedItems.count))
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(manager.selectedItems.isEmpty ? Color.gray.opacity(0.4) : Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.selectedItems.isEmpty)
                            .help(L10n.clotheslineCopyTooltip)
                            .fixedSize()

                            if manager.selectedItems.count > 1 {
                                Button(action: { manager.stitchSelectedToClipboard(axis: .vertical) }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "rectangle.split.1x2.fill")
                                            .font(.system(size: 10.5, weight: .bold))
                                        Text(L10n.clotheslineStitchLabel)
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(red: 0.78, green: 0.54, blue: 0.28))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.clotheslineStitchTooltip)
                                .fixedSize()

                                Button(action: { manager.stitchSelectedToClipboard(axis: .horizontal) }) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "rectangle.split.2x1.fill")
                                            .font(.system(size: 10.5, weight: .bold))
                                        Text(L10n.clotheslineStitchHorizontalLabel)
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(red: 0.72, green: 0.46, blue: 0.22))
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help(L10n.clotheslineStitchHorizontalTooltip)
                                .fixedSize()
                            }
                        }

                        HStack(spacing: 6) {
                            Button(action: {
                                manager.isFramedPaddingEnabled.toggle()
                                manager.showToast(L10n.toastFramePaddingToggled(enabled: manager.isFramedPaddingEnabled))
                            }) {
                                HStack(spacing: 3) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .stroke(manager.isFramedPaddingEnabled ? Color.white : Color.primary.opacity(0.8), lineWidth: 1.1)
                                            .frame(width: 11, height: 9)
                                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                                            .fill(manager.isFramedPaddingEnabled ? Color.white : Color.primary.opacity(0.75))
                                            .frame(width: 6, height: 4.5)
                                    }
                                    Text(L10n.clotheslineFramePaddingLabel)
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(manager.isFramedPaddingEnabled ? Color.accentColor : Color.primary.opacity(0.12))
                                .foregroundColor(manager.isFramedPaddingEnabled ? .white : .primary.opacity(0.88))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(L10n.clotheslineFramePaddingTooltip)
                            .fixedSize()

                            Text("·").foregroundColor(.secondary)

                            Button(action: { manager.toggleSelectAll() }) {
                                Text(L10n.clotheslineSelectAllLabel(allSelected: manager.items.allSatisfy(\.isSelected)))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .fixedSize()

                            Text("·").foregroundColor(.secondary)

                            Button(action: { manager.saveSelectedToFolder() }) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.clotheslineSaveSelectedTooltip)

                            Text("·").foregroundColor(.secondary)

                            Button(action: {
                                for channel in NotificationChannels.settingsChannels {
                                    DistributedNotificationCenter.default().postNotificationName(
                                        NSNotification.Name(channel),
                                        object: nil,
                                        deliverImmediately: true
                                    )
                                }
                            }) {
                                Image(systemName: "keyboard")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.shortcutMenuSettings)

                            Text("·").foregroundColor(.secondary)

                            Button(action: { manager.clearAll() }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.red.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.clotheslineClearAllTooltip)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                }
                .padding(.trailing, 14)
            }

            if let toast = manager.toastMessage {
                Text(toast)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.78))
                    .clipShape(Capsule())
                    .offset(y: 114)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct HangingPhotoView: View {
    let item: ClippedPinItem
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: -6) {
                WoodenClothespinView(isSelected: item.isSelected)
                    .zIndex(3)

                Image(nsImage: item.compositeImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 90, height: 64)
                    .clipped()
                    .padding(4)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(
                                item.isSelected ? Color.accentColor : Color.black.opacity(0.2),
                                lineWidth: item.isSelected ? 2.2 : 0.8
                            )
                    )
                    .opacity(item.isSelected ? 1.0 : 0.55)
                    .scaleEffect(item.isSelected ? 1.0 : 0.94)
                    .shadow(color: .black.opacity(0.38), radius: 5, x: 0, y: 4)
                    .rotationEffect(.degrees(item.tiltAngle), anchor: .top)
            }
            .overlay(
                ClotheslinePhotoInteractionOverlay(
                    item: item,
                    onSingleTap: onSingleTap,
                    onDoubleTap: onDoubleTap
                )
            )

            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.black.opacity(0.65))
                    .background(Circle().fill(Color.white))
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: 12)
        }
        .help(L10n.clotheslinePhotoHelp)
    }
}

struct ClotheslineWindowDragHandleView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ClotheslineRopeDragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class ClotheslineRopeDragNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct ClotheslinePhotoInteractionOverlay: NSViewRepresentable {
    let item: ClippedPinItem
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void

    func makeNSView(context: Context) -> ClotheslinePhotoDragNSView {
        let view = ClotheslinePhotoDragNSView()
        view.item = item
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
        return view
    }

    func updateNSView(_ nsView: ClotheslinePhotoDragNSView, context: Context) {
        nsView.item = item
        nsView.onSingleTap = onSingleTap
        nsView.onDoubleTap = onDoubleTap
    }
}

final class ClotheslinePhotoDragNSView: NSView, NSDraggingSource {
    var item: ClippedPinItem?
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var singleTapDelaySeconds: TimeInterval = min(NSEvent.doubleClickInterval, 0.22)

    private var mouseDownPoint: NSPoint = .zero
    private var didStartDrag: Bool = false
    private var pendingSingleTapWorkItem: DispatchWorkItem?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func cancelPendingSingleTap() {
        pendingSingleTapWorkItem?.cancel()
        pendingSingleTapWorkItem = nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        didStartDrag = false
        if event.clickCount >= 2 {
            cancelPendingSingleTap()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !didStartDrag, let item = item else { return }
        let pt = convert(event.locationInWindow, from: nil)
        guard hypot(pt.x - mouseDownPoint.x, pt.y - mouseDownPoint.y) >= 3.0 else { return }
        didStartDrag = true
        cancelPendingSingleTap()

        let exported = ClotheslineManager.shared.writeDragExportFiles(startingFrom: item)
        guard !exported.isEmpty else { return }

        let baseFrame = bounds.isEmpty ? NSRect(x: 0, y: 0, width: 90, height: 64) : bounds
        let draggingItems: [NSDraggingItem] = exported.enumerated().map { idx, entry in
            let draggingItem = NSDraggingItem(pasteboardWriter: entry.url as NSURL)
            let stackOffset = CGFloat(min(idx, 4)) * 5.0
            let previewFrame = baseFrame.offsetBy(dx: stackOffset, dy: -stackOffset)
            draggingItem.setDraggingFrame(previewFrame, contents: entry.item.compositeImage)
            return draggingItem
        }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.draggingFormation = .pile
    }

    override func mouseUp(with event: NSEvent) {
        guard !didStartDrag else {
            didStartDrag = false
            return
        }
        if event.clickCount >= 2 {
            cancelPendingSingleTap()
            onDoubleTap?()
        } else if event.clickCount == 1 {
            cancelPendingSingleTap()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingSingleTapWorkItem = nil
                self.onSingleTap?()
            }
            pendingSingleTapWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + singleTapDelaySeconds, execute: work)
        }
    }
}
