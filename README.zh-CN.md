# ClipLine

macOS 原生截图、标注与顶部“晾衣绳”贴图工具。

[English](README.md)

```
   ═══════🪵══════════════🪵══════════════🪵═══════
       ┌──────┐       ┌──────┐       ┌──────┐
       │ #1   │       │ #2   │       │ #3   │
       └──────┘       └──────┘       └──────┘
```

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

点击截图工具栏右侧的键盘图标 `⌨️`（或在贴图窗口按 `⌘,`，或运行 `~/.local/bin/clipline --settings`），即可查看或编辑全部全局快捷键。出厂默认值：`⌃X` 框选截图，`⌘⇧X` 为备用截图快捷键，`⌃⌘V` 将剪贴板图片贴到屏幕上。

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

从本地仓库更新代码：

```bash
cd /path/to/ClipLine
git pull --ff-only
make build
make uninstall
make install
nohup ~/.local/bin/clipline >"$HOME/Library/Logs/clipline.log" 2>&1 &
```

- 若 `git pull --ff-only` 因本地修改报错，请先处理工作区改动后再更新。
- 务必在 `make uninstall` 之前先执行 `make build`，确保编译失败时原有可用版本不受影响。
- Makefile 中不存在 `make update`、`make version` 或服务管理相关的 target。

### 卸载

```bash
make uninstall
```

- 移除已安装的二进制文件（`~/.local/bin/clipline`），仅停止当前用户在该安装路径运行的进程，不影响其他路径下的副本。
- 卸载并删除 LaunchAgent 文件（`~/Library/LaunchAgents/io.github.clipline.daemon.plist`，如果存在）。
- 未保存的贴图和晾衣绳中的图片会丢失；已保存到磁盘的 PNG 文件不会删除。
- 保留系统偏好设置（`defaults`）与 macOS TCC 权限授权记录。

## 基本用法

### 1. 原地贴图与裁剪微调

使用已配置的截图快捷键（出厂默认值为 `⌃X`）框选区域后，贴图会直接停留在所选的屏幕坐标处。

在移动窗口或选择标注工具前（`100%` 缩放比例下），拖拽四周的 8 个圆点或 4 条边，可基于原始全屏画面继续放大或缩小裁剪范围。

### 2. 晾衣绳多图暂存

按 `P`（或点击工具栏上的木夹图标）把当前贴图挂到屏幕顶部的晾衣绳：

- **多图批量复制、无缝拼长图与导出**：在晾衣绳上点选多张缩略图，点击 **复制** 可作为多张独立图片写入剪贴板；点击 **拼长图** 可将多张图无缝纵向拼接为一张 Retina 原生高清长图并复制；也可点击下载图标批量保存到文件夹。
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

除非已将 `~/.local/bin` 加入 `PATH`，请使用完整路径 `~/.local/bin/clipline`：

```bash
~/.local/bin/clipline --capture     # 启动框选截图
~/.local/bin/clipline --clipboard   # 将剪贴板中的图片贴到屏幕上
~/.local/bin/clipline --settings    # 打开快捷键设置（必要时启动守护进程）
~/.local/bin/clipline --shortcuts   # 以 JSON 输出当前全局快捷键
```

截图与剪贴板命令会触发正在运行的守护进程。快捷键设置保存在 `io.github.clipline` UserDefaults 套件中。
Carbon 独占注册只能检测其他使用独占 Carbon 注册的快捷键冲突，无法识别所有 macOS、系统或应用快捷键。如果某个快捷键在特定应用中不起作用，请改用其他组合。

## 快捷键

下表列出出厂默认值；请在**键盘快捷键**设置中查看当前绑定，或运行 `clipline --shortcuts`。

| 出厂默认值 | 场景 | 功能 |
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

首次截图时，macOS 会请求 **屏幕录制** 权限。授权提示可能针对 `clipline` 或你当前使用的终端软件（如 Terminal、iTerm2）：

1. 打开 **系统设置 → 隐私与安全性 → 录屏与系统录音**。
2. 勾选启用 `clipline`（若提示的是终端软件，则启用对应的终端）。
3. 授权后请重启 `clipline` 进程，使权限变更生效。

> **注意**：由于未配置受信任的稳定代码签名，重新编译可能会变更签名标识，更新后可能需要在系统设置中重新授权。

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
make test       # 运行单元与 AppKit 回归检查（使用独立快捷键设置、剪贴板与临时目录）
make test-install # 在隔离目录中验证卸载与重装流程
make uninstall  # 停止守护进程并移除 ~/.local/bin/clipline
make clean      # 清理 ./build
```

## 隐私与安全说明

- **马赛克属于视觉遮挡**：使用 `CoreImage` 的 `CIPixellate` 像素化（若渲染异常则回退为不透明深色实心块）。如需处理密钥或密码等高敏感内容，请直接裁剪剔除或使用不透明画笔覆盖。
- **临时文件**：为支持 Finder/Slack 文件粘贴与拖拽导出，程序会在 `$TMPDIR/ClipLine`（权限 `0700`）写入 `ClipLine_*.png`。超过 1 小时的旧文件会在进程启动和后续复制时清理。
- **本地通知**：当检测到 `fy-daemon` 运行时，OCR 文本会通过当前登录用户会话内的 `DistributedNotificationCenter` 发送。

## 许可证

[MIT](LICENSE)
