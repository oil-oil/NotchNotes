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

启动后，将鼠标移到或点击屏幕顶部中央。可直接记录 Markdown 笔记；将文件拖入底部暂存区即可快速取用，按住 Command 拖入时会移动原文件。

笔记和暂存记录保存在本机，不会因覆盖安装应用而删除。

## 本地运行

```bash
swift run NotchNotes
```

## 构建发布包

```bash
./Scripts/package-app.sh
open dist/NotchNotes.app
```

脚本会生成 Apple Silicon + Intel 通用应用、ZIP 附件和 SHA-256 校验文件。正式签名和公证时可设置：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE="notary-profile" \
./Scripts/package-app.sh
```

## 技术栈

- Swift + AppKit：浮层、窗口层级、屏幕定位和顶部触发行为。
- SwiftUI：笔记和文件暂存界面。
- UserDefaults：轻量本地数据存储。
- MarkdownEngine：Markdown 编辑和内嵌图片。
