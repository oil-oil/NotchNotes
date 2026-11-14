import Darwin
import Foundation
import XCTest
@testable import NotchNotes
import NotchNotesCore

@MainActor
final class CLIIPCTests: XCTestCase {
    func testOfflineCLICRUDTargetMatchingSearchAndStoreRecovery() async throws {
        let env = try makeIsolatedEnvironment()
        defer { env.cleanUp() }

        // Seed an older snapshot via NoteStore first, then关闭/离线用 CLI 修改并确认下次启动采用最新快照
        do {
            let initialStore = NoteStore(defaults: env.defaults, archiveURL: env.archiveURL)
            initialStore.updateText("# Initial Note\nLine one")
            initialStore.flush()
        }

        let added = await env.runCLI(["add", "--text", "Intro line\n## Second Header\nTODO: ship ipc", "--json"])
        XCTAssertEqual(added.exitCode, 0, added.stderr)
        let addedDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(added.stdout.utf8))
        XCTAssertEqual(addedDetail.title, "Second Header")
        XCTAssertFalse(addedDetail.isActive)

        // Pipe via --stdin with --select
        let piped = await env.runCLI(
            ["add", "--stdin", "--select", "--json"],
            stdinIsTTY: false,
            stdin: "# Third Tab\nPipe body"
        )
        XCTAssertEqual(piped.exitCode, 0, piped.stderr)
        let pipedDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(piped.stdout.utf8))
        XCTAssertTrue(pipedDetail.isActive)
        XCTAssertEqual(pipedDetail.index, 3)

        // List all 3 notes
        let listed = await env.runCLI(["list", "--json"])
        XCTAssertEqual(listed.exitCode, 0)
        let summaries = try JSONDecoder().decode([NoteSummaryPayload].self, from: Data(listed.stdout.utf8))
        XCTAssertEqual(summaries.map(\.title), ["Initial Note", "Second Header", "Third Tab"])
        XCTAssertEqual(summaries.map(\.isActive), [false, false, true])

        // Append with automatic newline vs --no-newline
        let appended = await env.runCLI(["append", "2", "--text", "Extra TODO line", "--json"])
        XCTAssertEqual(appended.exitCode, 0, appended.stderr)
        let appendedDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(appended.stdout.utf8))
        XCTAssertTrue(appendedDetail.text.hasSuffix("TODO: ship ipc\nExtra TODO line"))

        let appendedInline = await env.runCLI(["append", "Second", "--text", "!", "--no-newline", "--json"])
        XCTAssertEqual(appendedInline.exitCode, 0, appendedInline.stderr)
        let inlineDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(appendedInline.stdout.utf8))
        XCTAssertTrue(inlineDetail.text.hasSuffix("Extra TODO line!"))

        // Get by UUID prefix and --active
        let idPrefix = String(addedDetail.id.prefix(8))
        let gotByPrefix = await env.runCLI(["get", idPrefix, "--json"])
        XCTAssertEqual(gotByPrefix.exitCode, 0)
        let gotDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(gotByPrefix.stdout.utf8))
        XCTAssertEqual(gotDetail.id, addedDetail.id)

        let gotActive = await env.runCLI(["get", "--json"])
        XCTAssertEqual(gotActive.exitCode, 0)
        let activeDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(gotActive.stdout.utf8))
        XCTAssertEqual(activeDetail.id, pipedDetail.id)

        // Search across notes
        let searched = await env.runCLI(["search", "todo", "--json"])
        XCTAssertEqual(searched.exitCode, 0)
        let matches = try JSONDecoder().decode([SearchMatchPayload].self, from: Data(searched.stdout.utf8))
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.map(\.line), [3, 4])
        XCTAssertEqual(matches[0].title, "Second Header")

        // Update & delete, plus guard against deleting the last remaining note
        let updated = await env.runCLI(["update", "1", "--text", "# Updated First\nFresh content", "--json"])
        XCTAssertEqual(updated.exitCode, 0)

        let del3 = await env.runCLI(["delete", pipedDetail.id, "--json"])
        XCTAssertEqual(del3.exitCode, 0, del3.stderr)
        let del2 = await env.runCLI(["delete", "2", "--json"])
        XCTAssertEqual(del2.exitCode, 0, del2.stderr)

        let delLast = await env.runCLI(["delete", "1", "--json"])
        XCTAssertNotEqual(delLast.exitCode, 0)
        XCTAssertTrue(delLast.stderr.contains("last remaining note"))

        // Re-open NoteStore and verify offline CLI changes win via savedAt
        let reopenedStore = NoteStore(defaults: env.defaults, archiveURL: env.archiveURL)
        XCTAssertEqual(reopenedStore.tabs.count, 1)
        XCTAssertEqual(reopenedStore.title(for: reopenedStore.activeTabID), "Updated First")
        XCTAssertEqual(reopenedStore.text, "# Updated First\nFresh content")
    }

    func testOnlineIPCServerSyncsLiveStoreShelfAndPanelWithoutStaleOverwrite() async throws {
        let env = try makeIsolatedEnvironment()
        defer { env.cleanUp() }

        let store = NoteStore(defaults: env.defaults, archiveURL: env.archiveURL)
        store.updateText("# Live App Note\nInitial body")
        let shelfStore = FileShelfStore(defaults: env.defaults)

        var panelExpanded = false
        let server = NotchNotesIPCServer(
            store: store,
            fileShelfStore: shelfStore,
            socketPath: env.socketPath
        ) { command in
            switch command {
            case .open:
                panelExpanded = true
            case .close:
                panelExpanded = false
            case .toggle:
                panelExpanded.toggle()
            }
            return panelExpanded
        }
        try server.start()
        defer { server.stop() }

        // Live append mutates running NoteStore on @MainActor immediately
        let appendRes = await env.runCLI(["append", "--active", "--text", "- [ ] Added from CLI", "--json"])
        XCTAssertEqual(appendRes.exitCode, 0, appendRes.stderr)
        XCTAssertEqual(store.text, "# Live App Note\nInitial body\n- [ ] Added from CLI")

        // Live add without --select keeps current active tab; with --select switches active tab
        let originalActiveID = store.activeTabID
        let bgAdd = await env.runCLI(["add", "--text", "# Background Tab", "--json"])
        XCTAssertEqual(bgAdd.exitCode, 0)
        XCTAssertEqual(store.tabs.count, 2)
        XCTAssertEqual(store.activeTabID, originalActiveID)

        let fgAdd = await env.runCLI(["add", "--text", "# Focused Tab", "--select", "--json"])
        XCTAssertEqual(fgAdd.exitCode, 0)
        XCTAssertEqual(store.tabs.count, 3)
        XCTAssertEqual(store.title(for: store.activeTabID), "Focused Tab")

        // Flushing store afterward must preserve all IPC writes rather than overwriting with stale state
        store.flush()
        let reloaded = NoteStore(defaults: env.defaults, archiveURL: env.archiveURL)
        XCTAssertEqual(reloaded.tabs.count, 3)
        XCTAssertEqual(reloaded.tabs[0].text, "# Live App Note\nInitial body\n- [ ] Added from CLI")

        // Live file shelf operations (relative path resolution, list, remove, clear)
        let sampleA = env.directory.appendingPathComponent("alpha.txt")
        let sampleB = env.directory.appendingPathComponent("beta.pdf")
        try Data("a".utf8).write(to: sampleA)
        try Data("b".utf8).write(to: sampleB)

        let shelfAdd = await env.runCLI(
            ["shelf", "add", "alpha.txt", sampleB.path, "--json"],
            currentDirectoryPath: env.directory.path
        )
        XCTAssertEqual(shelfAdd.exitCode, 0, shelfAdd.stderr)
        XCTAssertEqual(shelfStore.items.count, 2)

        let shelfList = await env.runCLI(["shelf", "list", "--json"])
        let listedItems = try JSONDecoder().decode([ShelfItemPayload].self, from: Data(shelfList.stdout.utf8))
        XCTAssertEqual(listedItems.map(\.name), ["alpha.txt", "beta.pdf"])
        XCTAssertTrue(listedItems.allSatisfy(\.exists))

        let shelfRemove = await env.runCLI(["shelf", "remove", listedItems[0].id, "--json"])
        XCTAssertEqual(shelfRemove.exitCode, 0, shelfRemove.stderr)
        XCTAssertEqual(shelfStore.items.map(\.originalName), ["beta.pdf"])

        let shelfClear = await env.runCLI(["shelf", "clear", "--json"])
        XCTAssertEqual(shelfClear.exitCode, 0)
        XCTAssertTrue(shelfStore.items.isEmpty)

        // Panel open / toggle / close over IPC
        let openPanel = await env.runCLI(["panel", "open", "--json"])
        XCTAssertEqual(openPanel.exitCode, 0)
        XCTAssertTrue(panelExpanded)

        let togglePanel = await env.runCLI(["panel", "toggle", "--json"])
        XCTAssertEqual(togglePanel.exitCode, 0)
        XCTAssertFalse(panelExpanded)
    }

    func testStaleSocketRecoveryOfflineFallbackAndDuplicateServerGuard() async throws {
        let env = try makeIsolatedEnvironment()
        defer { env.cleanUp() }

        // Create a real stale Unix Domain Socket (bound & closed without unlink -> ECONNREFUSED)
        do {
            var addr = try IPCSocketSecurity.makeSockAddrUn(path: env.socketPath)
            let staleFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            XCTAssertGreaterThanOrEqual(staleFD, 0)
            let bindRC = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.bind(staleFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            XCTAssertEqual(bindRC, 0)
            _ = Darwin.close(staleFD)
        }

        // Offline CLI should gracefully fall back when socket returns ECONNREFUSED
        let offlineWrite = await env.runCLI(["update", "--active", "--text", "# Written While Stale", "--json"])
        XCTAssertEqual(offlineWrite.exitCode, 0, offlineWrite.stderr)

        // Starting IPCServer should detect ECONNREFUSED, unlink stale socket, and bind cleanly
        let store = NoteStore(defaults: env.defaults, archiveURL: env.archiveURL)
        let shelfStore = FileShelfStore(defaults: env.defaults)
        let server = NotchNotesIPCServer(store: store, fileShelfStore: shelfStore, socketPath: env.socketPath)
        try server.start()
        defer { server.stop() }

        let liveGet = await env.runCLI(["get", "--json"])
        XCTAssertEqual(liveGet.exitCode, 0)
        let detail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(liveGet.stdout.utf8))
        XCTAssertEqual(detail.title, "Written While Stale")

        // A second server attempting to bind the same live socket must fail without unlinking it
        let duplicateServer = NotchNotesIPCServer(store: store, fileShelfStore: shelfStore, socketPath: env.socketPath)
        XCTAssertThrowsError(try duplicateServer.start()) { error in
            XCTAssertEqual(error as? IPCSocketError, .socketAlreadyInUse(env.socketPath))
        }

        // Original server remains healthy
        let stillAlive = await env.runCLI(["list", "--json"])
        XCTAssertEqual(stillAlive.exitCode, 0)
    }

    func testPeerUIDVerificationDirectoryPermissionsAndCLIInstaller() throws {
        let env = try makeIsolatedEnvironment()
        defer { env.cleanUp() }

        // 1. Verify getpeereid passes for getuid() and rejects mismatched UID
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer {
            _ = Darwin.close(pair[0])
            _ = Darwin.close(pair[1])
        }
        XCTAssertNoThrow(try IPCSocketSecurity.verifyPeerUID(fd: pair[0], expectedUID: Darwin.getuid()))
        XCTAssertThrowsError(try IPCSocketSecurity.verifyPeerUID(fd: pair[0], expectedUID: Darwin.getuid() &+ 1)) { err in
            XCTAssertEqual(err as? IPCSocketError, .unauthorizedPeer(Darwin.getuid()))
        }

        // 2. Verify private directory enforces 0700 and rejects symlinked directory
        let privateDir = env.directory.appendingPathComponent("priv-sock-dir", isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let privateSockPath = privateDir.appendingPathComponent("ipc.sock").path
        try IPCSocketSecurity.prepareSecureParentDirectory(for: privateSockPath, enforceStrictPrivateDir: true)
        var st = Darwin.stat()
        XCTAssertEqual(Darwin.lstat(privateDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)

        let symlinkDir = env.directory.appendingPathComponent("symlink-sock-dir")
        try FileManager.default.createSymbolicLink(at: symlinkDir, withDestinationURL: privateDir)
        XCTAssertThrowsError(
            try IPCSocketSecurity.prepareSecureParentDirectory(
                for: symlinkDir.appendingPathComponent("ipc.sock").path,
                enforceStrictPrivateDir: true
            )
        )

        // 3. Verify CLIInstaller fallback to ~/.local/bin and broken symlink replacement
        let fakeAppURL = env.directory.appendingPathComponent("NotchNotes.app", isDirectory: true)
        let macOSDir = fakeAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        let fakeBinary = macOSDir.appendingPathComponent("notch-notes")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: fakeBinary)
        XCTAssertEqual(Darwin.chmod(fakeBinary.path, 0o755), 0)

        let fakeHome = env.directory.appendingPathComponent("home", isDirectory: true)
        let unwritableUsrLocal = env.directory.appendingPathComponent("nonexistent-root-bin", isDirectory: true)

        let localBinDir = fakeHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: localBinDir, withIntermediateDirectories: true)
        let danglingLink = localBinDir.appendingPathComponent("notch-notes")
        try FileManager.default.createSymbolicLink(
            atPath: danglingLink.path,
            withDestinationPath: "/nonexistent/old/notch-notes"
        )

        let installResult = try CLIInstaller.install(
            bundleURL: fakeAppURL,
            usrLocalBinURL: unwritableUsrLocal,
            homeDirectoryURL: fakeHome,
            pathEnvironment: "/usr/bin:/bin"
        )
        XCTAssertTrue(installResult.usedLocalBinFallback)
        XCTAssertFalse(installResult.isInPATH)
        XCTAssertEqual(installResult.destinationURL.path, danglingLink.path)
        XCTAssertTrue(installResult.message.contains("export PATH="))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: danglingLink.path),
            fakeBinary.path
        )
    }

    func testAgentSkillSetupResolvesBundledPathsAndGeneratesLocalizedPrompts() throws {
        let env = try makeIsolatedEnvironment()
        defer { env.cleanUp() }

        let fakeAppURL = env.directory.appendingPathComponent("NotchNotes.app", isDirectory: true)
        let missingAppURL = env.directory.appendingPathComponent("Missing.app", isDirectory: true)

        XCTAssertNil(
            AgentSkillSetup.resolvedSkillFileURL(
                bundleURL: fakeAppURL,
                applicationsAppURL: missingAppURL
            )
        )
        XCTAssertEqual(
            AgentSkillSetup.resolvedCLIBinaryPath(
                bundleURL: fakeAppURL,
                applicationsAppURL: missingAppURL
            ),
            "/Applications/NotchNotes.app/Contents/MacOS/notch-notes"
        )

        let macOSDir = fakeAppURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let skillDir = fakeAppURL.appendingPathComponent("Contents/Resources/Skills/notch-notes", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

        let fakeBinary = macOSDir.appendingPathComponent("notch-notes")
        try Data("#!/bin/sh\necho ok\n".utf8).write(to: fakeBinary)
        XCTAssertEqual(Darwin.chmod(fakeBinary.path, 0o755), 0)

        let bundledSkill = skillDir.appendingPathComponent("SKILL.md")
        try Data("# NotchNotes Skill\n".utf8).write(to: bundledSkill)

        XCTAssertEqual(
            AgentSkillSetup.resolvedSkillFileURL(
                bundleURL: fakeAppURL,
                applicationsAppURL: missingAppURL
            )?.path,
            bundledSkill.path
        )
        XCTAssertEqual(
            AgentSkillSetup.resolvedCLIBinaryPath(
                bundleURL: fakeAppURL,
                applicationsAppURL: missingAppURL
            ),
            fakeBinary.path
        )

        let zhPrompt = AgentSkillSetup.installPrompt(
            isChinese: true,
            bundleURL: fakeAppURL,
            applicationsAppURL: missingAppURL
        )
        XCTAssertTrue(zhPrompt.contains(fakeBinary.path))
        XCTAssertTrue(zhPrompt.contains(bundledSkill.path))
        XCTAssertTrue(zhPrompt.contains("~/.claude/skills/notch-notes/SKILL.md"))
        XCTAssertTrue(zhPrompt.contains("list --json"))

        let enPrompt = AgentSkillSetup.installPrompt(
            isChinese: false,
            bundleURL: fakeAppURL,
            applicationsAppURL: missingAppURL
        )
        XCTAssertTrue(enPrompt.contains(fakeBinary.path))
        XCTAssertTrue(enPrompt.contains(bundledSkill.path))
        XCTAssertTrue(enPrompt.contains("~/.agents/skills/notch-notes/SKILL.md"))
        XCTAssertTrue(enPrompt.contains("list --json"))
    }

    func testCLIArgumentQuotingNumericTargetValidationAndCleanStoreFlushPreservation() async throws {
        let env = try makeIsolatedEnvironment()
        defer { env.cleanUp() }

        let seed = await env.runCLI(["update", "1", "--text", "99 Bottles"])
        XCTAssertEqual(seed.exitCode, 0, seed.stderr)

        // `--text "--json"` consumes `--json` as value rather than global flag.
        let addedLiteralJson = await env.runCLI(["add", "--text", "--json"])
        XCTAssertEqual(addedLiteralJson.exitCode, 0, addedLiteralJson.stderr)
        XCTAssertNil(try? JSONDecoder().decode(NoteDetailPayload.self, from: Data(addedLiteralJson.stdout.utf8)))
        let gotLiteralJson = await env.runCLI(["get", "2", "--json"])
        XCTAssertEqual(gotLiteralJson.exitCode, 0, gotLiteralJson.stderr)
        XCTAssertEqual(
            try JSONDecoder().decode(NoteDetailPayload.self, from: Data(gotLiteralJson.stdout.utf8)).text,
            "--json"
        )

        // `append 1 --text "--json" --no-newline` consumes `--json` as value and appends without newline.
        let appendedLiteral = await env.runCLI(["append", "1", "--text", "--json", "--no-newline"])
        XCTAssertEqual(appendedLiteral.exitCode, 0, appendedLiteral.stderr)
        XCTAssertNil(try? JSONDecoder().decode(NoteDetailPayload.self, from: Data(appendedLiteral.stdout.utf8)))
        let gotNote1 = await env.runCLI(["get", "1", "--json"])
        XCTAssertEqual(gotNote1.exitCode, 0, gotNote1.stderr)
        XCTAssertEqual(
            try JSONDecoder().decode(NoteDetailPayload.self, from: Data(gotNote1.stdout.utf8)).text,
            "99 Bottles--json"
        )

        // `add --text "--help" --json` stores literal `--help` instead of printing help.
        let addedHelp = await env.runCLI(["add", "--text", "--help", "--json"])
        XCTAssertEqual(addedHelp.exitCode, 0, addedHelp.stderr)
        let helpDetail = try JSONDecoder().decode(NoteDetailPayload.self, from: Data(addedHelp.stdout.utf8))
        XCTAssertEqual(helpDetail.text, "--help")

        // `search --json -- -h` treats `-h` after `--` as search query instead of help flag.
        let searched = await env.runCLI(["search", "--json", "--", "-h"])
        XCTAssertEqual(searched.exitCode, 0, searched.stderr)
        let searchMatches = try JSONDecoder().decode([SearchMatchPayload].self, from: Data(searched.stdout.utf8))
        XCTAssertEqual(searchMatches.map(\.id), [helpDetail.id])

        // Out-of-range numeric target must fail rather than prefix-matching "99 Bottles--json".
        let outOfRange = await env.runCLI(["get", "99", "--json"])
        XCTAssertNotEqual(outOfRange.exitCode, 0)

        // `delete --active` must be rejected.
        let deleteActive = await env.runCLI(["delete", "--active"])
        XCTAssertNotEqual(deleteActive.exitCode, 0)

        // `shelf add` on a missing file must be rejected.
        let missingShelfFile = env.directory.appendingPathComponent("missing-file.txt").path
        let badShelfAdd = await env.runCLI(["shelf", "add", missingShelfFile])
        XCTAssertNotEqual(badShelfAdd.exitCode, 0)

        // Clean NoteStore.flush() must not overwrite newer offline CLI writes on disk.
        let cleanStore = NoteStore(defaults: env.defaults, archiveURL: env.archiveURL)
        let cliWrite = await env.runCLI(["add", "--text", "Fresh Offline Write", "--json"])
        XCTAssertEqual(cliWrite.exitCode, 0, cliWrite.stderr)
        cleanStore.flush(waitForDisk: true)

        let listedAfterFlush = await env.runCLI(["list", "--json"])
        XCTAssertEqual(listedAfterFlush.exitCode, 0, listedAfterFlush.stderr)
        let summaries = try JSONDecoder().decode([NoteSummaryPayload].self, from: Data(listedAfterFlush.stdout.utf8))
        XCTAssertTrue(summaries.contains { $0.title == "Fresh Offline Write" })

        cleanStore.reloadFromDiskIfClean()
        XCTAssertTrue(cleanStore.tabs.contains { $0.text == "Fresh Offline Write" })
    }

    private func makeIsolatedEnvironment() throws -> IsolatedCLIEnvironment {
        let shortID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let socketPath = "/tmp/nn-test-\(shortID).sock"
        let suiteName = "CLIIPCTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchNotesCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return IsolatedCLIEnvironment(
            suiteName: suiteName,
            defaults: defaults,
            directory: directory,
            archiveURL: directory.appendingPathComponent("notes.json"),
            socketPath: socketPath
        )
    }
}

private struct IsolatedCLIEnvironment: @unchecked Sendable {
    let suiteName: String
    let defaults: UserDefaults
    let directory: URL
    let archiveURL: URL
    let socketPath: String

    var environmentVariables: [String: String] {
        [
            NoteStorage.dataDirEnvKey: directory.path,
            NoteStorage.defaultsSuiteEnvKey: suiteName,
            IPCSocketSecurity.socketPathEnvKey: socketPath,
            NotchNotesCLIRunner.noAutoLaunchEnvKey: "1"
        ]
    }

    func runCLI(
        _ arguments: [String],
        currentDirectoryPath: String? = nil,
        stdinIsTTY: Bool = true,
        stdin: String = ""
    ) async -> CLIExecutionResult {
        let envVars = environmentVariables
        let cwd = currentDirectoryPath ?? directory.path
        return await Task.detached {
            NotchNotesCLIRunner.run(
                arguments: arguments,
                environment: envVars,
                currentDirectoryPath: cwd,
                stdinIsTTY: stdinIsTTY,
                readStdin: { stdin }
            )
        }.value
    }

    func cleanUp() {
        _ = Darwin.unlink(socketPath)
        defaults.removeTestSuiteAndPlist(named: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
