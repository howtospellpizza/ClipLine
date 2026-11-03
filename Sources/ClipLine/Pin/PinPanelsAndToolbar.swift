import AppKit
import SwiftUI

// MARK: - Detached Floating Toolbar View (SwiftUI inside its own auto-sizing NSPanel)

struct PinToolbarView: View {
    @ObservedObject var vm: PinSessionViewModel
    var onOpenSettings: (() -> Void)? = nil
    var onClose: () -> Void

    private let palette: [Color] = [.red, .orange, .yellow, .green, .blue, .white]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PinAnnotation.Tool.allCases) { tool in
                Button(action: {
                    vm.commitPendingText()
                    vm.activeTool = (vm.activeTool == tool) ? nil : tool
                    vm.hostingPanel?.canvasView?.needsDisplay = true
                }) {
                    Image(systemName: tool.icon)
                        .font(.system(size: 12.5, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .background(vm.activeTool == tool ? Color.accentColor : Color.clear)
                        .foregroundColor(vm.activeTool == tool ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.localizedName)
            }

            let selectedTool: PinAnnotation.Tool? = vm.annotations.first(where: { $0.id == vm.selectedTextAnnotationID })?.tool
            let activeOrSelectedTool: PinAnnotation.Tool? = selectedTool ?? vm.activeTool
            if let styleTool = activeOrSelectedTool {
                if styleTool != .emoji {
                    Divider().frame(height: 16)
                    HStack(spacing: 3) {
                        ForEach(StrokePreset.allCases) { preset in
                            Button(action: {
                                vm.strokePreset = preset
                            }) {
                                HStack(spacing: 3) {
                                    Circle()
                                        .fill(vm.strokePreset == preset ? Color.white : Color.primary.opacity(0.75))
                                        .frame(width: preset.dotDiameter, height: preset.dotDiameter)
                                    Text(preset.localizedShortLabel)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(vm.strokePreset == preset ? .white : .primary.opacity(0.85))
                                }
                                .padding(.horizontal, 5)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(vm.strokePreset == preset ? Color.accentColor : Color.primary.opacity(0.08))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(preset.localizedTooltip)
                        }
                    }
                }

                if styleTool != .mosaic && styleTool != .emoji {
                    Divider().frame(height: 16)
                    HStack(spacing: 4) {
                        ForEach(palette, id: \.self) { c in
                            Button(action: {
                                vm.selectedColor = c
                            }) {
                                Circle()
                                    .fill(c)
                                    .frame(width: 14, height: 14)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white, lineWidth: vm.selectedColor == c ? 2.2 : 0)
                                    )
                                    .frame(width: 18, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }

                if styleTool == .emoji {
                    Divider().frame(height: 16)
                    HStack(spacing: 3) {
                        HStack(spacing: 2) {
                            ForEach(PinAnnotation.quickEmojiPalette, id: \.self) { emoji in
                                let isSelected = vm.selectedEmoji == emoji
                                Button(action: {
                                    vm.hostingPanel?.canvasView?.teardownEmojiCaptureInputView()
                                    if let selID = vm.selectedTextAnnotationID,
                                       vm.annotations.first(where: { $0.id == selID })?.tool == .emoji {
                                        vm.selectedTextAnnotationID = nil
                                    }
                                    vm.selectedEmoji = emoji
                                }) {
                                    Text(emoji)
                                        .font(.system(size: 14.5))
                                        .frame(width: 24, height: 22)
                                        .background(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .fill(isSelected ? Color.accentColor : Color.clear)
                                        )
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            if !PinAnnotation.quickEmojiPalette.contains(vm.selectedEmoji) {
                                Text(vm.selectedEmoji)
                                    .font(.system(size: 14.5))
                                    .frame(width: 24, height: 22)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(Color.accentColor)
                                    )
                            }
                        }
                        .padding(1)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.07))
                        )

                        Button(action: {
                            vm.hostingPanel?.canvasView?.openSystemEmojiPicker()
                        }) {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(.primary.opacity(0.85))
                                .frame(width: 24, height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                                .overlay(alignment: .bottomTrailing) {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 8.5, weight: .bold))
                                        .foregroundColor(.accentColor)
                                        .offset(x: 1, y: 1)
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(L10n.emojiMorePickerTooltip)
                    }
                }

                if styleTool == .text {
                    Divider().frame(height: 16)
                    HStack(spacing: 3) {
                        ForEach(TextBackgroundStyle.allCases) { bgStyle in
                            Button(action: {
                                vm.textBackgroundStyle = bgStyle
                            }) {
                                HStack(spacing: 3) {
                                    ZStack {
                                        if bgStyle == .transparent {
                                            RoundedRectangle(cornerRadius: 3)
                                                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [2, 2]))
                                                .foregroundColor(vm.textBackgroundStyle == bgStyle ? .white : .primary.opacity(0.75))
                                                .frame(width: 11, height: 11)
                                        } else {
                                            RoundedRectangle(cornerRadius: 3)
                                                .fill(bgStyle == .black ? Color.black : Color.white)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 3)
                                                        .stroke(Color.gray.opacity(0.6), lineWidth: 1)
                                                )
                                                .frame(width: 11, height: 11)
                                        }
                                    }
                                    Text(bgStyle.localizedShortLabel)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(vm.textBackgroundStyle == bgStyle ? .white : .primary.opacity(0.85))
                                }
                                .padding(.horizontal, 5)
                                .frame(height: 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(vm.textBackgroundStyle == bgStyle ? Color.accentColor : Color.primary.opacity(0.08))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(bgStyle.localizedTooltip)
                        }
                    }
                }
            }

            Divider().frame(height: 16)

            Button(action: { vm.undo() }) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12))
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!vm.canUndo)
            .help(L10n.toolbarUndoTooltip)

            Button(action: { vm.runOCR(andTranslate: false) }) {
                HStack(spacing: 3) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 12, weight: .semibold))
                    Text("OCR")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .frame(height: 24)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarOCRTooltip)

            Button(action: { vm.runOCR(andTranslate: true) }) {
                HStack(spacing: 3) {
                    Image(systemName: "character.bubble.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(L10n.toolbarTranslateShortLabel)
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 5)
                .frame(height: 24)
                .background(Color.accentColor.opacity(0.18))
                .foregroundColor(.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarTranslateTooltip)

            Button(action: { vm.runQRCodeScan() }) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 24)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarQRTooltip)

            Button(action: { vm.saveToFile() }) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarSaveTooltip)

            Divider().frame(height: 16)

            Button(action: { vm.clipToClothesline() }) {
                HStack(spacing: 3) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11.5, weight: .bold))
                    Text(L10n.toolbarClipLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color(red: 0.78, green: 0.54, blue: 0.28))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarClipTooltip)

            Button(action: {
                if vm.copyToClipboard() {
                    onClose()
                }
            }) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11.5, weight: .bold))
                    Text(L10n.toolbarCopyLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .padding(.horizontal, 6)
                .frame(height: 24)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarCopyTooltip)

            Button(action: { onOpenSettings?() }) {
                Image(systemName: "keyboard")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.shortcutMenuSettings)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.toolbarCloseTooltip)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .fixedSize()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        .padding(6)
    }
}

