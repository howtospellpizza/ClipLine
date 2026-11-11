# Contributing to ClipLine

Thank you for contributing to **ClipLine**! ClipLine is a native, zero-dependency macOS screenshot, annotation, and floating pin CLI utility built with Swift, AppKit, and SwiftUI.

## Prerequisites
- **macOS 14.0 (Sonoma) or later**
- **Xcode Command Line Tools** (`xcode-select --install`)

## Development Workflow

1. **Build the binary**
   ```bash
   make build
   ```
   This syncs `VERSION` into `Sources/ClipLine/Services/GeneratedVersion.swift` and compiles `build/clipline`.

2. **Run the regression test suites**
   ```bash
   make test
   ```
   All tests run in-process against an isolated `NSPasteboard` and temporary directory without touching your live clipboard or running daemon.

   To run a single test suite during iteration:
   ```bash
   make test FILTER="Suite 5"
   ```

3. **Run the isolated install/uninstall smoke test**
   ```bash
   make test-install
   ```

4. **Check local diagnostics**
   ```bash
   ./build/clipline --version
   ./build/clipline --doctor
   ```

## Test Suite Layout (`Tests/`)
- `TestHarness.swift`: Shared test runner, suite filter parser, and capture fixtures.
- `Suite1_CaptureAndCropTests.swift`: Geometry, crop math, window snap, pixel loupe, and Screen Recording permission checks.
- `Suite2_MosaicAndRedactionTests.swift`: Lazy `CIPixellate` mosaic verification and fail-closed redaction.
- `Suite3_TranslateOCRAndLockTests.swift`: URL encoding, OCR pasteboard guard, and single-instance lock.
- `Suite4_PinToolbarAndCanvasTests.swift`: Dual-panel AppKit/SwiftUI GUI regression, 8-handle resize, and annotation hit-testing.
- `Suite5_ClotheslineStitchAndTextTests.swift`: Clothesline multi-image copy, vertical/horizontal stitching, Spotlight, and clipboard text sticky notes.
- `Suite6_ShortcutSettingsTests.swift`: Global shortcut validation, transactional Carbon registration, and settings UI.
- `Suite7_LocalizationQRAndDragTests.swift`: `en` / `zh-Hans` localization, multi-photo drag-out, and Vision QR detection.
- `ClipLineUpdaterTests.swift` (Suite 8): Offline, isolated `--update` verification.
- `Suite9_VersionAndDiagnosticsTests.swift` (Suite 9): Version metadata, event log rotation, and `--doctor` report output.

## Pull Request & Release Conventions
- Use [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `docs:`, `test:`, `chore:`) so release notes can be generated automatically.
- Ensure `make build`, `make test`, and `make test-install` pass before opening a PR.
- Keep `README.md` and `README.zh-CN.md` synchronized when adding user-facing flags, shortcuts, or tools.
- Releases are lightweight (version bump in `VERSION` + `CHANGELOG.md` + Git tag & GitHub Release); ClipLine installs directly as a CLI binary via `make install` / `clipline --update` without `.app` or `.dmg` bundle overhead.
