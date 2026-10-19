import Foundation

// MARK: - Type-Safe In-Binary Localization (EN & Simplified Chinese)

enum AppLanguage: String, CaseIterable, Equatable {
    case en = "en"
    case zhHans = "zh-Hans"

    static var current: AppLanguage = resolveLanguage(
        envOverride: ProcessInfo.processInfo.environment["CLIP_LINE_LANG"],
        preferredLanguages: Locale.preferredLanguages
    )

    static func resolveLanguage(envOverride: String?, preferredLanguages: [String]) -> AppLanguage {
        if let rawEnv = envOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !rawEnv.isEmpty {
            if let matched = matchLanguageTag(rawEnv) {
                return matched
            }
        }
        for lang in preferredLanguages {
            if let matched = matchLanguageTag(lang) {
                return matched
            }
        }
        return .en
    }

    static func matchLanguageTag(_ rawTag: String) -> AppLanguage? {
        let lower = rawTag
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if lower == "en" || lower.hasPrefix("en-") {
            return .en
        }
        // Only treat Simplified Chinese tags as .zhHans; do not misclassify zh-Hant / zh-TW / zh-HK
        if lower == "zh"
            || lower == "zh-cn"
            || lower == "zh-sg"
            || lower.hasPrefix("zh-hans") {
            return .zhHans
        }
        return nil
    }

    static func resolveTranslateTargetLanguage(
        envOverride: String? = ProcessInfo.processInfo.environment["CLIP_LINE_TRANSLATE_TARGET"],
        uiLanguage: AppLanguage = AppLanguage.current
    ) -> String {
        if let raw = envOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        switch uiLanguage {
        case .en:
            return "en"
        case .zhHans:
            return "zh-CN"
        }
    }
}

enum L10n {
    // MARK: - Annotation Tools

