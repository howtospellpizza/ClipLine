# ClipLine

macOS 原生截图、标注与顶部“晾衣绳”贴图工具。

[English](README.md)

```
   ═══════🪵══════════════🪵══════════════🪵═══════
       ┌──────┐       ┌──────┐       ┌──────┐
       │ #1   │       │ #2   │       │ #3   │
       └──────┘       └──────┘       └──────┘
```

## 快速开始

需要 macOS 14+ 与 Xcode Command Line Tools（`xcode-select --install`），无第三方依赖。

```bash
make install
~/.local/bin/clipline &
```

按 `⌃X`（`Control + X`）框选截图，再按 `P` 即可用小木夹将贴图挂到屏幕顶部的晾衣绳上。

## 基本用法

### 1. 原地贴图与裁剪微调

按 `⌃X` 框选区域后，贴图会直接停留在所选的屏幕坐标处。

在移动窗口或选择标注工具前（`100%` 缩放比例下），拖拽四周的 8 个圆点或 4 条边，可基于原始全屏画面继续放大或缩小裁剪范围。

### 2. 晾衣绳多图暂存

按 `P`（或点击工具栏上的木夹图标）把当前贴图挂到屏幕顶部的晾衣绳：

- **拼接复制**：在晾衣绳上点选多张缩略图，点击 **复制** 即可纵向拼合为一张图片写入剪贴板。
- **拖拽导出**：直接按住缩略图拖入 Slack、浏览器或 Finder。
- **取回编辑**：双击任意缩略图即可取回画布继续编辑。

### 3. 标注、OCR 与翻译

- **标注工具**：矩形、箭头、画笔、文字、像素马赛克（`CIPixellate`），提供 `细` / `中` / `粗` 三档尺寸与 6 种颜色。
- **文字编辑**：支持透明底、黑底圆角、白底圆角背景。输入时按住文字框任意位置即可拖动；双击已提交的文字可原地重编辑。
- **离线 OCR（`O`）**：使用 macOS `Vision` 离线识别简繁中文与英文，并复制到剪贴板。
- **翻译路由（`T`）**：对合成后的图像执行 OCR，并按以下顺序发送识别文本：
  1. 本地翻译进程（默认检测 `fy-daemon`，可通过 `CLIP_LINE_TRANSLATE_DAEMON` 指定）
  2. 自定义翻译 URL 模板（`CLIP_LINE_TRANSLATE_URL`）
  3. macOS 系统翻译服务
  4. 默认浏览器网页翻译（每个外部域名首次打开前会弹窗确认）

### 4. 命令行触发

守护进程运行时，也可通过终端或脚本触发：

```bash
clipline --capture     # 启动框选截图
clipline --clipboard   # 将剪贴板中的图片贴到屏幕上
```

## 快捷键

| 快捷键 | 场景 | 功能 |
| :--- | :--- | :--- |
| `⌃X` | 全局 | 框选截图 |
| `⌘⇧X` | 全局 | 框选截图（备用快捷键） |
| `⌃⌘V` | 全局 | 将剪贴板图片贴到屏幕 |
| `↩` (`Return`) | 贴图窗口 | 复制合成图片并关闭贴图 |
| `⌘C` | 贴图窗口 | 复制合成图片（保留贴图窗口） |
| `⌘S` | 贴图窗口 | 保存为 PNG |
| `P` / `⇥` (`Tab`) | 贴图窗口 | 挂到顶部晾衣绳 |
| `O` | 贴图窗口 | OCR 识别文字并复制 |
| `T` | 贴图窗口 | OCR 识别并翻译 |
| `Space` | 贴图窗口 | 显示 / 隐藏工具栏 |
| `⌘Z` | 贴图窗口 | 撤销上一步标注 |
| `+` / `-` | 贴图窗口 | 缩放贴图（`35%` – `300%`） |
| `⌥` + 滚轮 | 贴图窗口 | 调节透明度（`25%` – `100%`） |
| `⎋` (`Esc`) | 选区 / 贴图 | 取消截图、退出文字编辑或关闭贴图（不修改剪贴板） |

## 权限设置

首次截图时，macOS 会请求 **屏幕录制** 权限：

1. 打开 **系统设置 → 隐私与安全性 → 录屏与系统录音**。
2. 勾选启用 `clipline`。

## 配置项

| 环境变量 / 配置键 | 默认值 | 说明 |
| :--- | :--- | :--- |
| `CLIP_LINE_LANG` | 自动跟随系统语言 | 界面语言覆盖（支持 `en` 或 `zh-Hans`） |
| `CLIP_LINE_TRANSLATE_TARGET` | `zh-CN`（中文界面）/ `en`（英文界面） | 内置网页翻译的目标语言代码（`tl` 参数） |
| `CLIP_LINE_TRANSLATE_URL` | 未设置 | 自定义 HTTPS（或 `localhost` HTTP）翻译 URL 模板，使用 `{text}` 占位符 |
| `TranslateURLTemplate` (`NSGlobalDomain`) | 未设置 | `CLIP_LINE_TRANSLATE_URL` 的 `defaults write` 持久化配置项 |
| `CLIP_LINE_TRANSLATE_DAEMON` | `fy-daemon` | 本地翻译守护进程名 |
| `CLIP_LINE_TRANSLATE_CHANNEL` | `io.github.clipline.translate` | 本地翻译分布式通知通道 |
| `CLIP_LINE_CAPTURE_CHANNEL` | `io.github.clipline.capture` | 外部触发截图的分布式通知通道 |

配置自定义翻译网址示例：

```bash
export CLIP_LINE_TRANSLATE_URL="https://www.deepl.com/translator#en/zh/{text}"
```

## 开发与测试

```bash
make build      # 编译 Release 二进制文件到 ./build/clipline
make test       # 运行 86 项单元与 AppKit 回归检查（使用独立剪贴板与临时目录）
make uninstall  # 停止守护进程并移除 ~/.local/bin/clipline
make clean      # 清理 ./build
```

## 隐私与安全说明

- **马赛克属于视觉遮挡**：使用 `CoreImage` 的 `CIPixellate` 像素化（若渲染异常则回退为不透明深色实心块）。如需处理密钥或密码等高敏感内容，请直接裁剪剔除或使用不透明画笔覆盖。
- **临时文件**：为支持 Finder/Slack 文件粘贴与拖拽导出，程序会在 `$TMPDIR/ClipLine`（权限 `0700`）写入 `ClipLine_*.png`。超过 1 小时的旧文件会在进程启动和后续复制时清理。
- **本地通知**：当检测到 `fy-daemon` 运行时，OCR 文本会通过当前登录用户会话内的 `DistributedNotificationCenter` 发送。

## 许可证

[MIT](LICENSE)
