import Darwin
import Foundation

public struct CLIInstallResult: Equatable, Sendable {
    public let sourceURL: URL
    public let destinationURL: URL
    public let usedLocalBinFallback: Bool
    public let isInPATH: Bool
    public let message: String

    public init(
        sourceURL: URL,
        destinationURL: URL,
        usedLocalBinFallback: Bool,
        isInPATH: Bool,
        message: String
    ) {
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.usedLocalBinFallback = usedLocalBinFallback
        self.isInPATH = isInPATH
        self.message = message
    }
}

public enum CLIInstallerError: LocalizedError, Equatable, Sendable {
    case bundledBinaryNotFound(String)
    case existingFileIsNotSymlink(String)
    case symlinkCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .bundledBinaryNotFound(path):
            return "Could not find bundled notch-notes CLI executable at \(path)."
        case let .existingFileIsNotSymlink(path):
            return "A non-symlink file already exists at \(path). Remove or rename it first."
        case let .symlinkCreationFailed(reason):
            return "Failed to install notch-notes symlink: \(reason)"
        }
    }
}

public enum CLIInstaller {
    public static let binaryName = "notch-notes"

    public static func bundledBinaryURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(binaryName)
    }

    public static func preferredDestinationURL(
        usrLocalBinURL: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> (url: URL, usedLocalBinFallback: Bool) {
        if FileManager.default.isWritableFile(atPath: usrLocalBinURL.path) {
            return (usrLocalBinURL.appendingPathComponent(binaryName), false)
        }

        let localBin = homeDirectoryURL
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(binaryName)
        return (localBin, true)
    }

    @discardableResult
    public static func install(
        bundleURL: URL = Bundle.main.bundleURL,
        usrLocalBinURL: URL = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"]
    ) throws -> CLIInstallResult {
        let sourceURL = bundledBinaryURL(bundleURL: bundleURL)
        guard FileManager.default.isExecutableFile(atPath: sourceURL.path) else {
            throw CLIInstallerError.bundledBinaryNotFound(sourceURL.path)
        }

        let preferred = preferredDestinationURL(
            usrLocalBinURL: usrLocalBinURL,
            homeDirectoryURL: homeDirectoryURL
        )
        let destinationURL = preferred.url
        let parentDir = destinationURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw CLIInstallerError.symlinkCreationFailed(error.localizedDescription)
        }

        var st = Darwin.stat()
        if Darwin.lstat(destinationURL.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFLNK else {
                throw CLIInstallerError.existingFileIsNotSymlink(destinationURL.path)
            }
            if Darwin.unlink(destinationURL.path) != 0 {
                let reason = String(cString: strerror(errno))
                throw CLIInstallerError.symlinkCreationFailed(reason)
            }
        }

        do {
            try FileManager.default.createSymbolicLink(
                atPath: destinationURL.path,
                withDestinationPath: sourceURL.path
            )
        } catch {
            throw CLIInstallerError.symlinkCreationFailed(error.localizedDescription)
        }

        let standardizedParent = parentDir.standardizedFileURL.path
        let pathEntries = (pathEnvironment ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
        let isInPATH = pathEntries.contains(standardizedParent)

        let message: String
        if isInPATH || !preferred.usedLocalBinFallback {
            message = "Installed '\(binaryName)' to \(destinationURL.path). Run 'notch-notes --help' in Terminal to verify."
        } else {
            message = """
            Installed '\(binaryName)' to \(destinationURL.path).

            Add ~/.local/bin to your PATH to run 'notch-notes' from anywhere:
            export PATH="$HOME/.local/bin:$PATH"
            """
        }

        return CLIInstallResult(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            usedLocalBinFallback: preferred.usedLocalBinFallback,
            isInPATH: isInPATH,
            message: message
        )
    }
}

public enum AgentSkillSetup {
    public static let skillName = "notch-notes"
    public static let fallbackSkillURLString = "https://raw.githubusercontent.com/oil-oil/NotchNotes/main/Skills/notch-notes/SKILL.md"