    static func toolName(_ tool: PinAnnotation.Tool, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            switch tool {
            case .rect: return "Rectangle"
            case .arrow: return "Arrow"
            case .pen: return "Pen"
            case .mosaic: return "Mosaic"
            case .text: return "Text"
            }
        case .zhHans:
            switch tool {
            case .rect: return "框选"
            case .arrow: return "箭头"
            case .pen: return "画笔"
            case .mosaic: return "马赛克"
            case .text: return "文字"
            }
        }
    }

    // MARK: - Stroke Presets (Compact Toolbar Label + Full Tooltip)

    static func strokeShortLabel(_ preset: StrokePreset, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            switch preset {
            case .thin: return "S"
            case .medium: return "M"
            case .thick: return "L"
            }
        case .zhHans:
            switch preset {
            case .thin: return "细"
            case .medium: return "中"
            case .thick: return "粗"
            }
        }
    }

    static func strokeTooltip(_ preset: StrokePreset, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            switch preset {
            case .thin: return "Stroke size: Thin (S)"
            case .medium: return "Stroke size: Medium (M)"
            case .thick: return "Stroke size: Thick (L)"
            }
        case .zhHans:
            switch preset {
            case .thin: return "粗细：细"
            case .medium: return "粗细：中"
            case .thick: return "粗细：粗"
            }
        }
    }

    // MARK: - Text Background Styles (Compact Toolbar Label + Full Tooltip)

    static func textBgShortLabel(_ style: TextBackgroundStyle, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            switch style {
            case .transparent: return "Clear"
            case .black: return "Dark"
            case .white: return "Light"
            }
        case .zhHans:
            switch style {
            case .transparent: return "透明"
            case .black: return "黑底"
            case .white: return "白底"
            }
        }
    }

    static func textBgTooltip(_ style: TextBackgroundStyle, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            switch style {
            case .transparent: return "Text background: Transparent"
            case .black: return "Text background: Dark pill"
            case .white: return "Text background: Light pill"
            }
        case .zhHans:
            switch style {
            case .transparent: return "文字背景：透明"
            case .black: return "文字背景：黑底"
            case .white: return "文字背景：白底"
            }
        }
    }

    // MARK: - Toolbar Actions & Tooltips

    static var toolbarUndoTooltip: String {
        switch AppLanguage.current {
        case .en: return "Undo (Cmd+Z)"
        case .zhHans: return "撤销 (Cmd+Z)"
        }
    }

    static var toolbarOCRTooltip: String {
        switch AppLanguage.current {
        case .en: return "Extract and copy text from image (O)"
        case .zhHans: return "提取图中文字并复制 (O)"
        }
    }

    static var toolbarTranslateShortLabel: String {
        switch AppLanguage.current {
        case .en: return "Trans"
        case .zhHans: return "译"
        }
    }

    static var toolbarTranslateTooltip: String {
        switch AppLanguage.current {
        case .en: return "Extract and translate text in image (T)"
        case .zhHans: return "识别图中文字并直接翻译 (T)"
        }
    }

    static var toolbarSaveTooltip: String {
        switch AppLanguage.current {
        case .en: return "Save as PNG (Cmd+S)"
        case .zhHans: return "保存为 PNG (Cmd+S)"
        }
    }

    static var toolbarClipLabel: String {
        switch AppLanguage.current {
        case .en: return "Clip"
        case .zhHans: return "夹起"
        }
    }

    static var toolbarClipTooltip: String {
        switch AppLanguage.current {
        case .en: return "Clip to top clothesline dock (P / Tab)"
        case .zhHans: return "夹到顶部晾衣绳 (快捷键 P / Tab)"
        }
    }

    static var toolbarCopyLabel: String {
        switch AppLanguage.current {
        case .en: return "Copy"
        case .zhHans: return "复制"
        }
    }

    static var toolbarCopyTooltip: String {
        switch AppLanguage.current {
        case .en: return "Copy and close (↵ Enter / Cmd+C)"
        case .zhHans: return "复制并关闭 (↵ Enter / Cmd+C)"
        }
    }

    static var toolbarCloseTooltip: String {
        switch AppLanguage.current {
        case .en: return "Discard / Close pin (Esc)"
        case .zhHans: return "关闭贴图 (Esc)"
        }
    }

    // MARK: - Inline Text Field

    static var inlineTextPlaceholder: String {
        switch AppLanguage.current {
        case .en: return "Type text..."
        case .zhHans: return "输入文字..."
        }
    }

    // MARK: - Clothesline Dock

    static func clotheslineCopyCountLabel(_ count: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Copy (\(count))"
        case .zhHans: return "复制 (\(count))"
        }
    }

    static var clotheslineCopyTooltip: String {
        switch AppLanguage.current {
        case .en: return "Copy selected as separate images"
        case .zhHans: return "将选中的图片作为多张独立图片复制到剪贴板"
        }
    }

    static var clotheslineStitchLabel: String {
        switch AppLanguage.current {
        case .en: return "Stitch"
        case .zhHans: return "拼长图"
        }
    }

    static var clotheslineStitchTooltip: String {
        switch AppLanguage.current {
        case .en: return "Seamlessly stitch selected images vertically into one high-res image and copy"
        case .zhHans: return "将选中的多张图片无缝纵向拼接为一张高清长图并复制"
        }
    }

    static func toastStitchedPhotos(_ count: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Stitched \(count) images into 1 and copied"
        case .zhHans: return "已将 \(count) 张图无缝拼成 1 张并复制"
        }
    }

    static func clotheslineSelectAllLabel(allSelected: Bool, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return allSelected ? "Deselect" : "Select All"
        case .zhHans: return allSelected ? "全不选" : "全选"
        }
    }

    static var clotheslineSaveSelectedTooltip: String {
        switch AppLanguage.current {
        case .en: return "Save selected"
        case .zhHans: return "保存选中"
        }
    }

    static var clotheslineClearAllTooltip: String {
        switch AppLanguage.current {
        case .en: return "Clear clothesline"
        case .zhHans: return "收起晾衣绳"
        }
    }

    static var clotheslinePhotoHelp: String {
        switch AppLanguage.current {
        case .en: return "Click: select/deselect · Double-click: restore to edit · Drag: drop into apps"
        case .zhHans: return "单击：选中/取消 · 双击：取下继续标注 · 按住可直接拖拽到聊天框"
        }
    }

    static func clotheslineSaveFolderPrompt(_ count: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Save \(count) \(count == 1 ? "image" : "images")"
        case .zhHans: return "保存这 \(count) 张图片"
        }
    }

    // MARK: - Toasts & Status Messages

    static var toastRenderFailedRefusedExport: String {
        switch AppLanguage.current {
        case .en: return "Composite render failed; export refused"
        case .zhHans: return "图像合成失败，已拒绝导出"
        }
    }

    static var toastRenderFailedCannotSave: String {
        switch AppLanguage.current {
        case .en: return "Composite render failed; unable to save"
        case .zhHans: return "图像合成失败，无法保存"
        }
    }

    static func toastClippedToLine(selectedCount: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Clipped to clothesline (\(selectedCount) selected)"
        case .zhHans: return "已夹上晾衣绳（当前选中 \(selectedCount) 张）"
        }
    }

    static var toastDeselectedAll: String {
        switch AppLanguage.current {
        case .en: return "Deselected all"
        case .zhHans: return "已取消全选"
        }
    }

    static var toastSelectPhotosToCopy: String {
        switch AppLanguage.current {
        case .en: return "Select at least one image to copy"
        case .zhHans: return "请先勾选要复制的照片"
        }
    }

    static var toastSelectPhotosToSave: String {
        switch AppLanguage.current {
        case .en: return "Select at least one image to save"
        case .zhHans: return "请先勾选要保存的照片"
        }
    }

    static func toastCopiedPhotos(_ count: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Copied \(count) \(count == 1 ? "image" : "images") to clipboard"
        case .zhHans: return "已复制 \(count) 张照片到剪贴板"
        }
    }

    static var toastCopyFailed: String {
        switch AppLanguage.current {
        case .en: return "Copy failed; unable to write to clipboard"
        case .zhHans: return "复制失败，未能写入剪贴板"
        }
    }

    static var toastCopiedSingleImage: String {
        switch AppLanguage.current {
        case .en: return "Copied to clipboard"
        case .zhHans: return "已复制到剪贴板"
        }
    }

    static var toastSavedSingleImage: String {
        switch AppLanguage.current {
        case .en: return "Image saved"
        case .zhHans: return "已保存图片"
        }
    }

    static func toastSavedMultipleImages(_ count: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Saved \(count) \(count == 1 ? "image" : "images")"
        case .zhHans: return "已保存 \(count) 张图片"
        }
    }

    static func toastSavedPartialImages(saved: Int, total: Int, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return "Saved \(saved)/\(total) images (some writes failed)"
        case .zhHans: return "已保存 \(saved)/\(total) 张图片（部分写入失败）"
        }
    }

    static var toastSaveFailedCheckPermissions: String {
        switch AppLanguage.current {
        case .en: return "Save failed; check directory permissions"
        case .zhHans: return "保存失败，请检查文件权限"
        }
    }

    static var toastTranslatedViaDaemon: String {
        switch AppLanguage.current {
        case .en: return "OCR complete · Opening local translator"
        case .zhHans: return "已识别并唤起翻译"
        }
    }

    static var toastOCRCopiedCancelledWebTranslate: String {
        switch AppLanguage.current {
        case .en: return "OCR text copied (web translation cancelled)"
        case .zhHans: return "OCR 文本已复制（已取消网页翻译）"
        }
    }

    static var toastOCRCopiedOpenedCustomTranslate: String {
        switch AppLanguage.current {
        case .en: return "OCR text copied · Opening custom translator"
        case .zhHans: return "已复制文本并打开自定义翻译"
        }
    }

    static var toastOCRCopiedOpenedSystemTranslate: String {
        switch AppLanguage.current {
        case .en: return "Opened macOS system translation"
        case .zhHans: return "已唤起 macOS 系统翻译"
        }
    }

    static var toastOCRCopiedOpenedWebTranslate: String {
        switch AppLanguage.current {
        case .en: return "OCR text copied · Opening web translation"
        case .zhHans: return "已复制文本并打开网页翻译"
        }
    }

    static var toastOCRNoTextFound: String {
        switch AppLanguage.current {
        case .en: return "No text recognized"
        case .zhHans: return "未识别到文字"
        }
    }

    static var toastOCRClipboardChangedSkipped: String {
        switch AppLanguage.current {
        case .en: return "Clipboard changed; skipped overwriting"
        case .zhHans: return "剪贴板已更新，未覆盖新内容"
        }
    }

    static var toastOCRTextCopied: String {
        switch AppLanguage.current {
        case .en: return "OCR text copied"
        case .zhHans: return "OCR 文本已复制"
        }
    }

    static var toastUnableToReadImage: String {
        switch AppLanguage.current {
        case .en: return "Unable to read image"
        case .zhHans: return "无法读取图像"
        }
    }

    static func toastOCRInProgress(andTranslate: Bool, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en: return andTranslate ? "Recognizing & translating..." : "Recognizing text..."
        case .zhHans: return andTranslate ? "正在识别并翻译..." : "正在识别文字..."
        }
    }

    static var toastOCRError: String {
        switch AppLanguage.current {
        case .en: return "OCR recognition failed"
        case .zhHans: return "OCR 识别出错"
        }
    }

    // MARK: - Alerts (Screen Recording Permission & Web Translation Consent)

    static var alertScreenRecordingTitle: String {
        switch AppLanguage.current {
        case .en: return "Screen Recording Permission Required"
        case .zhHans: return "需要「屏幕录制」权限才能截图"
        }
    }

    static var alertScreenRecordingBody: String {
        switch AppLanguage.current {
        case .en:
            return "Please open System Settings → Privacy & Security → Screen & System Audio Recording, enable your terminal or the clipline binary, and try again."
        case .zhHans:
            return "请前往「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」，勾选允许当前终端或 ClipLine 可执行程序后重试。"
        }
    }

    static var alertOpenSystemSettingsButton: String {
        switch AppLanguage.current {
        case .en: return "Open System Settings"
        case .zhHans: return "打开系统设置"
        }
    }

    static var alertCancelButton: String {
        switch AppLanguage.current {
        case .en: return "Cancel"
        case .zhHans: return "取消"
        }
    }

    static var alertWebTranslateTitle: String {
        switch AppLanguage.current {
        case .en: return "Open External Translation Service?"
        case .zhHans: return "即将使用外部翻译服务打开识别文本"
        }
    }

    static func alertWebTranslateBody(destinationHost: String, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            return "No local translation daemon was detected. Allow sending the recognized OCR text to \(destinationHost) in your default browser? (Your choice will be remembered for this host.)"
        case .zhHans:
            return "当前未检测到本地翻译守护进程。是否允许将 OCR 识别到的文字通过默认浏览器发送到 \(destinationHost)？（后续将记住您的选择）"
        }
    }

    static var alertWebTranslateAllowButton: String {
        switch AppLanguage.current {
        case .en: return "Allow & Open Browser"
        case .zhHans: return "允许并打开网页翻译"
        }
    }

    static var alertWebTranslateCopyOnlyButton: String {
        switch AppLanguage.current {
        case .en: return "Copy Text Only"
        case .zhHans: return "仅复制文本，不打开网页"
        }
    }

    // MARK: - Global Shortcut Settings

    static var shortcutMenuCapture: String {
        switch AppLanguage.current {
        case .en: return "Capture Region"
        case .zhHans: return "框选截图"
        }
    }

    static var shortcutMenuClipboard: String {
        switch AppLanguage.current {
        case .en: return "Pin Clipboard Image"
        case .zhHans: return "贴上剪贴板图片"
        }
    }

    static var shortcutMenuSettings: String {
        switch AppLanguage.current {
        case .en: return "Keyboard Shortcuts…"
        case .zhHans: return "键盘快捷键…"
        }
    }

    static var shortcutMenuQuit: String {
        switch AppLanguage.current {
        case .en: return "Quit ClipLine"
        case .zhHans: return "退出 ClipLine"
        }
    }

    static var shortcutWindowTitle: String {
        switch AppLanguage.current {
        case .en: return "Keyboard Shortcuts"
        case .zhHans: return "键盘快捷键"
        }
    }

    static var shortcutSettingsHeading: String {
        switch AppLanguage.current {
        case .en: return "Global Shortcuts"
        case .zhHans: return "全局快捷键"
        }
    }

    static var shortcutSettingsHelp: String {
        switch AppLanguage.current {
        case .en: return "Click a shortcut to record. Use Control, Option, or Command with a key. Escape cancels; Tab moves focus."
        case .zhHans: return "点击快捷键按钮开始录制。请使用 Control、Option 或 Command 加一个按键。按 Escape 取消，按 Tab 移动焦点。"
        }
    }

    static var shortcutRecordingTitle: String {
        switch AppLanguage.current {
        case .en: return "Type shortcut…"
        case .zhHans: return "请按下快捷键…"
        }
    }

    static var shortcutRecordingAccessibilityValue: String {
        switch AppLanguage.current {
        case .en: return "Recording; press Escape to cancel"
        case .zhHans: return "正在录制；按 Escape 取消"
        }
    }

    static var shortcutRestoreDefaults: String {
        switch AppLanguage.current {
        case .en: return "Restore Defaults"
        case .zhHans: return "恢复默认值"
        }
    }

    static func shortcutName(_ action: ShortcutAction, lang: AppLanguage = .current) -> String {
        switch lang {
        case .en:
            switch action {
            case .capture: return "Capture Region"
            case .captureSecondary: return "Secondary Capture"
            case .clipboard: return "Pin Clipboard Image"
            }
        case .zhHans:
            switch action {
            case .capture: return "框选截图"
            case .captureSecondary: return "备用截图"
            case .clipboard: return "贴上剪贴板图片"
            }
        }
    }

    static func shortcutButtonLabel(
        _ action: ShortcutAction,
        binding: ShortcutBinding,
        lang: AppLanguage = .current
    ) -> String {
        switch lang {
        case .en: return "\(shortcutName(action, lang: lang)) shortcut, currently \(binding.displayString)"
        case .zhHans: return "\(shortcutName(action, lang: lang))快捷键，当前为 \(binding.displayString)"
        }
    }

    static func shortcutValidationMessage(
        _ error: ShortcutValidationError,
        lang: AppLanguage = .current
    ) -> String {
        switch error {
        case .unsupportedModifiers:
            switch lang {
            case .en: return "This modifier combination is not supported."
            case .zhHans: return "不支持此修饰键组合。"
            }
        case .requiredModifier:
            switch lang {
            case .en: return "Use at least Control, Option, or Command with a key."
            case .zhHans: return "请至少使用 Control、Option 或 Command 修饰键。"
            }
        case .unsupportedKeyCode(let keyCode):
            switch lang {
            case .en: return "This key is not supported (key code \(keyCode))."
            case .zhHans: return "不支持此按键（键码 \(keyCode)）。"
            }
        case .reservedShortcut:
            switch lang {
            case .en: return "That key is reserved for system or app navigation. Choose another."
            case .zhHans: return "该按键保留给系统或应用导航，请选择其他按键。"
            }
        case .duplicate(let first, let second):
            switch lang {
            case .en: return "\(shortcutName(second, lang: lang)) duplicates \(shortcutName(first, lang: lang)). Choose a different shortcut."
            case .zhHans: return "\(shortcutName(second, lang: lang))与\(shortcutName(first, lang: lang))重复，请选择其他快捷键。"
            }
        }
    }

    static func shortcutRuntimeMessage(_ error: Error, lang: AppLanguage = .current) -> String {
        guard let error = error as? ShortcutRuntimeError else {
            switch lang {
            case .en: return "The shortcut settings could not be updated."
            case .zhHans: return "无法更新快捷键设置。"
            }
        }

        switch error {
        case .launchRegistrationFailed(let failures):
            let message: String
            switch lang {
            case .en: message = "Some configured shortcuts could not be registered; they remain saved but inactive."
            case .zhHans: message = "部分已配置的快捷键未能注册；设置仍已保存，但当前未生效。"
            }
            return appendRollbackWarning(message, failures: failures, lang: lang)
        case .validationFailed(let validation, let restorationFailures):
            return appendRollbackWarning(
                shortcutValidationMessage(validation, lang: lang),
                failures: restorationFailures,
                lang: lang
            )
        case .unregisterFailed(let action, let status, let rollbackFailures):
            let message: String
            switch lang {
            case .en: message = "Could not pause \(shortcutName(action, lang: lang)) (OSStatus \(status))."
            case .zhHans: message = "无法暂时停用\(shortcutName(action, lang: lang))（OSStatus \(status)）。"
            }
            return appendRollbackWarning(message, failures: rollbackFailures, lang: lang)
        case .registrationFailed(let action, let status, let rollbackFailures):
            let message: String
            if rollbackFailures.isEmpty {
                switch lang {
                case .en: message = "Could not register \(shortcutName(action, lang: lang)) (OSStatus \(status)); previous shortcuts were restored."
                case .zhHans: message = "无法注册\(shortcutName(action, lang: lang))（OSStatus \(status)）；已恢复原有快捷键。"
                }
            } else {
                switch lang {
                case .en: message = "Could not register \(shortcutName(action, lang: lang)) (OSStatus \(status)). Rollback also failed."
                case .zhHans: message = "无法注册\(shortcutName(action, lang: lang))（OSStatus \(status)），回滚也失败。"
                }
            }
            return appendRollbackWarning(message, failures: rollbackFailures, lang: lang)
        case .restorationFailed(let failures):
            let message: String
            switch lang {
            case .en: message = "One or more existing shortcuts could not be restored."
            case .zhHans: message = "一个或多个原有快捷键未能恢复。"
            }
            return appendRollbackWarning(message, failures: failures, lang: lang)
        }
    }

    private static func appendRollbackWarning(
        _ message: String,
        failures: [ShortcutRegistrationFailure],
        lang: AppLanguage
    ) -> String {
        guard !failures.isEmpty else { return message }
        let statuses = failures.map { "\(shortcutName($0.action, lang: lang)): \($0.status)" }.joined(separator: ", ")
        switch lang {
        case .en: return "\(message) Some shortcuts may not match the saved settings (OSStatus: \(statuses))."
        case .zhHans: return "\(message) 部分快捷键可能与已保存设置不一致（OSStatus：\(statuses)）。"
        }
    }
}
