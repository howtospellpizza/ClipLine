# ClipLine

Capture screenshots, annotate them, and clip them to a floating clothesline at the top of your screen.

[简体中文](README.zh-CN.md)

```
   ═══════🪵══════════════🪵══════════════🪵═══════
       ┌──────┐       ┌──────┐       ┌──────┐
       │ #1   │       │ #2   │       │ #3   │
       └──────┘       └──────┘       └──────┘
```

## Installation & Quickstart

### Prerequisites

- macOS 14+ deployment target configured (runtime-tested on the maintainer's current machine; macOS 14/Intel runtime compatibility is not independently verified).
- Swift 5.9+ command-line tools (`xcode-select --install`). If prompted, complete installation and wait for the installer to finish before proceeding.

### Install from Source

```bash
git clone https://github.com/howtospellpizza/ClipLine.git
cd ClipLine
make install
nohup ~/.local/bin/clipline >"$HOME/Library/Logs/clipline.log" 2>&1 &
```

> **Note**: This starts `clipline` in the background for the current session. It does not automatically register a login item or guarantee launch on system startup.

Open the ClipLine menu bar menu → **Keyboard Shortcuts** to view or edit all global shortcuts. Factory defaults: `⌃X` captures a region, `⌘⇧X` is the secondary capture shortcut, and `⌃⌘V` pins the clipboard image.

### Update & Reinstall

To update from the repository checkout:

```bash
cd /path/to/ClipLine
git pull --ff-only
make build
make uninstall
make install
nohup ~/.local/bin/clipline >"$HOME/Library/Logs/clipline.log" 2>&1 &
```

- If `git pull --ff-only` fails due to local changes, stop and resolve your working tree before updating.
- Always run `make build` before `make uninstall` so any compile failure leaves your existing installed version intact.
- `make update`, `make version`, or service management make targets do not exist.

### Uninstall

```bash
make uninstall
```

- Removes the installed binary (`~/.local/bin/clipline`) and stops the current user's process at that exact installed path, not copies elsewhere.
- Unloads and removes the daemon LaunchAgent (`~/Library/LaunchAgents/io.github.clipline.daemon.plist`) if present.
- Unsaved active pins and images parked on the clothesline are lost; PNGs already saved to disk are not removed.
- Preserves preferences (`defaults`) and macOS TCC permission entries.

## Usage

### 1. Capture and adjust crop in place

Use the configured capture shortcut (factory default `⌃X`) and drag to select a region. The screenshot stays pinned at the exact screen coordinates you selected.

Before moving the pin or selecting a drawing tool (at `100%` zoom), drag any of the 8 handles or 4 edges to expand or shrink the crop against the original full-screen frame.

### 2. Hang multiple pins on the clothesline

Press `P` (or click the clothespin icon) to park the current pin on the clothesline at the top of your screen:

- **Batch copy, stitch & save**: Click multiple thumbnails on the line and click **Copy** (or **Save**) to copy or export them as separate images, or click **Stitch** to seamlessly join them vertically into a single Retina-sharp image.
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

Use the full path `~/.local/bin/clipline` unless `~/.local/bin` is in your `PATH`:

```bash
~/.local/bin/clipline --capture     # start interactive region capture
~/.local/bin/clipline --clipboard   # pin current clipboard image
~/.local/bin/clipline --settings    # open shortcut settings (starts the daemon if needed)
~/.local/bin/clipline --shortcuts   # print current global shortcuts as JSON
```

The capture and clipboard commands trigger a running daemon. Shortcut settings persist in the `io.github.clipline` UserDefaults suite.
Carbon's exclusive registration detects conflicts with other exclusive Carbon hotkeys, but cannot detect every macOS, system, or app shortcut. If a binding does not work in a particular app, choose another one.

## Shortcuts

The table lists factory defaults; use **Keyboard Shortcuts** or `clipline --shortcuts` for your current bindings.

| Factory default | Context | Action |
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

On first capture, macOS prompts for **Screen Recording** permission. The prompt may appear either for `clipline` or for your host terminal application (e.g., Terminal or iTerm2):

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. Enable `clipline` (or your terminal application if prompted).
3. Restart the `clipline` process after granting permissions so the changes take effect.

> **Note**: Because binaries built without stable trusted code-signing identity may change signature across recompilations, updates may require re-approving permissions in System Settings.

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
make build      # compile release binary to ./build/clipline
make test       # run unit & AppKit checks (uses isolated shortcut settings, pasteboard, and temp directory)
make test-install # check scoped uninstall and reinstall in an isolated directory
make uninstall  # stop daemon and remove ~/.local/bin/clipline
make clean      # remove ./build
```

## Privacy & Security Notes

- **Mosaic is visual obfuscation**: Uses `CoreImage` `CIPixellate` (and falls back to an opaque dark fill if pixelation fails). For sensitive credentials or keys, crop them out or cover them with an opaque pen stroke.
- **Temporary files**: Writes `ClipLine_*.png` to `$TMPDIR/ClipLine` (`0700`) so file-paste and drag-and-drop work across Finder and chat apps. Files older than 1 hour are removed on daemon startup and on subsequent copy actions.
- **Local notifications**: When `fy-daemon` is running, OCR text is posted via `DistributedNotificationCenter` within the current macOS user session.

## License

[MIT](LICENSE)