// MARK: - Detached Floating Toolbar Panel

final class PinToolbarPanel: NSPanel {
    weak var viewModel: PinSessionViewModel?
    var onEscape: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    override var canBecomeKey: Bool { true }

    func refreshToolbarRootView() {
        guard let vm = viewModel,
              let hosting = contentView as? NSHostingView<PinToolbarView> else { return }
        hosting.rootView = PinToolbarView(
            vm: vm,
            onOpenSettings: onOpenSettings,
            onClose: { [weak self] in self?.onEscape?() }
        )
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func insertText(_ insertString: Any) {
        viewModel?.hostingPanel?.canvasView?.insertText(insertString)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            if let vm = viewModel, vm.pendingTextNormalizedPos != nil {
                vm.cancelPendingTextEditing()
                return
            }
            onEscape?()
            return
        }
        if let hosting = viewModel?.hostingPanel {
            hosting.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Native Floating Pin NSPanel

final class PinFloatingPanel: NSPanel {
    var viewModel: PinSessionViewModel?
    var canvasView: PinCanvasNSView?
    var onClosePanel: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        orderFront(nil)
        if let vm = viewModel, vm.showToolbar, let tbPanel = vm.toolbarPanel, tbPanel.isVisible {
            tbPanel.order(.above, relativeTo: windowNumber)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onClosePanel?()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleSettingsShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    private func handleSettingsShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command,
              event.charactersIgnoringModifiers == "," || event.keyCode == 43,
              let onOpenSettings else { return false }
        onOpenSettings()
        return true
    }

    override func insertText(_ insertString: Any) {
        canvasView?.insertText(insertString)
    }

    override func keyDown(with event: NSEvent) {
        if handleSettingsShortcut(event) { return }

        guard let vm = viewModel else {
            super.keyDown(with: event)
            return
        }

        if vm.pendingTextNormalizedPos != nil {
            if event.keyCode == 53 {
                vm.cancelPendingTextEditing()
                return
            }
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 {
            onClosePanel?()
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if vm.copyToClipboard() {
                onClosePanel?()
            }
            return
        }
        if event.keyCode == 48 || chars == "p" {
            vm.clipToClothesline()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            if vm.deleteSelectedAnnotation() {
                return
            }
        }
        if event.keyCode == 49 {
            guard !event.isARepeat else { return }
            vm.showToolbar.toggle()
            return
        }
        if flags.contains(.command) && chars == "z" {
            vm.undo()
            return
        }
        if flags.contains(.command) && chars == "c" {
            vm.copyToClipboard()
            return
        }
        if flags.contains(.command) && chars == "s" {
            vm.saveToFile()
            return
        }
        let unmodifiedLetter = flags.intersection([.command, .option, .control]).isEmpty
        if unmodifiedLetter && chars == "o" {
            vm.runOCR(andTranslate: false)
            return
        }
        if unmodifiedLetter && chars == "q" {
            vm.runQRCodeScan()
            return
        }
        if unmodifiedLetter && chars == "t" {
            vm.runOCR(andTranslate: true)
            return
        }
        if chars == "=" || chars == "+" {
            vm.updateZoom(delta: 0.15)
            return
        }
        if chars == "-" {
            vm.updateZoom(delta: -0.15)
            return
        }

        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let vm = viewModel else { return }
        if event.modifierFlags.contains(.option) {
            let delta = Double(event.scrollingDeltaY) * 0.01
            vm.windowOpacity = max(0.25, min(1.0, vm.windowOpacity + delta))
            canvasView?.needsDisplay = true
        }
        // Unmodified two-finger scroll/swipe does NOT resize the pin window (use +/- keys to zoom if needed)
    }
}
