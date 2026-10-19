# ClipLine

Capture screenshots, annotate them, and clip them to a floating clothesline at the top of your screen.

[简体中文](README.zh-CN.md)

```
   ═══════🪵══════════════🪵══════════════🪵═══════
       ┌──────┐       ┌──────┐       ┌──────┐
       │ #1   │       │ #2   │       │ #3   │
       └──────┘       └──────┘       └──────┘
```

## Quickstart

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
make install
~/.local/bin/clipline &
```

Press `⌃X` (`Control + X`) to capture a region, then press `P` to hang it on the top clothesline.

## Usage

### 1. Capture and adjust crop in place

Press `⌃X` and drag to select a region. The screenshot stays pinned at the exact screen coordinates you selected.

Before moving the pin or selecting a drawing tool (at `100%` zoom), drag any of the 8 handles or 4 edges to expand or shrink the crop against the original full-screen frame.

### 2. Hang multiple pins on the clothesline

Press `P` (or click the clothespin icon) to park the current pin on the clothesline at the top of your screen:

- **Stitch & copy**: Click multiple thumbnails on the line and click **Copy** to stitch them vertically into one image.
- **Drag & drop**: Drag any thumbnail directly into Slack, a browser, or Finder.
- **Unclip**: Double-click any thumbnail to return it to the canvas.

### 3. Annotate, OCR, and translate

- **Tools**: Rectangle, arrow, freehand pen, text, and mosaic (`CIPixellate`), with 3 stroke sizes (`S` / `M` / `L` or `细` / `中` / `粗`) and 6 colors.
- **Text**: Supports transparent, black pill, or white pill backgrounds. Drag anywhere inside the text box to move it, or double-click committed text to edit it in place.
- **OCR (`O`)**: Recognizes Simplified Chinese, Traditional Chinese, and English offline via macOS `Vision` and copies the text to your clipboard.
- **Translate (`T`)**: Runs OCR on the composited image and routes text to:
  1. Local translation daemon (`fy-daemon`, or custom name via `CLIP_LINE_TRANSLATE_DAEMON`)
  2. Custom URL template (`CLIP_LINE_TRANSLATE_URL`)
  3. macOS system Translation service
  4. Browser translation (prompts once per destination domain before opening)

### 4. CLI triggers

When the daemon is running, you can also trigger it from a terminal or script:

```bash
clipline --capture     # start interactive region capture
clipline --clipboard   # pin current clipboard image
```

## Shortcuts

| Shortcut | Context | Action |
| :--- | :--- | :--- |
| `⌃X` | Global | Capture region |
| `⌘⇧X` | Global | Capture region (secondary shortcut) |
| `⌃⌘V` | Global | Pin image from clipboard |
| `↩` (`Return`) | Active pin | Copy composited image and close pin |
| `⌘C` | Active pin | Copy composited image (keep pin open) |
| `⌘S` | Active pin | Save as PNG |
| `P` / `⇥` (`Tab`) | Active pin | Hang pin on the clothesline |
| `O` | Active pin | Copy OCR text |
| `T` | Active pin | Run OCR and translate |
| `Space` | Active pin | Toggle toolbar |
| `⌘Z` | Active pin | Undo last annotation |
| `+` / `-` | Active pin | Zoom (`35%` – `300%`) |
| `⌥` + Scroll | Active pin | Adjust opacity (`25%` – `100%`) |
| `⎋` (`Esc`) | Capture / Pin | Cancel capture, cancel text edit, or close pin without modifying the clipboard |

## Permissions

On first capture, macOS prompts for **Screen Recording** permission:

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Enable `clipline`.

## Configuration

| Variable / Key | Default | Description |
| :--- | :--- | :--- |
| `CLIP_LINE_LANG` | Auto (`Locale.preferredLanguages`) | UI language override (`en` or `zh-Hans`) |
| `CLIP_LINE_TRANSLATE_TARGET` | `en` (EN UI) / `zh-CN` (ZH UI) | Target language code (`tl`) for built-in web translation fallback |
| `CLIP_LINE_TRANSLATE_URL` | Unset | Custom HTTPS (or `localhost` HTTP) URL template using `{text}` placeholder |
| `TranslateURLTemplate` (`NSGlobalDomain`) | Unset | Persistent `defaults write` equivalent of `CLIP_LINE_TRANSLATE_URL` |
| `CLIP_LINE_TRANSLATE_DAEMON` | `fy-daemon` | Process name checked for local translation routing |
| `CLIP_LINE_TRANSLATE_CHANNEL` | `io.github.clipline.translate` | Distributed notification channel for local translation |
| `CLIP_LINE_CAPTURE_CHANNEL` | `io.github.clipline.capture` | Distributed notification channel for external capture triggers |

Example custom translation URL:

```bash
export CLIP_LINE_TRANSLATE_URL="https://www.deepl.com/translator#en/zh/{text}"
```

## Development

```bash
make build   # compile release binary to ./build/clipline
make test    # run 86 unit & AppKit checks (uses isolated pasteboard and temp directory)
make clean   # remove ./build
```

## Privacy & Security Notes

- **Mosaic is visual obfuscation**: Uses `CoreImage` `CIPixellate` (and falls back to an opaque dark fill if pixelation fails). For sensitive credentials or keys, crop them out or cover them with an opaque pen stroke.
- **Temporary files**: Writes `ClipLine_*.png` to `$TMPDIR/ClipLine` (`0700`) so file-paste and drag-and-drop work across Finder and chat apps. Files older than 1 hour are removed on daemon startup and on subsequent copy actions.
- **Local notifications**: When `fy-daemon` is running, OCR text is posted via `DistributedNotificationCenter` within the current macOS user session.

## License

[MIT](LICENSE)
