# NotchNotes

![NotchNotes 预览](docs/assets/readme-hero.png)

NotchNotes 是一款原生 macOS 刘海笔记应用。将鼠标移到或点击屏幕顶部，即可快速记录 Markdown 笔记、暂存文件或防止 Mac 自动休眠。

## 下载与安装

- [下载最新版](https://github.com/oil-oil/NotchNotes/releases/latest/download/NotchNotes.zip)
- [打开产品官网](https://oil-oil.github.io/NotchNotes/)

下载包同时支持 Apple Silicon 和 Intel，要求 macOS 14 或更高版本。

1. 解压 `NotchNotes.zip`，将 `NotchNotes.app` 移入“应用程序”。
2. 首次启动时右键点击应用，选择“打开”。
3. 如果 macOS 仍然拦截，请前往“系统设置 → 隐私与安全性”，点击“仍要打开”。

当前公开构建使用临时签名，尚未经过 Apple 公证，因此首次启动会出现安全提示。正式免提示分发需要 Developer ID Application 证书和 Apple 公证。

## 使用

启动后，将鼠标移到或点击屏幕顶部中央。可直接记录 Markdown 笔记；将文件拖入底部暂存区即可快速取用，再拖到 Finder、应用或网页上传区。暂存区只保留文件引用，不会移动或删除原文件。

- **胶囊标签栏与自动标题**：顶部单行可滚动胶囊标签栏会自动提取每篇笔记的首个 Markdown 标题（如 `# 今日待办`）作为标签名，无标题时回退到首行非空内容；支持悬停点击 `×` 关闭笔记，也可右键选择 `Restore Deleted Note` 恢复最近删除的笔记。
- **`/` 斜杠快捷菜单**：在行首或空格后输入 `/` 即可呼出插入菜单（一级至三级标题、待办/无序/有序列表、引用、代码块、分割线、今日日期、当前时间、链接），支持中英文关键词与语法符号实时过滤，`↑` / `↓` 切换、`Enter` / `Tab` 插入、`Esc` 仅关闭菜单而不收起刘海面板。
- **常用 Markdown 快捷键**：支持 `⌘B` 加粗、`⌘I` 斜体、`⌘E` 行内代码、`⌘K` 链接、`⇧⌘X` 删除线、`⇧⌘L` 待办清单、`⇧⌘U` 无序列表、`⇧⌘O` 有序列表、`⇧⌘'` 引用，以及 `⌥⌘1`–`⌥⌘3` 切换一至三级标题。
- **开机自启**：可在编辑器右下角齿轮菜单或菜单栏图标右键菜单中切换 `Launch at Login`（应用需位于 `/Applications`；若系统要求审批，前往“系统设置 → 通用 → 登录项与扩展”允许即可）。

如果顶部触发区影响菜单栏操作，可点击菜单栏的 NotchNotes 图标打开笔记，再在编辑器的齿轮菜单中选择 `Menu Bar Only`。此模式会隐藏顶部触发区，停用顶部悬停、点击和拖入唤起；点击菜单栏图标仍可打开笔记、使用文件暂存区，按 Esc 或 ⌘W 收起。设置会在重启后保留，也可随时切回 `Hover` 或 `Click`。

笔记和暂存记录保存在本机，不会因覆盖安装应用而删除。

点击咖啡杯可阻止自动休眠和合盖休眠，再点一次关闭。首次使用需要在“系统设置 → 通用 → 登录项与扩展”中允许 NotchNotes 的后台辅助服务，之后开关无需反复输入密码。应用须放在 `/Applications` 中运行。

关闭模式、退出应用或应用崩溃时，独立守护进程会恢复正常休眠。应用或辅助服务失去响应后，守护进程最多等待 8 秒续期便开始恢复；恢复失败会持续重试。辅助服务被强制结束或系统重启后，也会依据本机恢复标记清理遗留状态。关闭咖啡杯只是恢复原有的休眠策略，屏幕仍会按系统设定的时间熄灭。

## CLI 与 Agent Skill

在编辑器右下角齿轮菜单（或顶部菜单栏图标右键菜单）点击 `Install CLI Command…`，可将内置 `notch-notes` 命令链接到 `/usr/local/bin/notch-notes`（无写权限时自动回退至 `~/.local/bin/notch-notes`）；也可点击 `复制 Agent Skill 安装提示词` / `Copy Agent Skill Prompt` 复制安装提示词发给任意 AI Agent 自动完成配置。应用运行时通过私有 Unix Domain Socket 实时同步界面，未运行时通过文件锁安全读写本地 `notes.json`。

```bash
# 查看、读取与搜索笔记（所有命令均支持 --json）
notch-notes list --json
notch-notes get 1
notch-notes search "TODO"

# 新建、追加、更新与删除笔记
notch-notes add --text $'# 会议纪要\n- [ ] 跟进发布' --select
notch-notes append --active --text "- [ ] 补充测试"
notch-notes update "<uuid>" --text $'# 新标题\n正文'
notch-notes delete "<uuid>"

# 管理文件暂存区与控制刘海抽屉
notch-notes shelf list
notch-notes shelf add ./report.pdf
notch-notes panel toggle
```

`SKILL.md` 源码位于仓库 `Skills/notch-notes/SKILL.md`，并随应用打包内置在 `NotchNotes.app/Contents/Resources/Skills/notch-notes/SKILL.md`。可将其复制到 `~/.claude/skills/notch-notes/SKILL.md`、`~/.codex/skills/notch-notes/SKILL.md` 或 `~/.agents/skills/notch-notes/SKILL.md` 等技能目录（或直接点击菜单中的“复制 Agent Skill 安装提示词”交由 Agent 自动安装），供 Agent 按“先读后改”的安全规范读写刘海笔记与暂存文件。

## 本地运行

```bash
swift run NotchNotes
```

合盖不休眠需要打包后的应用和后台服务，`swift run` 仅用于其他功能的开发。

## 构建发布包

```bash
./Scripts/package-app.sh
open dist.noindex/NotchNotes.app
```

脚本会生成 Apple Silicon + Intel 通用应用、ZIP 附件和 SHA-256 校验文件。正式签名和公证时可设置：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="notary-profile" \
./Scripts/package-app.sh
```

## 自动发布

- 每次推送 `main`，GitHub Actions 会先运行测试，再构建通用应用，并自动覆盖 `latest` Release。
- 官网下载按钮固定指向 `releases/latest`，因此不需要手动修改下载地址。
- 推送 `v*` 版本标签时，仍会生成对应的版本快照 Release。
- 官网由 GitHub Pages 读取 `main` 分支的 `docs` 目录，页面修改推送后会自动部署。

如果测试或构建失败，Release 不会被覆盖，用户仍会下载上一份验证通过的版本。

## 技术栈

- Swift + AppKit：浮层、窗口层级、屏幕定位和顶部触发行为。
- SwiftUI：笔记和文件暂存界面。
- UserDefaults：轻量本地数据存储。
- MarkdownEngine：Markdown 编辑和内嵌图片。
