# AGENTS.md — ClipLine Engineering & Agent Guide

## 1. Build, Test & Verification Commands
- **Build release binary**: `make build` (syncs `VERSION` → `Sources/ClipLine/Services/GeneratedVersion.swift` and compiles `build/clipline` for `$(uname -m)-apple-macosx14.0`).
- **Run full regression suite**: `make test` (runs all 9 in-process unit and AppKit GUI regression suites in an isolated pasteboard & temporary directory).
- **Run a single test suite**: `make test FILTER="Suite 5"` (or `./build/clipline-tests --filter "Suite 5"`; exits non-zero if no suite matches).
- **Run isolated install/uninstall smoke check**: `make test-install` (never touches the user's real `~/.local/bin/clipline` or live daemon).
- **Inspect version & local diagnostics**: `./build/clipline --version` and `./build/clipline --doctor [--json]`.

## 2. Module Boundaries (`Sources/ClipLine/`)
- `main.swift`: CLI flag parsing (`--capture`, `--clipboard`, `--settings`, `--shortcuts`, `--doctor`, `--update`, `--version`, `--help`) and single-instance lock handoff.
- `App/`: `PinDaemonApp` (menu bar status item, Carbon global hotkeys, distributed notification listener) and `KeyboardShortcutsSettings` (SwiftUI settings window).
- `Capture/`: `ScreenCaptureOverlayController` and `PixPinSelectionView` (multi-display fullscreen overlay, window snap detection, pixel loupe, live Screen Recording permission checks).
- `Pin/`: `PinSessionViewModel` (annotations, undo stack, lazy `CIPixellate` mosaic, composite export, Vision OCR & barcode detection), `PinCanvasView` (AppKit hit-testing, 8-handle screen re-crop, inline text field, Spotlight hole), and `PinPanelsAndToolbar` (dual floating panels + SwiftUI toolbar).
- `Clothesline/`: `ClotheslineManager` and `ClotheslineBarView` (top-of-screen dock, multi-photo selection, drag-out NSItemProvider export, vertical/horizontal stitching, framed backdrop toggle).
- `Models/`: `Annotation.swift` (`AnnotationTool`, `StrokeWidthPreset`, `TextBackgroundStyle`, `PinAnnotation`).
- `Services/`: `SystemServices.swift` (pasteboard, `stitchImagesGrid`, `renderTextCardImage`, translation URL builder, temp file hygiene), `KeyboardShortcuts.swift`, `Localization.swift` (`en` / `zh-Hans`), `ClipLineUpdater.swift`, `Version.swift`, and `DiagnosticsService.swift`.

## 3. Coordinate & Retina Invariants (Must Not Regress)
- **Normalized annotation coordinates**: `PinAnnotation.points` are stored in `[0, 1] × [0, 1]` relative to `PinSessionViewModel.baseSize`, with **bottom-left origin** (`y = 0` at bottom, `y = 1` at top) matching AppKit `NSView` coordinates (`isFlipped == false`).
- **2x Retina `NSBitmapImageRep` CTM**: Whenever creating a 2x Retina bitmap buffer (`pixelsWide = width * 2`, `pixelsHigh = height * 2`), **always set `rep.size = targetPointSize` BEFORE calling `NSGraphicsContext(bitmapImageRep: rep)`** so the CoreGraphics context CTM scales 1pt → 2px across the full buffer.
- **CoreGraphics linear gradients**: When drawing diagonal gradients across a rounded rect, pass `[.drawsBeforeStartLocation, .drawsAfterEndLocation]` so corners outside the gradient axis perpendiculars are never clipped.
- **Dual-panel focus & z-order**: `PinFloatingPanel` and `PinToolbarPanel` intentionally omit `.nonactivatingPanel` so WindowServer CPS focus stays consistent and keyboard shortcuts (`⌘Z`, `Delete`, `Return`, `Esc`, `P`) work immediately on click.

## 4. Safety, Privacy & Asset Constraints
- **Zero-upload privacy**: Never log or transmit screenshot pixels, clipboard text, OCR strings, QR payloads, or window titles. `DiagnosticsService.recordEvent` must only record high-level operational status codes.
- **Fail-closed redaction**: If `CIPixellate` ever fails during `.mosaic` rendering, paint an opaque dark redaction block rather than exposing underlying pixels.
- **GIF inspection constraint**: Never pass `.gif` files directly to an AI model image reader (`read` tool); extract or render `.jpg`/`.png` frames via Swift/ImageIO first.
