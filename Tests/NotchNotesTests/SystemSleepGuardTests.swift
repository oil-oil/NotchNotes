import Foundation
import XCTest
@testable import NotchNotes

final class SystemSleepGuardTests: XCTestCase {
    func testCommandDisablesSleepAndAlwaysRestoresIt() {
        let guardCommand = SystemSleepGuardCommand(
            appProcessID: 4321,
            readyFileURL: URL(fileURLWithPath: "/tmp/notch-notes.ready"),
            stopFileURL: URL(fileURLWithPath: "/tmp/notch-notes.stop")
        )
        let command = guardCommand.watcherCommand

        XCTAssertTrue(command.contains("'/usr/bin/pmset' -a disablesleep 1"))
        XCTAssertTrue(command.contains("SleepDisabled[[:space:]]+1"))
        XCTAssertTrue(command.contains("trap cleanup 0"))
        XCTAssertTrue(command.contains("trap 'exit 1' 1 2 15"))
        XCTAssertTrue(command.contains("'/usr/bin/pmset' -a disablesleep 0"))
        XCTAssertFalse(command.contains("original_state"))
        XCTAssertTrue(command.contains("/bin/kill -0 4321"))
        XCTAssertTrue(command.contains("[ ! -e '/tmp/notch-notes.stop' ]"))
        XCTAssertFalse(guardCommand.appleScript.contains("nohup"))
        XCTAssertTrue(guardCommand.appleScript.contains("do shell script"))
    }

    func testCommandQuotesTemporaryPaths() {
        let command = SystemSleepGuardCommand(
            appProcessID: 7,
            readyFileURL: URL(fileURLWithPath: "/tmp/notch notes' ready"),
            stopFileURL: URL(fileURLWithPath: "/tmp/notch notes' stop")
        ).watcherCommand

        XCTAssertTrue(command.contains("'/tmp/notch notes'\\'' ready'"))
        XCTAssertTrue(command.contains("'/tmp/notch notes'\\'' stop'"))
    }

    func testCommandIsValidShellSyntax() throws {
        let command = SystemSleepGuardCommand(
            appProcessID: 99,
            readyFileURL: URL(fileURLWithPath: "/tmp/notch-notes.ready"),
            stopFileURL: URL(fileURLWithPath: "/tmp/notch-notes.stop")
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", "-c", command.watcherCommand]

        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)

    }

    func testSleepDisabledParserRequiresEnabledValue() {
        XCTAssertTrue(SystemSleepGuardCommand.sleepIsDisabled(in: "SleepDisabled\t\t1\n"))
        XCTAssertFalse(SystemSleepGuardCommand.sleepIsDisabled(in: "SleepDisabled 0\n"))
        XCTAssertFalse(SystemSleepGuardCommand.sleepIsDisabled(in: "sleep 1\n"))
    }

    func testAppleScriptErrorsAreClassified() {
        XCTAssertEqual(
            SystemSleepGuardError.fromAppleScriptError("execution error: User canceled. (-128)"),
            .authorizationCancelled
        )
        XCTAssertEqual(
            SystemSleepGuardError.fromAppleScriptError("execution error: Not authorized. (-60005)"),
            .authorizationDenied
        )
    }

    func testWatcherLifecycleEnablesThenRestoresSleep() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NotchNotesSleepGuardTests-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let stateURL = directory.appendingPathComponent("state")
        let fakePMSetURL = directory.appendingPathComponent("pmset")
        let readyURL = directory.appendingPathComponent("watcher.ready")
        let stopURL = directory.appendingPathComponent("watcher.stop")
        try Data("0\n".utf8).write(to: stateURL)

        let fakePMSet = """
        #!/bin/sh
        state_file='\(stateURL.path)'
        if [ "$1" = "-a" ] && [ "$2" = "disablesleep" ]; then
            /usr/bin/printf '%s\n' "$3" > "$state_file"
            exit 0
        fi
        if [ "$1" = "-g" ]; then
            state_value=$(/bin/cat "$state_file")
            /usr/bin/printf 'SleepDisabled\\t\\t%s\\n' "$state_value"
            exit 0
        fi
        exit 1
        """
        try Data(fakePMSet.utf8).write(to: fakePMSetURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakePMSetURL.path
        )

        let command = SystemSleepGuardCommand(
            appProcessID: ProcessInfo.processInfo.processIdentifier,
            readyFileURL: readyURL,
            stopFileURL: stopURL,
            pmsetExecutable: fakePMSetURL.path
        )
        let watcher = Process()
        watcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        watcher.arguments = ["-c", command.watcherCommand]
        try watcher.run()
        defer {
            fileManager.createFile(atPath: stopURL.path, contents: Data())
            if watcher.isRunning {
                watcher.terminate()
            }
        }

        XCTAssertTrue(waitUntil { fileManager.fileExists(atPath: readyURL.path) })
        XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), "1\n")

        fileManager.createFile(atPath: stopURL.path, contents: Data())
        XCTAssertTrue(waitUntil { !watcher.isRunning })
        XCTAssertEqual(watcher.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), "0\n")
        XCTAssertFalse(fileManager.fileExists(atPath: readyURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: stopURL.path))
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }
}
