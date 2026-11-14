import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Sendable, Identifiable {
    case chinese = "zh-Hans"
    case english = "en"

    public var id: String { rawValue }

    /// Always shown in the language's own native script so users can switch
    /// back regardless of which language is currently active.
    public var nativeDisplayName: String {
        switch self {
        case .chinese:
            return "简体中文"
        case .english:
            return "English"
        }
    }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public static func defaultLanguage(forPreferredLanguages preferredLanguages: [String]) -> AppLanguage {
        guard let first = preferredLanguages.first?.lowercased() else {
            return .english
        }
        return first.hasPrefix("zh") ? .chinese : .english
    }
}

struct AppStrings: Sendable {
    let language: AppLanguage

    private var isChinese: Bool {
        language == .chinese
    }

    // MARK: - Settings Menu & Trigger Modes

    var settings: String {
        isChinese ? "设置" : "Settings"
    }

    func openTriggerHeader(_ modeTitle: String) -> String {
        isChinese ? "打开方式 · \(modeTitle)" : "Open NotchNotes · \(modeTitle)"
    }

    func triggerModeTitle(_ mode: TriggerMode) -> String {
        switch mode {
        case .hover:
            return isChinese ? "悬停" : "Hover"
        case .click:
            return isChinese ? "点击" : "Click"
        case .menuBar:
            return isChinese ? "仅菜单栏" : "Menu Bar Only"
        }
    }

    func displayHeader(_ displayTitle: String) -> String {
        isChinese ? "显示器 · \(displayTitle)" : "Display · \(displayTitle)"
    }

    var automaticDisplay: String {
        isChinese ? "自动" : "Automatic"
    }

    var builtInDisplay: String {
        isChinese ? "内建显示器" : "Built-in Display"
    }

    var languageHeader: String {
        isChinese ? "语言 · \(language.nativeDisplayName)" : "Language · \(language.nativeDisplayName)"
    }

    var languageMenuTitle: String {
        isChinese ? "语言" : "Language"
    }

    var launchAtLogin: String {
        isChinese ? "开机自启" : "Launch at Login"
    }

    var installCLICommand: String {
        isChinese ? "安装 CLI 命令…" : "Install CLI Command…"
    }

    var copyAgentSkillPrompt: String {
        isChinese ? "复制 Agent Skill 安装提示词" : "Copy Agent Skill Prompt"
    }

    var quitNotchNotes: String {
        isChinese ? "退出 NotchNotes" : "Quit NotchNotes"
    }

    // MARK: - Alerts & System Actions

    var openSystemSettings: String {
        isChinese ? "打开系统设置" : "Open System Settings"
    }

    var ok: String {
        isChinese ? "好" : "OK"
    }

    var couldNotUpdateLaunchAtLoginTitle: String {
        isChinese ? "无法更新开机自启设置" : "Couldn’t Update Launch at Login"
    }

    var cliInstalledTitle: String {
        isChinese ? "CLI 命令已安装" : "CLI Command Installed"
    }

    var couldNotInstallCLITitle: String {
        isChinese ? "无法安装 CLI 命令" : "Couldn’t Install CLI Command"
    }

    var agentSkillPromptCopiedTitle: String {
        isChinese ? "已复制 Agent 安装提示词" : "Agent Skill Prompt Copied"
    }

    var agentSkillPromptCopiedMessage: String {
        isChinese
            ? "安装提示词已复制到剪贴板。直接粘贴发给你的 AI Agent（如 Claude Code、Codex、Cursor 等），即可自动完成 CLI 与 NotchNotes Skill 配置。"
            : "The setup prompt has been copied to your clipboard. Paste and send it to your AI agent (Claude Code, Codex, Cursor, etc.) to install and configure the NotchNotes CLI and Skill automatically."
    }

    func cliInstallSuccessMessage(for result: CLIInstallResult) -> String {
        guard isChinese else {
            return result.message
        }
        if result.isInPATH || !result.usedLocalBinFallback {
            return "已将 '\(CLIInstaller.binaryName)' 安装到 \(result.destinationURL.path)。可在终端运行 'notch-notes --help' 验证。"
        }
        return """
        已将 '\(CLIInstaller.binaryName)' 安装到 \(result.destinationURL.path)。

        将 ~/.local/bin 加入 PATH 后即可在任意位置运行 'notch-notes'：
        export PATH="$HOME/.local/bin:$PATH"
        """
    }