    public static func bundledSkillURL(bundleURL: URL = Bundle.main.bundleURL) -> URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent(skillName, isDirectory: true)
            .appendingPathComponent("SKILL.md")
    }

    public static func resolvedSkillFileURL(
        bundleURL: URL = Bundle.main.bundleURL,
        applicationsAppURL: URL = URL(fileURLWithPath: "/Applications/NotchNotes.app", isDirectory: true),
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            bundledSkillURL(bundleURL: bundleURL),
            bundledSkillURL(bundleURL: applicationsAppURL)
        ]
        return candidates.first { fileManager.fileExists(atPath: $0.path) }
    }

    public static func resolvedCLIBinaryPath(
        bundleURL: URL = Bundle.main.bundleURL,
        applicationsAppURL: URL = URL(fileURLWithPath: "/Applications/NotchNotes.app", isDirectory: true),
        fileManager: FileManager = .default
    ) -> String {
        let candidates = [
            CLIInstaller.bundledBinaryURL(bundleURL: bundleURL),
            CLIInstaller.bundledBinaryURL(bundleURL: applicationsAppURL)
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }?.path
            ?? "/Applications/NotchNotes.app/Contents/MacOS/notch-notes"
    }

    private static func shellSingleQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func installPrompt(
        isChinese: Bool,
        bundleURL: URL = Bundle.main.bundleURL,
        applicationsAppURL: URL = URL(fileURLWithPath: "/Applications/NotchNotes.app", isDirectory: true),
        fileManager: FileManager = .default
    ) -> String {
        let cliPath = resolvedCLIBinaryPath(
            bundleURL: bundleURL,
            applicationsAppURL: applicationsAppURL,
            fileManager: fileManager
        )
        let quotedCLIPath = shellSingleQuoted(cliPath)
        let skillPath = (
            resolvedSkillFileURL(
                bundleURL: bundleURL,
                applicationsAppURL: applicationsAppURL,
                fileManager: fileManager
            ) ?? bundledSkillURL(bundleURL: applicationsAppURL)
        ).path

        if isChinese {
            return """
            请帮我安装并配置 NotchNotes（刘海笔记）的 CLI 与 Agent Skill：

            1. 配置 CLI 命令 `notch-notes`：
               - 内置可执行文件：`\(cliPath)`
               - 若当前 `command -v notch-notes` 不可用，请优先软链到 `/usr/local/bin/notch-notes`；若无写权限，则执行 `mkdir -p ~/.local/bin && ln -sf \(quotedCLIPath) ~/.local/bin/notch-notes`。

            2. 安装 `notch-notes` Skill 到你自己的全局技能目录：
               - 本地技能文件：`\(skillPath)`（若本地不存在，可从 \(fallbackSkillURLString) 获取）
               - 请将该 `SKILL.md` 复制到你当前 Agent 实际加载的全局 skills 目录下的 `notch-notes/SKILL.md`（例如 Claude Code 为 `~/.claude/skills/notch-notes/SKILL.md`，Codex 为 `~/.codex/skills/notch-notes/SKILL.md`，Cursor / OpenCode / 通用 Agent 为 `~/.agents/skills/notch-notes/SKILL.md`，其他 Agent 请放入你自己的全局 skills 目录；目录不存在则先 `mkdir -p`）。

            3. 验证可用性：
               - 运行 `"$(command -v notch-notes || echo \(quotedCLIPath))" list --json` 验证连接正常，完成后告诉我即可。
            """
        }

        return """
        Please install and configure the NotchNotes CLI and Agent Skill for me:

        1. Set up the `notch-notes` CLI command:
           - Bundled executable: `\(cliPath)`
           - If `command -v notch-notes` is unavailable, symlink it to `/usr/local/bin/notch-notes` if writable; otherwise run `mkdir -p ~/.local/bin && ln -sf \(quotedCLIPath) ~/.local/bin/notch-notes`.

        2. Install the `notch-notes` Skill into your own global skills directory:
           - Local skill file: `\(skillPath)` (fallback if missing: \(fallbackSkillURLString))
           - Copy `SKILL.md` to `notch-notes/SKILL.md` inside the global skills directory you actually load skills from (for example `~/.claude/skills/notch-notes/SKILL.md` for Claude Code, `~/.codex/skills/notch-notes/SKILL.md` for Codex, `~/.agents/skills/notch-notes/SKILL.md` for Cursor / OpenCode / universal agents, or your own global skills folder; create parent directories with `mkdir -p` if needed).

        3. Verify:
           - Run `"$(command -v notch-notes || echo \(quotedCLIPath))" list --json` to confirm it works, then let me know it is ready.
        """
    }
}
