import Darwin
import Foundation

public struct CLIExecutionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

private struct CLIArgumentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

public enum NotchNotesCLIRunner {
    public static let noAutoLaunchEnvKey = "NOTCHNOTES_NO_AUTO_LAUNCH"
    public static let allowAutoLaunchEnvKey = "NOTCHNOTES_ALLOW_AUTO_LAUNCH"

    public static func runFromProcess() -> Int32 {
        let args = Array(CommandLine.arguments.dropFirst())
        let env = ProcessInfo.processInfo.environment
        let isTTY = Darwin.isatty(STDIN_FILENO) != 0
        let result = run(
            arguments: args,
            environment: env,
            currentDirectoryPath: FileManager.default.currentDirectoryPath,
            stdinIsTTY: isTTY,
            readStdin: {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                return String(data: data, encoding: .utf8) ?? ""
            }
        )
        if !result.stdout.isEmpty {
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
        }
        if !result.stderr.isEmpty {
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        return result.exitCode
    }

    public static func run(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        stdinIsTTY: Bool = true,
        readStdin: () -> String = { "" },
        launchAppHandler: (() -> Bool)? = nil
    ) -> CLIExecutionResult {
        var jsonMode = false
        var index = 0
        var subcommand: String?
        var subArgs: [String] = []
        var topLevelError: String?

        while index < arguments.count {
            let arg = arguments[index]
            if arg == "--json" {
                jsonMode = true
                index += 1
                continue
            }
            if arg == "--help" || arg == "-h" || arg == "help" {
                let topic = arguments.dropFirst(index + 1).first { $0 != "--json" }
                return CLIExecutionResult(exitCode: 0, stdout: helpText(for: topic), stderr: "")
            }
            if arg.hasPrefix("-") {
                topLevelError = "Unknown option '\(arg)'. Run 'notch-notes --help' for usage."
                jsonMode = jsonMode || arguments.dropFirst(index + 1).contains("--json")
                break
            }
            subcommand = arg
            subArgs = Array(arguments.dropFirst(index + 1))
            break
        }

        if let topLevelError {
            return formatFailure(topLevelError, jsonMode: jsonMode)
        }

        guard let subcommand else {
            return CLIExecutionResult(exitCode: 0, stdout: helpText(for: nil), stderr: "")
        }

        let consumesValueFor: Set<String> = (subcommand == "add" || subcommand == "append" || subcommand == "update")
            ? ["--text", "-t"]
            : []
        let preprocessed = preprocessSubcommandArguments(
            subArgs,
            consumesValueFor: consumesValueFor,
            initialJSONMode: jsonMode
        )
        jsonMode = preprocessed.jsonMode

        if preprocessed.requestedHelp {
            return CLIExecutionResult(exitCode: 0, stdout: helpText(for: subcommand), stderr: "")
        }

        do {
            let request = try parseRequest(
                subcommand: subcommand,
                arguments: preprocessed.filtered,
                currentDirectoryPath: currentDirectoryPath,
                stdinIsTTY: stdinIsTTY,
                readStdin: readStdin
            )

            let response = try execute(
                request: request,
                environment: environment,
                launchAppHandler: launchAppHandler
            )

            guard response.ok else {
                return formatFailure(response.error ?? "Command failed.", jsonMode: jsonMode)
            }

            let formatted = try formatSuccess(response: response, request: request, jsonMode: jsonMode)
            return CLIExecutionResult(exitCode: 0, stdout: formatted, stderr: "")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return formatFailure(message, jsonMode: jsonMode)
        }
    }

    private static func preprocessSubcommandArguments(
        _ arguments: [String],
        consumesValueFor: Set<String>,
        initialJSONMode: Bool
    ) -> (filtered: [String], jsonMode: Bool, requestedHelp: Bool) {
        var jsonMode = initialJSONMode
        var requestedHelp = false
        var filtered: [String] = []
        var treatAsPositional = false
        var expectingValue = false

        for arg in arguments {
            if expectingValue {
                filtered.append(arg)
                expectingValue = false
                continue
            }
            if treatAsPositional {
                filtered.append(arg)
                continue
            }
            if arg == "--" {
                treatAsPositional = true
                filtered.append(arg)
                continue
            }
            if arg == "--json" {
                jsonMode = true
                continue
            }
            if arg == "--help" || arg == "-h" {
                requestedHelp = true
                continue
            }
            if consumesValueFor.contains(arg) {
                expectingValue = true
            }
            filtered.append(arg)
        }

        return (filtered, jsonMode, requestedHelp)
    }

    // MARK: - Argument Parsing

    private static func parseRequest(
        subcommand: String,
        arguments: [String],
        currentDirectoryPath: String,
        stdinIsTTY: Bool,
        readStdin: () -> String
    ) throws -> IPCRequest {
        switch subcommand {
        case "list":
            guard arguments.isEmpty else {
                throw CLIArgumentError(message: "Unexpected arguments for 'list': \(arguments.joined(separator: " "))")
            }
            return IPCRequest(action: .list)

        case "get":
            let target = try parseOptionalTarget(from: arguments, command: "get")
            return IPCRequest(action: .get, target: target)

        case "add":
            var textValue: String?
            var useStdin = false
            var select = false
            var idx = 0
            while idx < arguments.count {
                let arg = arguments[idx]
                if arg == "--text" || arg == "-t" {
                    idx += 1
                    guard idx < arguments.count else {
                        throw CLIArgumentError(message: "Missing value for \(arg).")
                    }
                    textValue = arguments[idx]
                } else if arg.hasPrefix("--text=") {
                    textValue = String(arg.dropFirst("--text=".count))
                } else if arg == "--stdin" {
                    useStdin = true
                } else if arg == "--select" {
                    select = true
                } else {
                    throw CLIArgumentError(message: "Unknown option for 'add': \(arg)")
                }
                idx += 1
            }

            if textValue != nil && useStdin {
                throw CLIArgumentError(message: "Cannot specify both --text and --stdin.")
            }

            let resolvedText: String
            if let textValue {
                resolvedText = textValue
            } else if useStdin || !stdinIsTTY {
                resolvedText = readStdin()
            } else {
                resolvedText = ""
            }

            return IPCRequest(action: .add, text: resolvedText, select: select)

        case "append":
            return try parseContentMutation(
                action: .append,
                arguments: arguments,
                allowNoNewline: true,
                stdinIsTTY: stdinIsTTY,
                readStdin: readStdin
            )

        case "update":
            return try parseContentMutation(
                action: .update,
                arguments: arguments,
                allowNoNewline: false,
                stdinIsTTY: stdinIsTTY,
                readStdin: readStdin
            )

        case "delete":
            let target = try parseRequiredTarget(from: arguments, command: "delete")
            return IPCRequest(action: .delete, target: target)

        case "search":
            let positionals = try parsePositionalOnly(from: arguments, command: "search")
            guard positionals.count == 1 else {
                throw CLIArgumentError(message: "Usage: notch-notes search <query> [--json]")
            }
            guard !positionals[0].isEmpty else {
                throw NoteStorageError.emptySearchQuery
            }
            return IPCRequest(action: .search, query: positionals[0])

        case "shelf":
            return try parseShelfRequest(arguments: arguments, currentDirectoryPath: currentDirectoryPath)

        case "panel":
            guard arguments.count == 1, let panelCommand = PanelCommand(rawValue: arguments[0]) else {
                throw CLIArgumentError(message: "Usage: notch-notes panel <open|close|toggle> [--json]")
            }
            return IPCRequest(action: .panel, panelCommand: panelCommand)

        default:
            throw CLIArgumentError(message: "Unknown command '\(subcommand)'. Run 'notch-notes --help' for usage.")
        }
    }

    private static func parseOptionalTarget(from arguments: [String], command: String) throws -> String? {
        var target: String?
        var explicitActive = false
        var treatAsPositional = false

        for arg in arguments {
            if !treatAsPositional && arg == "--" {
                treatAsPositional = true
                continue
            }
            if !treatAsPositional && arg == "--active" {
                explicitActive = true
                continue
            }
            if !treatAsPositional && arg.hasPrefix("-") {
                throw CLIArgumentError(message: "Unknown option for '\(command)': \(arg)")
            }
            guard target == nil else {
                throw CLIArgumentError(message: "Too many target arguments for '\(command)'.")
            }
            target = arg
        }

        if explicitActive && target != nil {
            throw CLIArgumentError(message: "Cannot specify both <target> and --active for '\(command)'.")
        }

        return target
    }

    private static func parseRequiredTarget(from arguments: [String], command: String) throws -> String {
        var target: String?
        var treatAsPositional = false

        for arg in arguments {
            if !treatAsPositional && arg == "--" {
                treatAsPositional = true
                continue
            }
            if !treatAsPositional && arg == "--active" {
                throw CLIArgumentError(
                    message: "'\(command)' requires an explicit <target> (index, UUID, or title); --active is not allowed."
                )
            }
            if !treatAsPositional && arg.hasPrefix("-") {
                throw CLIArgumentError(message: "Unknown option for '\(command)': \(arg)")
            }
            guard target == nil else {
                throw CLIArgumentError(message: "Usage: notch-notes \(command) <target> [--json]")
            }
            target = arg
        }

        guard let target else {
            throw CLIArgumentError(message: "Usage: notch-notes \(command) <target> [--json]")
        }

        return target
    }

    private static func parsePositionalOnly(from arguments: [String], command: String) throws -> [String] {
        var positionals: [String] = []
        var treatAsPositional = false
        for arg in arguments {
            if !treatAsPositional && arg == "--" {
                treatAsPositional = true
                continue
            }
            if !treatAsPositional && arg.hasPrefix("-") {
                throw CLIArgumentError(message: "Unknown option for '\(command)': \(arg)")
            }
            positionals.append(arg)
        }
        return positionals
    }

    private static func parseContentMutation(
        action: IPCAction,
        arguments: [String],
        allowNoNewline: Bool,
        stdinIsTTY: Bool,
        readStdin: () -> String
    ) throws -> IPCRequest {
        let commandName = action.rawValue
        var target: String?
        var explicitActive = false
        var textValue: String?
        var useStdin = false
        var noNewline = false
        var treatAsPositional = false
        var idx = 0

        while idx < arguments.count {
            let arg = arguments[idx]
            if !treatAsPositional && arg == "--" {
                treatAsPositional = true
                idx += 1
                continue
            }
            if !treatAsPositional {
                if arg == "--active" {
                    explicitActive = true
                    idx += 1
                    continue
                }
                if arg == "--text" || arg == "-t" {
                    idx += 1
                    guard idx < arguments.count else {
                        throw CLIArgumentError(message: "Missing value for \(arg).")
                    }
                    textValue = arguments[idx]
                    idx += 1
                    continue
                }
                if arg.hasPrefix("--text=") {
                    textValue = String(arg.dropFirst("--text=".count))
                    idx += 1
                    continue
                }
                if arg == "--stdin" {
                    useStdin = true
                    idx += 1
                    continue
                }
                if allowNoNewline && arg == "--no-newline" {
                    noNewline = true
                    idx += 1
                    continue
                }
                if arg.hasPrefix("-") {
                    throw CLIArgumentError(message: "Unknown option for '\(commandName)': \(arg)")
                }
            }

            guard target == nil else {
                throw CLIArgumentError(message: "Too many positional arguments for '\(commandName)'.")
            }
            target = arg
            idx += 1
        }

        if explicitActive && target != nil {
            throw CLIArgumentError(message: "Cannot specify both <target> and --active for '\(commandName)'.")
        }
        if textValue != nil && useStdin {
            throw CLIArgumentError(message: "Cannot specify both --text and --stdin.")
        }

        let resolvedText: String
        if let textValue {
            resolvedText = textValue
        } else if useStdin || !stdinIsTTY {
            resolvedText = readStdin()
        } else {
            throw CLIArgumentError(
                message: "Missing content for '\(commandName)'. Pass --text <markdown> or pipe input with --stdin."
            )
        }

        return IPCRequest(
            action: action,
            target: target,
            text: resolvedText,
            noNewline: allowNoNewline ? noNewline : nil
        )
    }

    private static func parseShelfRequest(
        arguments: [String],
        currentDirectoryPath: String
    ) throws -> IPCRequest {
        guard let sub = arguments.first else {
            throw CLIArgumentError(message: "Usage: notch-notes shelf <list|add|remove|clear> [--json]")
        }
        let rest = Array(arguments.dropFirst())
        let cwdURL = URL(fileURLWithPath: currentDirectoryPath, isDirectory: true)

        switch sub {
        case "list":
            guard rest.isEmpty else {
                throw CLIArgumentError(message: "Usage: notch-notes shelf list [--json]")
            }
            return IPCRequest(action: .shelf, shelfOperation: .list)

        case "add":
            let rawPaths = try parsePositionalOnly(from: rest, command: "shelf add")
            guard !rawPaths.isEmpty else {
                throw CLIArgumentError(message: "Usage: notch-notes shelf add <path...> [--json]")
            }
            var normalized: [String] = []
            normalized.reserveCapacity(rawPaths.count)
            for rawPath in rawPaths {
                let expanded = (rawPath as NSString).expandingTildeInPath
                let url = URL(fileURLWithPath: expanded, relativeTo: cwdURL).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NoteStorageError.fileNotFound(rawPath)
                }
                normalized.append(url.path)
            }
            return IPCRequest(action: .shelf, shelfOperation: .add, paths: normalized)

        case "remove":
            let targets = try parsePositionalOnly(from: rest, command: "shelf remove")
            guard targets.count == 1 else {
                throw CLIArgumentError(message: "Usage: notch-notes shelf remove <id|path> [--json]")
            }
            let raw = targets[0]
            let expandedRaw = (raw as NSString).expandingTildeInPath
            let resolvedPath = URL(fileURLWithPath: expandedRaw, relativeTo: cwdURL).standardizedFileURL.path
            let shelfTarget: String
            if UUID(uuidString: raw) != nil
                || (raw.count >= 4 && raw.allSatisfy({ $0.isHexDigit || $0 == "-" }) && !FileManager.default.fileExists(atPath: resolvedPath)) {
                shelfTarget = raw
            } else if raw.contains("/") || raw.hasPrefix("~") || raw.hasPrefix(".") {
                shelfTarget = resolvedPath
            } else if FileManager.default.fileExists(atPath: resolvedPath) {
                shelfTarget = resolvedPath
            } else {
                shelfTarget = raw
            }
            return IPCRequest(action: .shelf, shelfOperation: .remove, shelfTarget: shelfTarget)

        case "clear":
            guard rest.isEmpty else {
                throw CLIArgumentError(message: "Usage: notch-notes shelf clear [--json]")
            }
            return IPCRequest(action: .shelf, shelfOperation: .clear)

        default:
            throw CLIArgumentError(message: "Unknown shelf command '\(sub)'. Expected list, add, remove, or clear.")
        }
    }

