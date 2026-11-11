# Changelog

All notable changes to **ClipLine** are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).

## [0.2.0] - 2026-11-11

### Added
- **Horizontal clothesline stitch & Frame backdrop**: Added side-by-side (`Side`) stitching and optional dark framed backdrop with rounded corners and drop shadow.
- **Spotlight annotation tool**: Dim exterior pixels while keeping one or more focus areas bright, with full corner-handle resize and interior drawing pass-through.
- **Clipboard text sticky notes (`⌃⌘V` / `--clipboard`)**: Render plain text or code snippets on the clipboard into a 2x Retina sticky-note Pin window.
- **Emoji sticker tool & corner-handle annotation resizing**: Added inline emoji sticker placement, system Character Palette (`🌐`) integration, and 4-corner resize handles for `.rect`, `.spotlight`, `.text`, and `.emoji`.
- **QR / barcode detection & multi-photo drag-out**: Offline Vision barcode scanning (`Q`) with safe URL confirmation and direct multi-photo file drag from the Clothesline dock.
- **Version & diagnostics CLI (`--version`, `--doctor`)**: Compile-time version metadata from `VERSION`, read-only local diagnostic report (`clipline --doctor`), and structured event logging without capturing user content.

### Fixed
- **Retina 2x CTM scaling in `stitchImagesGrid`**: Set `NSBitmapImageRep.size` before creating `NSGraphicsContext(bitmapImageRep:)` and extended linear frame gradients across all four corners.
- **Zoomed Spotlight hit-testing**: Scaled corner-handle and interior pass-through hit radii at minimum zoom (`35%`).
- **Highlighter toolbar icon clarity**: Added a high-visibility fluorescent color swatch bar beneath the highlighter symbol.