    func cliInstallErrorMessage(for error: Error) -> String {
        if isChinese, let installerError = error as? CLIInstallerError {
            switch installerError {
            case let .bundledBinaryNotFound(path):
                return "未找到内置的 notch-notes 可执行文件：\(path)"
            case let .existingFileIsNotSymlink(path):
                return "\(path) 已存在非软链文件，请先移除或重命名该文件。"
            case let .symlinkCreationFailed(reason):
                return "创建 notch-notes 软链失败：\(reason)"
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Keep Awake & Error Copy

    var couldNotKeepMacAwakeTitle: String {
        isChinese ? "无法开启防休眠" : "Couldn’t Keep Mac Awake"
    }

    var changingKeepAwake: String {
        isChinese ? "正在切换防休眠模式…" : "Changing keep-awake mode…"
    }

    var stopKeepingAwake: String {
        isChinese ? "停止防休眠" : "Stop keeping Mac awake"
    }

    var keepMacAwake: String {
        isChinese ? "保持 Mac 唤醒（支持合盖不休眠）" : "Keep Mac awake, even with the lid closed"
    }

    var accessibilityOn: String {
        isChinese ? "开启" : "On"
    }

    var accessibilityOff: String {
        isChinese ? "关闭" : "Off"
    }

    func launchAtLoginErrorMessage(_ error: LaunchAtLoginError) -> String {
        switch error {
        case .approvalRequired:
            return isChinese
                ? "请在“系统设置 → 通用 → 登录项与扩展”中允许 NotchNotes，以开启开机自启。"
                : "Allow NotchNotes in System Settings → General → Login Items & Extensions to enable Launch at Login."
        case .notPackaged:
            return isChinese
                ? "请将 NotchNotes 放入“应用程序”文件夹后运行，以启用开机自启。"
                : "Run NotchNotes from the Applications folder to enable Launch at Login."
        case .registrationFailed(let message):
            if message.isEmpty {
                return isChinese ? "无法开启开机自启。" : "Couldn’t enable Launch at Login."
            }
            return isChinese
                ? "无法开启开机自启。\(message)"
                : "Couldn’t enable Launch at Login. \(message)"
        case .unregistrationFailed(let message):
            if message.isEmpty {
                return isChinese ? "无法关闭开机自启。" : "Couldn’t disable Launch at Login."
            }
            return isChinese
                ? "无法关闭开机自启。\(message)"
                : "Couldn’t disable Launch at Login. \(message)"
        }
    }

    func sleepGuardErrorMessage(_ error: SystemSleepGuardError) -> String? {
        switch error {
        case .approvalRequired:
            return isChinese
                ? "若要合盖保持唤醒，请在“系统设置 → 通用 → 登录项与扩展”中允许 NotchNotes（仅需授权一次），然后再次点击咖啡杯图标。"
                : "To keep your Mac awake with the lid closed, allow NotchNotes in System Settings → General → Login Items & Extensions. This is only required once. Then click the coffee cup again."
        case .notPackaged:
            return isChinese
                ? "请从“应用程序”文件夹运行 NotchNotes 以使用合盖防休眠功能（应用包内含所需的后台辅助程序）。"
                : "Run NotchNotes from the Applications folder to use closed-lid keep-awake mode. The packaged app includes the required background helper."
        case .helperLaunchFailed(let message):
            return message
        case .stateVerificationFailed:
            return isChinese
                ? "macOS 未能启用合盖防休眠模式，请重试。"
                : "macOS didn’t enable closed-lid keep-awake mode. Please try again."
        }
    }

    var keepAwakeDisconnectedMessage: String {
        isChinese
            ? "防休眠后台服务已断开，本次防休眠已结束并正在恢复系统正常休眠。"
            : "The keep-awake helper disconnected. The session has ended and normal sleep is being restored."
    }

    var sleepRecoveryNeedsApprovalMessage: String {
        isChinese
            ? "请在“系统设置 → 通用 → 登录项与扩展”中允许 NotchNotes，以便后台服务恢复系统正常休眠。"
            : "Allow NotchNotes in System Settings → General → Login Items & Extensions so its helper can restore normal sleep."
    }

    var sleepRecoveryRetryingMessage: String {
        isChinese
            ? "暂时无法恢复正常休眠，后台服务将继续重试。"
            : "Normal sleep couldn’t be restored yet. The background helper will keep trying."
    }

    // MARK: - Tabs, Editor & Markdown Toolbar

    var untitledNote: String {
        isChinese ? "未命名" : "Untitled"
    }

    var newNote: String {
        isChinese ? "新建笔记" : "New note"
    }

    var deleteNote: String {
        isChinese ? "删除笔记" : "Delete note"
    }

    var deleteThisNote: String {
        isChinese ? "删除此笔记" : "Delete This Note"
    }

    var restoreDeletedNote: String {
        isChinese ? "恢复已删除的笔记" : "Restore Deleted Note"
    }

    func currentNoteAccessibility(_ title: String) -> String {
        isChinese ? "当前笔记：\(title)" : "Current note: \(title)"
    }

    func openNoteAccessibility(_ title: String) -> String {
        isChinese ? "打开笔记：\(title)" : "Open note: \(title)"
    }

    func deleteNoteAccessibility(_ title: String) -> String {
        isChinese ? "删除 \(title)" : "Delete \(title)"
    }

    var startTypingPlaceholder: String {
        isChinese ? "开始输入…" : "Start typing…"
    }

    func markdownCommandTitle(_ command: MarkdownCommand) -> String {
        switch command {
        case .bold:
            return isChinese ? "加粗" : "Bold"
        case .italic:
            return isChinese ? "斜体" : "Italic"
        case .strikethrough:
            return isChinese ? "删除线" : "Strikethrough"
        case .inlineCode:
            return isChinese ? "行内代码" : "Inline Code"
        case .link:
            return isChinese ? "链接" : "Link"
        case .quote:
            return isChinese ? "引用" : "Quote"
        case .unorderedList:
            return isChinese ? "无序列表" : "Bulleted List"
        case .orderedList:
            return isChinese ? "有序列表" : "Numbered List"
        case .todoList:
            return isChinese ? "待办清单" : "Todo List"
        }
    }

    func markdownCommandHelp(_ command: MarkdownCommand) -> String {
        switch command {
        case .bold:
            return isChinese ? "加粗" : "Bold"
        case .italic:
            return isChinese ? "斜体" : "Italic"
        case .strikethrough:
            return isChinese ? "删除线" : "Strikethrough"
        case .inlineCode:
            return isChinese ? "行内代码" : "Inline code"
        case .link:
            return isChinese ? "链接" : "Link"
        case .quote:
            return isChinese ? "引用" : "Quote"
        case .unorderedList:
            return isChinese ? "无序列表" : "Bulleted list"
        case .orderedList:
            return isChinese ? "有序列表" : "Numbered list"
        case .todoList:
            return isChinese ? "待办清单" : "Todo list"
        }
    }

    // MARK: - Slash Command Menu

    func slashItemTitle(_ item: SlashCommandItem) -> String {
        isChinese ? item.subtitle : item.title
    }

    func slashItemHelp(_ item: SlashCommandItem) -> String {
        isChinese ? "\(item.subtitle) · \(item.title)" : "\(item.title) · \(item.subtitle)"
    }

    // MARK: - Temporary File Shelf

    var removeAllShelfItems: String {
        isChinese ? "清空暂存区" : "Remove All Shelf Items"
    }

    var releaseToAdd: String {
        isChinese ? "松开以添加" : "Release to add"
    }

    var removeFromShelfKeepDisk: String {
        isChinese ? "从暂存区移除（磁盘原文件保留）" : "Remove from shelf (file stays on disk)"
    }

    var folderKind: String {
        isChinese ? "文件夹" : "Folder"
    }

    var fileKind: String {
        isChinese ? "文件" : "File"
    }

    func shelfItemPreviewHelp(name: String, kind: String) -> String {
        isChinese
            ? "\(name) · \(kind) · 按空格键预览"
            : "\(name) · \(kind) · Press Space to preview"
    }

    func shelfItemUnavailableHelp(_ name: String) -> String {
        isChinese ? "\(name) 不可用" : "\(name) is unavailable"
    }

    var openItem: String {
        isChinese ? "打开" : "Open"
    }

    var showInFinder: String {
        isChinese ? "在 Finder 中显示" : "Show in Finder"
    }

    var removeFromShelf: String {
        isChinese ? "从暂存区移除" : "Remove from Shelf"
    }

    // MARK: - App & Menu Bar Menus

    var openNotchNotes: String {
        isChinese ? "打开 NotchNotes" : "Open NotchNotes"
    }

    var newNoteMenu: String {
        isChinese ? "新建笔记" : "New Note"
    }

    var showNotes: String {
        isChinese ? "显示笔记" : "Show Notes"
    }

    var hideNotes: String {
        isChinese ? "隐藏笔记" : "Hide Notes"
    }

    var editMenu: String {
        isChinese ? "编辑" : "Edit"
    }

    var undo: String {
        isChinese ? "撤销" : "Undo"
    }

    var redo: String {
        isChinese ? "重做" : "Redo"
    }

    var cut: String {
        isChinese ? "剪切" : "Cut"
    }

    var copy: String {
        isChinese ? "拷贝" : "Copy"
    }

    var paste: String {
        isChinese ? "粘贴" : "Paste"
    }

    var selectAll: String {
        isChinese ? "全选" : "Select All"
    }

    var headingMenu: String {
        isChinese ? "标题" : "Heading"
    }

    func headingLevel(_ level: Int) -> String {
        isChinese ? "标题 \(level)" : "Heading \(level)"
    }

    var findMenu: String {
        isChinese ? "查找" : "Find"
    }

    var findEllipsis: String {
        isChinese ? "查找…" : "Find…"
    }

    var findNext: String {
        isChinese ? "查找下一个" : "Find Next"
    }

    var findPrevious: String {
        isChinese ? "查找上一个" : "Find Previous"
    }
}
