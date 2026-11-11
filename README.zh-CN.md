# ClipLine

[![CI](https://github.com/howtospellpizza/ClipLine/actions/workflows/ci.yml/badge.svg)](https://github.com/howtospellpizza/ClipLine/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

macOS 原生截图、标注与顶部“晾衣绳”贴图工具。

[English](README.md)

<p align="center">
  <img src="assets/demo.gif" alt="ClipLine 演示动画" width="760">
</p>

```
   ═══════🪵══════════════🪵══════════════🪵═══════
       ┌──────┐       ┌──────┐       ┌──────┐
       │ #1   │       │ #2   │       │ #3   │
       └──────┘       └──────┘       └──────┘
```

## 目录

- [核心功能与分步演示](#核心功能与分步演示)
  - [1. 智能窗口吸附、8× 放大镜取色与无损重裁](#1-智能窗口吸附8-放大镜取色与无损重裁)
  - [2. 贴图画布与 9 种标注工具](#2-贴图画布与-9-种标注工具)
  - [3. 离线 OCR、二维码自动复制剪贴板与翻译路由](#3-离线-ocr二维码自动复制剪贴板与翻译路由)
  - [4. 顶部晾衣绳：多图暂存、拖拽导出、纵/横向拼图与加边距衬底](#4-顶部晾衣绳多图暂存拖拽导出纵横向拼图与加边距衬底)
  - [5. 剪贴板图片或纯文本一键转便签贴图（`⌃⌘V`）](#5-剪贴板图片或纯文本一键转便签贴图v)
- [安装与快速开始](#安装与快速开始)
  - [源码安装](#源码安装)
  - [让 AI 助手帮你安装](#让-ai-助手帮你安装)
  - [更新与重新安装](#更新与重新安装)
  - [卸载](#卸载)
- [命令行与快捷键速查](#命令行与快捷键速查)
- [权限、配置与隐私说明](#权限配置与隐私说明)
- [开发与测试](#开发与测试)

---

## 核心功能与分步演示

### 1. 智能窗口吸附、8× 放大镜取色与无损重裁

使用全局截图快捷键（出厂默认 `⌃X`，备用 `⌘⇧X`）：

- **单击智能吸附窗口**：鼠标悬停在任意可见窗口（包括台前调度左侧缩略图）上会自动高亮识别边界，**直接单击**即可一键截取完整窗口。
- **自由框选与一键截全屏**：按住鼠标拖拽截取自定义区域；进入截图模式后按 **`Space`（空格键）** 或 **`⌘A`** 即可直接截取整张屏幕。
- **放大镜与 HEX 取色器**：悬停时实时显示坐标与 `8×` 像素放大镜，按 **`C`** 即可直接复制当前像素的 `#RRGGBB` 色值并退出截图；可在快捷键设置（`⌘,`）中切换准星样式（全屏十字线、四角取景框、极简圆点）与配色。
- **原地贴图与边缘无损重裁**：截图完成后直接停留在所选屏幕坐标处。在移动窗口或选择标注工具前（`100%` 缩放比例下），拖拽四周的 8 个圆点或 4 条边，可基于原始全屏画面继续放大或缩小裁剪范围。

<details>
<summary>🎬 <b>查看演示：单击窗口智能吸附、8× HEX 像素取色器与边缘无损重裁</b></summary>
<br>
<p align="center">
  <img src="assets/demo-capture-snap.gif" alt="单击窗口智能吸附、HEX 像素取色器与边缘无损重裁演示" width="760">
</p>
</details>

---

### 2. 贴图画布与 9 种标注工具

截图固定在屏幕后，可通过底部悬浮工具栏添加标注；点击画布上已绘制的任意标注即可移动位置、修改颜色/粗细、拖拽四角控制点无级缩放，或按 `Delete` / `⌫` 删除（支持 `⌘Z` 多步撤销）：

| 工具 | 功能亮点 |
| :--- | :--- |
| **矩形与箭头** | 按住 `Shift` 锁定 `1:1` 正方形或 `45°` 方向箭头；支持 `细` / `中` / `粗` 三档尺寸与 6 种颜色。 |
| **聚光灯（Spotlight）** | 框选重点区域并自动压暗外部画面（`56%` 暗色遮罩 + 高亮白框）；多个聚光灯共享同一层暗色背景，选中后可拖拽 **四角控制点** 自由调整范围。 |
| **画笔与荧光笔** | 自由手绘曲线与正片叠底（`.multiply`）半透明荧光笔，高亮代码与文字时不遮挡原字。 |
| **递增序号章（`① ② ③…`）** | 点击即可连续放置递增数字标号；选中后可拖拽四角控制点无级缩放尺寸。 |
| **像素马赛克（`CIPixellate`）** | 原地框选打码遮挡敏感信息。 |
| **文字（`Aa`）** | 支持透明底、黑底圆角、白底圆角背景；双击已提交文字可原地重编辑，拖拽四角控制点可自由缩放字号。 |
| **Emoji 贴图（`😊`）** | 内置常用表情快捷栏，也可一键唤起 macOS「表情与符号」面板（`⌃⌘Space`），放置后拖拽四角控制点自由调节大小。 |

<details open>
<summary>🎬 <b>查看演示：聚光灯（Spotlight）重点遮罩与四角无级缩放</b></summary>
<br>
<p align="center">
  <img src="assets/demo-spotlight.gif" alt="聚光灯标注重点区域并压暗选区外的画面" width="760">
</p>
</details>

<details>
<summary>🎬 <b>查看演示：像素马赛克打码与正片叠底荧光笔</b></summary>
<br>
<p align="center">
  <img src="assets/demo-mosaic-highlight.gif" alt="像素马赛克打码与半透明荧光笔标注演示" width="760">
</p>
</details>

<details>
<summary>🎬 <b>查看演示：快捷 Emoji 贴图、系统表情面板与四角无级缩放</b></summary>
<br>
<p align="center">
  <img src="assets/demo-emoji-stickers.gif" alt="Emoji 贴图放置与四角控制点无级缩放演示" width="760">
</p>
</details>

---

### 3. 离线 OCR、二维码自动复制剪贴板与翻译路由

- **离线 OCR（`O`）**：使用 macOS `Vision` 离线识别简繁中文与英文，直接复制到剪贴板。
- **二维码 / 条形码识别（`Q`）**：使用 `VNDetectBarcodesRequest` 离线解码截图中的二维码与条形码，**识别后立即将内容自动复制到剪贴板**；若内容为 `http`/`https` 链接，还会弹窗询问「仅复制，不打开」或「打开链接」。
- **翻译路由（`T`）**：对合成后的图像执行 OCR，并按以下顺序发送识别文本：
  1. 本地翻译进程（默认检测 `gloss-daemon`，可通过 `CLIP_LINE_TRANSLATE_DAEMON` 指定）
  2. 自定义翻译 URL 模板（`CLIP_LINE_TRANSLATE_URL`）
  3. macOS 系统翻译服务
  4. 默认浏览器网页翻译（每个外部域名首次打开前会弹窗确认）

<details open>
<summary>🎬 <b>查看演示：递增序号章、框选标注与二维码识别自动复制到剪贴板</b></summary>
<br>
<p align="center">
  <img src="assets/demo-annotate-qr.gif" alt="递增序号章、框选箭头标注与离线二维码识别自动复制到剪贴板演示" width="760">
</p>
</details>

---

### 4. 顶部晾衣绳：多图暂存、拖拽导出、纵/横向拼图与加边距衬底

按 `P` / `Tab`（或点击工具栏上的 **木夹图标 Clip**）把当前贴图挂到屏幕顶部的晾衣绳（双击任意缩略图即可取回画布继续编辑）：

- **多图一并拖拽导出**：直接按住已选中的缩略图即可**将当前选中的多张图片一起拖入**微信、Slack、浏览器或 Finder（拖未选中的图片则仅导出该张）；按住顶部绳索可自由移动晾衣绳位置。
- **批量复制、纵向拼长图（`Stitch`）与横向并排拼图（`Side`）**：点选多张缩略图后，点击 **复制** 可作为多张独立图片写入剪贴板；点击 **拼长图 / Stitch**（上下纵向）或 **横向拼 / Side**（左右并排）可将多张图拼接为一张 Retina 原生高清图并自动复制到剪贴板。
- **深色加边距衬底（`Frame`）**：开启控制栏底部的 **加边距 / Frame** 开关，下次复制或拼图时会自动包裹深色渐变衬底、圆角阴影与均匀内边距。

<details>
<summary>🎬 <b>查看演示：挂上顶部晾衣绳并一并拖入 Slack 聊天窗口</b></summary>
<br>
<p align="center">
  <img src="assets/demo-clothesline-drag.gif" alt="将多张贴图挂上晾衣绳并一并拖入 Slack" width="760">
</p>
</details>

<details open>
<summary>🎬 <b>查看演示：纵向拼长图（Stitch）、横向并排拼图（Side）与深色加边距衬底（Frame）</b></summary>
<br>
<p align="center">
  <img src="assets/demo-clothesline-stitch.gif" alt="纵向拼长图、横向并排拼图与开启加边距衬底演示" width="760">
</p>
</details>

---

### 5. 剪贴板图片或纯文本一键转便签贴图（`⌃⌘V`）

在任意应用中按 `⌃⌘V`（或运行 `~/.local/bin/clipline --clipboard`）：

- **当剪贴板为图片时**：直接将该图片作为贴图窗口固定在屏幕上。
- **当剪贴板为纯文本或代码时**：先用 `⌘C` 复制任意文本或代码片段，再按 `⌃⌘V`，即可将其渲染为高清 **黄色便签贴图卡片**（最多显示 60 行并自动附带省略提示），同样支持荧光笔高亮、画笔标注、OCR 与挂上顶部晾衣绳。

<details open>
<summary>🎬 <b>查看演示：先复制代码文本（<code>⌘C</code>）→ 按 <code>⌃⌘V</code> 变成可标注的黄色便签贴图</b></summary>
<br>
<p align="center">
  <img src="assets/demo-clipboard-text.gif" alt="先用 Cmd+C 复制纯文本再用 Ctrl+Cmd+V 贴成便签卡片的演示" width="760">
</p>
</details>

---

## 安装与快速开始

### 前置要求

- 项目配置了 macOS 14+ 部署目标（已在维护者当前机器上通过运行时验证；macOS 14 与 Intel 架构运行兼容性未经独立完整验证）。
- Swift 5.9+ 命令行工具（`xcode-select --install`）。如弹出安装提示，请等待工具安装完成后再继续。

### 源码安装

```bash
git clone https://github.com/howtospellpizza/ClipLine.git
cd ClipLine
make install
nohup ~/.local/bin/clipline >"$HOME/Library/Logs/clipline.log" 2>&1 &
```

> **注意**：该命令会在当前会话后台启动 `clipline`，不会自动注册登录项，亦不保证开机自启。

点击截图工具栏右侧的键盘图标 `⌨️`（或在贴图窗口按 `⌘,`，或运行 `~/.local/bin/clipline --settings`），即可查看或编辑全部全局快捷键。出厂默认值：`⌃X` 框选截图，`⌘⇧X` 为备用截图快捷键，`⌃⌘V` 将剪贴板图片或纯文本便签贴到屏幕上。

### 让 AI 助手帮你安装

将以下提示词复制给 Claude Code、OpenCode、Cursor 或 Codex：

```text
请参照仓库 README 帮我安装 ClipLine（https://github.com/howtospellpizza/ClipLine）：
1. 检查当前环境是否满足 macOS 14+ 与 Swift 5.9+ 命令行工具（`swiftc --version`）。
2. 若检测到已有 `~/.local/bin/clipline`、正在运行的 `clipline` 进程或本地仓库修改，请先向我确认，不要直接覆盖、卸载或删除。
3. 克隆仓库并执行 `make install`，随后在后台启动守护进程（`nohup ~/.local/bin/clipline >"$HOME/Library/Logs/clipline.log" 2>&1 &`）。除非我明确要求，不要自动注册 LaunchAgent 或开机登录项。
4. 运行 `~/.local/bin/clipline --help`、`~/.local/bin/clipline --shortcuts`，并检查 `pgrep -x clipline` 与 `$HOME/Library/Logs/clipline.log` 验证安装结果。
5. 提醒我前往「系统设置 → 隐私与安全性 → 录屏与系统录音」手动开启屏幕录制权限，并按一次 `⌃X` 测试截图与复制（macOS TCC 权限无法由脚本自动绕过）。
```

### 更新与重新安装

从官方 `main` 分支更新当前运行的二进制文件：

```bash
~/.local/bin/clipline --update
```

更新器会下载一份全新的临时仓库副本，先完成编译，再替换当前调用的二进制文件，不会修改本地仓库。更新需要连接 GitHub 下载公开源码；ClipLine 不会上传截图、剪贴板内容或偏好设置。

- 如果现有安装使用证书签名，只有在可用原签名身份时才会更新。否则，更新器会在替换二进制文件前停止并给出说明；它不会删除 macOS 权限设置。Ad-hoc 签名的版本更新后可能需要重新授权屏幕录制。
- 如果已注册的 LaunchAgent 确实指向当前二进制文件，更新器会重启该任务，但不会新建 LaunchAgent。否则，只有检测到相同可执行文件路径的守护进程正在运行时，才会停止并重启该进程；新进程使用更新器当前的环境变量，无法恢复仅存在于旧进程中的环境变量。
- 活动贴图尚未保存，守护进程重启时可能丢失。更新前请先保存重要内容。如果没有匹配的运行中守护进程或 LaunchAgent，更新器不会启动应用。

`make install` 仅用于本地编译并复制：它会构建 `build/clipline`，再复制到 `~/.local/bin/clipline`。它不会对二进制文件签名、停止或重启守护进程，也不会注册或管理 LaunchAgent。也可以从本地仓库更新：

```bash
cd /path/to/ClipLine
git pull --ff-only
make build
make install
```

- 若 `git pull --ff-only` 因本地修改报错，请先处理工作区改动后再更新。
- 保存活动贴图后，请手动重启守护进程；`make install` 不会重启它。
- `clipline --update` 是命令行功能；Makefile 中不存在 `make update`、`make version` 或服务管理相关的 target。

### 卸载

```bash
make uninstall
```

- 移除已安装的二进制文件（`~/.local/bin/clipline`），仅停止当前用户在该安装路径运行的进程，不影响其他路径下的副本。
- 卸载并删除 LaunchAgent 文件（`~/Library/LaunchAgents/io.github.clipline.daemon.plist`，如果存在）。
- 未保存的贴图和晾衣绳中的图片会丢失；已保存到磁盘的 PNG 文件不会删除。
- 保留系统偏好设置（`defaults`）与 macOS TCC 权限授权记录。

---

## 命令行与快捷键速查

### 命令行参数

除非已将 `~/.local/bin` 加入 `PATH`，请使用完整路径 `~/.local/bin/clipline`：

```bash
~/.local/bin/clipline --capture     # 启动框选截图
~/.local/bin/clipline --clipboard   # 将剪贴板中的图片（或纯文本便签卡片）贴到屏幕上
~/.local/bin/clipline --settings    # 打开快捷键设置（必要时启动守护进程）
~/.local/bin/clipline --shortcuts   # 以 JSON 输出当前全局快捷键
~/.local/bin/clipline --update      # 从官方 main 更新当前调用的二进制文件
```

截图与剪贴板命令会触发正在运行的守护进程。快捷键设置保存在 `io.github.clipline` UserDefaults 套件中。
Carbon 独占注册只能检测其他使用独占 Carbon 注册的快捷键冲突，无法识别所有 macOS、系统或应用快捷键。如果某个快捷键在特定应用中不起作用，请改用其他组合。

### 快捷键一览

下表列出出厂默认值；请在**键盘快捷键**设置（`⌘,`）中查看当前绑定，或运行 `clipline --shortcuts`。

| 出厂默认值 | 场景 | 功能 |
| :--- | :--- | :--- |
| `⌃X` | 全局 | 框选截图 |
| `⌘⇧X` | 全局 | 框选截图（备用快捷键） |
| `⌃⌘V` | 全局 | 将剪贴板图片（或纯文本便签）贴到屏幕 |
| `Space` / `⌘A` | 截图模式 | 一键截取全屏 |
| `C` | 截图模式 | 复制当前悬停像素的 `#RRGGBB` 色值并退出截图 |
| `↩` (`Return`) | 贴图窗口 | 复制合成图片并关闭贴图 |
| `⌘C` | 贴图窗口 | 复制合成图片（保留贴图窗口） |
| `⌘S` | 贴图窗口 | 保存为 PNG |
| `P` / `⇥` (`Tab`) | 贴图窗口 | 挂到顶部晾衣绳 |
| `O` | 贴图窗口 | OCR 识别文字并复制 |
| `Q` | 贴图窗口 | 识别二维码 / 条形码并复制 |
| `T` | 贴图窗口 | OCR 识别并翻译 |
| `⌫` / `Delete` | 贴图窗口 | 删除当前选中的标注 |
| `Space` | 贴图窗口 | 显示 / 隐藏工具栏 |
| `⌘Z` | 贴图窗口 | 撤销上一步标注 |
| `+` / `-` | 贴图窗口 | 缩放贴图（`35%` – `300%`） |
| `⌥` + 滚轮 | 贴图窗口 | 调节透明度（`25%` – `100%`） |
| `⎋` (`Esc`) | 选区 / 贴图 | 取消截图、退出文字编辑或关闭贴图（不修改剪贴板） |

---

## 权限、配置与隐私说明

### 权限设置

首次截图时，macOS 会请求 **屏幕录制** 权限。授权提示可能针对 `clipline` 或你当前使用的终端软件（如 Terminal、iTerm2）：

1. 打开 **系统设置 → Privacy & Security（隐私与安全性）→ 录屏与系统录音**。
2. 勾选启用 `clipline`（若提示的是终端软件，则启用对应的终端）。
3. 授权后请重启 `clipline` 进程，使权限变更生效。

> **注意**：更新器会在可用时复用现有证书签名身份与标识。Ad-hoc 签名的版本更新后，可能需要在系统设置中重新授权屏幕录制。

### 配置项

| 环境变量 / 配置键 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `CLIP_LINE_LANG` | 自动跟随系统语言 | 界面语言覆盖（支持 `en` 或 `zh-Hans`） |
| `CLIP_LINE_TRANSLATE_TARGET` | `zh-CN`（中文界面）/ `en`（英文界面） | 内置网页翻译的目标语言代码（`tl` 参数） |
| `CLIP_LINE_TRANSLATE_URL` | 未设置 | 自定义 HTTPS（或 `localhost` HTTP）翻译 URL 模板，使用 `{text}` 占位符 |
| `TranslateURLTemplate` (`NSGlobalDomain`) | 未设置 | `CLIP_LINE_TRANSLATE_URL` 的 `defaults write` 持久化配置项 |
| `CLIP_LINE_TRANSLATE_DAEMON` | `gloss-daemon` | 本地翻译守护进程名 |
| `CLIP_LINE_TRANSLATE_CHANNEL` | `io.github.clipline.translate` | 本地翻译分布式通知通道 |
| `CLIP_LINE_CAPTURE_CHANNEL` | `io.github.clipline.capture` | 外部触发截图的分布式通知通道 |

配置自定义翻译网址示例：

```bash
export CLIP_LINE_TRANSLATE_URL="https://www.deepl.com/translator#en/zh/{text}"
```

### 隐私与安全说明

- **马赛克属于视觉遮挡**：使用 `CoreImage` 的 `CIPixellate` 像素化（若渲染异常则回退为不透明深色实心块）。如需处理密钥或密码等高敏感内容，请直接裁剪剔除或使用不透明画笔覆盖。
- **临时文件**：为支持 Finder/Slack 文件粘贴与拖拽导出，程序会在 `$TMPDIR/ClipLine`（权限 `0700`）写入 `ClipLine_*.png`。超过 1 小时的旧文件会在进程启动和后续复制时清理。
- **本地通知**：当检测到 `gloss-daemon` 运行时，OCR 文本会通过当前登录用户会话内的 `DistributedNotificationCenter` 发送。

---

## 开发与测试

```bash
make build        # 编译 Release 二进制文件到 ./build/clipline
make test         # 运行单元与 AppKit 回归检查（使用独立快捷键设置、剪贴板与临时目录）
make test-install # 在隔离目录中验证卸载与重装流程
make uninstall    # 停止守护进程并移除 ~/.local/bin/clipline
make clean        # 清理 ./build
```

## 许可证

[MIT](LICENSE)