    // MARK: - Dual-Path Execution (Online IPC -> Offline File Lock Fallback)

    private static func execute(
        request: IPCRequest,
        environment: [String: String],
        launchAppHandler: (() -> Bool)?
    ) throws -> IPCResponse {
        switch try IPCClient.sendIfRunning(request, environment: environment) {
        case let .connected(response):
            return response
        case .offline:
            return try executeOffline(
                request: request,
                environment: environment,
                launchAppHandler: launchAppHandler
            )
        }
    }

    private static func shouldAutoLaunchApp(environment: [String: String]) -> Bool {
        if let disabled = environment[noAutoLaunchEnvKey], !disabled.isEmpty, disabled != "0" {
            return false
        }
        if let forced = environment[allowAutoLaunchEnvKey], forced == "1" {
            return true
        }
        if environment[IPCSocketSecurity.socketPathEnvKey] != nil
            || environment[NoteStorage.dataDirEnvKey] != nil
            || environment[NoteStorage.defaultsSuiteEnvKey] != nil {
            return false
        }
        return true
    }

    private static func defaultLaunchApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "NotchNotes"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func executeOffline(
        request: IPCRequest,
        environment: [String: String],
        launchAppHandler: (() -> Bool)?
    ) throws -> IPCResponse {
        if request.action == .panel {
            let panelCmd = request.panelCommand ?? .toggle
            if panelCmd == .close {
                return IPCResponse(
                    ok: true,
                    panel: PanelStatePayload(action: .close, isExpanded: false, launchedApp: false)
                )
            }

            let canLaunch = launchAppHandler != nil || shouldAutoLaunchApp(environment: environment)
            if canLaunch {
                let launched = (launchAppHandler ?? defaultLaunchApp)()
                if launched {
                    let retryRequest = IPCRequest(action: .panel, panelCommand: .open)
                    for _ in 0..<20 {
                        usleep(100_000)
                        if case let .connected(resp) = try? IPCClient.sendIfRunning(retryRequest, environment: environment),
                           resp.ok {
                            return IPCResponse(
                                ok: true,
                                panel: PanelStatePayload(
                                    action: panelCmd,
                                    isExpanded: resp.panel?.isExpanded ?? true,
                                    launchedApp: true
                                )
                            )
                        }
                    }
                }
            }

            return .failure("NotchNotes is not running.")
        }

        guard let archiveURL = NoteStorage.defaultArchiveURL(environment: environment) else {
            throw NoteStorageError.persistenceFailed("Unable to resolve NotchNotes data directory.")
        }
        let defaults = NoteStorage.resolveUserDefaults(environment: environment)

        return try NoteStorage.withExclusiveFileLock(for: archiveURL) {
            if request.action == .shelf {
                return try executeOfflineShelf(request: request, defaults: defaults)
            }

            var (tabs, activeTabID) = NoteStorage.loadInitialState(defaults: defaults, archiveURL: archiveURL)

            switch request.action {
            case .list:
                let summaries = tabs.enumerated().map { idx, tab in
                    IPCPayloadBuilder.summary(for: tab, index: idx, activeTabID: activeTabID)
                }
                return IPCResponse(ok: true, notes: summaries)

            case .get:
                let idx = try NoteTargetMatcher.resolveIndex(in: tabs, activeTabID: activeTabID, target: request.target)
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(for: tabs[idx], index: idx, activeTabID: activeTabID)
                )

            case .add:
                let newTab = NoteTab(text: request.text ?? "")
                tabs.append(newTab)
                if request.select == true {
                    activeTabID = newTab.id
                }
                try saveOfflineNotes(tabs: tabs, activeTabID: activeTabID, defaults: defaults, archiveURL: archiveURL)
                let newIndex = tabs.count - 1
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(for: newTab, index: newIndex, activeTabID: activeTabID)
                )

            case .append:
                let idx = try NoteTargetMatcher.resolveIndex(in: tabs, activeTabID: activeTabID, target: request.target)
                let appended = request.text ?? ""
                let current = tabs[idx].text
                let insertNewline = !(request.noNewline ?? false) && !current.isEmpty && !current.hasSuffix("\n")
                let updatedText = insertNewline ? current + "\n" + appended : current + appended
                tabs[idx].text = updatedText
                let clamped = NoteStorage.clampedSelection(
                    location: tabs[idx].selectionLocation,
                    length: tabs[idx].selectionLength,
                    for: updatedText
                )
                tabs[idx].selectionLocation = clamped.0
                tabs[idx].selectionLength = clamped.1
                try saveOfflineNotes(tabs: tabs, activeTabID: activeTabID, defaults: defaults, archiveURL: archiveURL)
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(for: tabs[idx], index: idx, activeTabID: activeTabID)
                )

