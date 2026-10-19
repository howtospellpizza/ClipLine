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
        vm.hostingPanel?.orderOut(nil)
        vm.toolbarPanel?.orderOut(nil)

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
        let ok = ClipboardHelper.copyImages(chosen.map(\.compositeImage), pasteboard: pasteboardProvider(), tempDir: tempDirOverride)
        if !silent {
            showToast(ok ? L10n.toastCopiedPhotos(chosen.count) : L10n.toastCopyFailed)
        }
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

        let width = min(max(CGFloat(items.count) * 124 + 225, 420), visible.width - 40)
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
        panel.isMovableByWindowBackground = true
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

                        HStack(spacing: 6) {
                            Button(action: { manager.toggleSelectAll() }) {
                                Text(L10n.clotheslineSelectAllLabel(allSelected: manager.items.allSatisfy(\.isSelected)))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)

                            Text("·").foregroundColor(.secondary)

                            Button(action: { manager.saveSelectedToFolder() }) {
                                Image(systemName: "arrow.down.to.line")
                                    .font(.system(size: 10.5, weight: .bold))
                                    .foregroundColor(.primary.opacity(0.85))
                            }
                            .buttonStyle(.plain)
                            .help(L10n.clotheslineSaveSelectedTooltip)

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
        VStack(spacing: -6) {
            WoodenClothespinView(isSelected: item.isSelected)
                .zIndex(3)

            ZStack(alignment: .topTrailing) {
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

                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.black.opacity(0.65))
                        .background(Circle().fill(Color.white))
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
            .rotationEffect(.degrees(item.tiltAngle), anchor: .top)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleTap)
            .onTapGesture(count: 1, perform: onSingleTap)
            .onDrag {
                if let png = ClipboardHelper.pngData(from: item.compositeImage) {
                    let tempURL = ClipboardHelper.uniqueTempFileURL(
                        prefix: "ClipLine_Drag_\(item.id.uuidString.prefix(6))",
                        tempDir: ClotheslineManager.shared.tempDirOverride
                    )
                    try? png.write(to: tempURL)
                    if let provider = NSItemProvider(contentsOf: tempURL) {
                        return provider
                    }
                }
                return NSItemProvider(object: item.compositeImage)
            }
        }
        .help(L10n.clotheslinePhotoHelp)
    }
}