            case .update:
                let idx = try NoteTargetMatcher.resolveIndex(in: tabs, activeTabID: activeTabID, target: request.target)
                let updatedText = request.text ?? ""
                tabs[idx].text = updatedText
                let clamped = NoteStorage.clampedSelection(
                    location: tabs[idx].selectionLocation,
                    length: tabs[idx].selectionLength,
                    for: updatedText
                )
                tabs[idx].selectionLocation = clamped.0
                tabs[idx].selectionLength = clamped.1
                try saveOfflineNotes(tabs: tabs, activeTabID: activeTabID, defaults: defaults, archiveURL: archiveURL)
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(for: tabs[idx], index: idx, activeTabID: activeTabID)
                )

            case .delete:
                let idx = try NoteTargetMatcher.resolveIndex(in: tabs, activeTabID: activeTabID, target: request.target)
                guard tabs.count > 1 else {
                    throw NoteStorageError.cannotDeleteLastNote
                }
                let removedTitle = NoteTitleExtractor.title(for: tabs[idx].text, index: idx)
                let removed = tabs.remove(at: idx)
                if removed.id == activeTabID {
                    let nextIdx = min(idx, tabs.count - 1)
                    activeTabID = tabs[nextIdx].id
                }
                try saveOfflineNotes(tabs: tabs, activeTabID: activeTabID, defaults: defaults, archiveURL: archiveURL)
                return IPCResponse(
                    ok: true,
                    deleted: DeleteNotePayload(
                        deletedID: removed.id.uuidString,
                        title: removedTitle,
                        activeTabID: activeTabID.uuidString,
                        remainingCount: tabs.count
                    )
                )

            case .search:
                let matches = try IPCPayloadBuilder.searchMatches(in: tabs, query: request.query ?? "")
                return IPCResponse(ok: true, matches: matches)

            case .shelf, .panel:
                return .failure("Unreachable offline command state.")
            }
        }
    }

    private static func saveOfflineNotes(
        tabs: [NoteTab],
        activeTabID: UUID,
        defaults: UserDefaults,
        archiveURL: URL
    ) throws {
        let snapshot = PersistedNotes(tabs: tabs, activeTabID: activeTabID, savedAt: Date())
        let archiveData = try JSONEncoder().encode(snapshot)
        try archiveData.write(to: archiveURL, options: .atomic)
        NoteStorage.writeDefaultsSnapshot(
            snapshot,
            archiveData: archiveData,
            defaults: defaults,
            synchronize: true
        )
    }

    private static func executeOfflineShelf(
        request: IPCRequest,
        defaults: UserDefaults
    ) throws -> IPCResponse {
        var items = NoteStorage.loadShelfItems(from: defaults)
        let operation = request.shelfOperation ?? .list

        switch operation {
        case .list:
            return IPCResponse(
                ok: true,
                shelfItems: items.map(IPCPayloadBuilder.shelfItemPayload(for:))
            )

        case .add:
            var knownPaths = Set(items.map { URL(fileURLWithPath: $0.fallbackPath).standardizedFileURL.path })
            var addedCount = 0
            for rawPath in request.paths ?? [] {
                let url = URL(fileURLWithPath: rawPath).standardizedFileURL
                guard items.count < NoteStorage.maximumShelfItemCount else { break }
                guard knownPaths.insert(url.path).inserted else { continue }
                items.append(FileShelfItem(url: url))
                addedCount += 1
            }
            if addedCount > 0 {
                try NoteStorage.saveShelfItems(items, to: defaults, synchronize: true)
            }
            return IPCResponse(
                ok: true,
                shelfMutation: ShelfMutationPayload(
                    operation: .add,
                    affectedCount: addedCount,
                    items: items.map(IPCPayloadBuilder.shelfItemPayload(for:))
                )
            )

        case .remove:
            let target = request.shelfTarget ?? ""
            let removeIDs = try resolveShelfRemovalIDs(in: items, target: target)
            items.removeAll { removeIDs.contains($0.id) }
            try NoteStorage.saveShelfItems(items, to: defaults, synchronize: true)
            return IPCResponse(
                ok: true,
                shelfMutation: ShelfMutationPayload(
                    operation: .remove,
                    affectedCount: removeIDs.count,
                    items: items.map(IPCPayloadBuilder.shelfItemPayload(for:))
                )
            )

        case .clear:
            let removedCount = items.count
            items.removeAll()
            try NoteStorage.saveShelfItems(items, to: defaults, synchronize: true)
            return IPCResponse(
                ok: true,
                shelfMutation: ShelfMutationPayload(operation: .clear, affectedCount: removedCount, items: [])
            )
        }
    }

    public static func resolveShelfRemovalIDs(in items: [FileShelfItem], target: String) throws -> Set<UUID> {
        try NoteStorage.resolveShelfRemovalIDs(in: items, target: target)
    }

    // MARK: - Output Formatting

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }

    private static func formatFailure(_ message: String, jsonMode: Bool) -> CLIExecutionResult {
        if jsonMode {
            struct ErrorPayload: Encodable {
                let ok = false
                let error: String
            }
            let json = (try? encodeJSON(ErrorPayload(error: message))) ?? "{\"ok\":false,\"error\":\"\(message)\"}\n"
            return CLIExecutionResult(exitCode: 1, stdout: "", stderr: json)
        }
        return CLIExecutionResult(exitCode: 1, stdout: "", stderr: "Error: \(message)\n")
    }

    private static func formatSuccess(
        response: IPCResponse,
        request: IPCRequest,
        jsonMode: Bool
    ) throws -> String {
        switch request.action {
        case .list:
            let notes = response.notes ?? []
            if jsonMode {
                return try encodeJSON(notes)
            }
            if notes.isEmpty {
                return "No notes.\n"
            }
            return notes.map { item in
                let marker = item.isActive ? "*" : " "
                return "\(marker) [\(item.index)] \(item.title)  (\(item.characterCount) chars, id: \(item.id.prefix(8)), created: \(item.createdAt))"
            }.joined(separator: "\n") + "\n"

        case .get:
            guard let note = response.note else { return "" }
            if jsonMode {
                return try encodeJSON(note)
            }
            if note.text.isEmpty || note.text.hasSuffix("\n") {
                return note.text
            }
            return note.text + "\n"

        case .add, .append, .update:
            guard let note = response.note else { return "" }
            if jsonMode {
                return try encodeJSON(note)
            }
            let verb: String
            switch request.action {
            case .add: verb = "Added"
            case .append: verb = "Appended to"
            case .update: verb = "Updated"
            default: verb = "Saved"
            }
            return "\(verb) note [\(note.index)] \(note.title) (\(note.id))\n"

        case .delete:
            guard let deleted = response.deleted else { return "" }
            if jsonMode {
                return try encodeJSON(deleted)
            }
            return "Deleted note '\(deleted.title)' (\(deleted.deletedID)). \(deleted.remainingCount) remaining.\n"

        case .search:
            let matches = response.matches ?? []
            if jsonMode {
                return try encodeJSON(matches)
            }
            if matches.isEmpty {
                return "No matches found.\n"
            }
            return matches.map { match in
                "[\(match.index)] \(match.title):\(match.line): \(match.snippet)"
            }.joined(separator: "\n") + "\n"

        case .shelf:
            let op = request.shelfOperation ?? .list
            if op == .list {
                let items = response.shelfItems ?? []
                if jsonMode {
                    return try encodeJSON(items)
                }
                if items.isEmpty {
                    return "File shelf is empty.\n"
                }
                return items.map { item in
                    let status = item.exists ? "" : " (missing)"
                    return "- \(item.name)  \(item.path)\(status)  [\(item.id.prefix(8))]"
                }.joined(separator: "\n") + "\n"
            } else if let mutation = response.shelfMutation {
                if jsonMode {
                    return try encodeJSON(mutation)
                }
                switch mutation.operation {
                case .add:
                    return "Added \(mutation.affectedCount) item(s) to shelf (\(mutation.items.count) total).\n"
                case .remove:
                    return "Removed \(mutation.affectedCount) item(s) from shelf (\(mutation.items.count) remaining).\n"
                case .clear:
                    return "Cleared \(mutation.affectedCount) item(s) from shelf.\n"
                case .list:
                    return ""
                }
            }
            return ""

        case .panel:
            guard let panel = response.panel else { return "" }
            if jsonMode {
                return try encodeJSON(panel)
            }
            let stateText = panel.isExpanded ? "open" : "closed"
            return "Notch panel is now \(stateText).\n"
        }
    }

    // MARK: - Help Text

    public static func helpText(for subcommand: String? = nil) -> String {
        switch subcommand {
        case "list":
            return """
            Usage: notch-notes list [--json]

            List all note tabs with 1-based index, id, title, character count, active flag, and creation date.
            """ + "\n"
        case "get":
            return """
            Usage: notch-notes get [<target> | --active] [--json]

            Print the target note (defaults to --active).
            <target> accepts full UUID, UUID prefix, 1-based index, or exact/prefix title.
            """ + "\n"
        case "add":
            return """
            Usage: notch-notes add [--text <markdown> | --stdin] [--select] [--json]

            Create a new note tab. Reads from stdin when --stdin is passed or stdin is piped.
            Pass --select to make the new tab active.
            """ + "\n"
        case "append":
            return """
            Usage: notch-notes append [<target> | --active] [--text <markdown> | --stdin] [--no-newline] [--json]

            Append content to the end of the target note (inserts a leading newline when needed unless --no-newline is set).
            """ + "\n"
        case "update":
            return """
            Usage: notch-notes update [<target> | --active] [--text <markdown> | --stdin] [--json]

            Replace the full content of the target note.
            """ + "\n"
        case "delete":
            return """
            Usage: notch-notes delete <target> [--json]

            Delete the specified note tab. Refuses to delete the last remaining note.
            """ + "\n"
        case "search":
            return """
            Usage: notch-notes search <query> [--json]

            Search across all note tabs line by line (case-insensitive).
            """ + "\n"
        case "shelf":
            return """
            Usage:
              notch-notes shelf list [--json]
              notch-notes shelf add <path...> [--json]
              notch-notes shelf remove <id|path> [--json]
              notch-notes shelf clear [--json]

            Inspect or modify the NotchNotes temporary file shelf.
            """ + "\n"
        case "panel":
            return """
            Usage: notch-notes panel <open|close|toggle> [--json]

            Expand, collapse, or toggle the NotchNotes drawer.
            """ + "\n"
        default:
            return """
            notch-notes — Command-line interface for NotchNotes

            Usage:
              notch-notes list [--json]
              notch-notes get [<target> | --active] [--json]
              notch-notes add [--text <markdown> | --stdin] [--select] [--json]
              notch-notes append [<target> | --active] [--text <markdown> | --stdin] [--no-newline] [--json]
              notch-notes update [<target> | --active] [--text <markdown> | --stdin] [--json]
              notch-notes delete <target> [--json]
              notch-notes search <query> [--json]
              notch-notes shelf <list | add <path...> | remove <id|path> | clear> [--json]
              notch-notes panel <open | close | toggle> [--json]

            Options:
              -h, --help    Show help information
              --json        Format output as JSON
            """ + "\n"
        }
    }
}
