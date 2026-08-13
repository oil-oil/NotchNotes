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

        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep 1"))
        XCTAssertTrue(command.contains("SleepDisabled[[:space:]]+1"))
        XCTAssertTrue(command.contains("trap cleanup 0"))
        XCTAssertTrue(command.contains("trap 'exit 1' 1 2 15"))
        XCTAssertTrue(command.contains("/usr/bin/pmset -a disablesleep 0"))
        XCTAssertFalse(command.contains("original_state"))
        XCTAssertTrue(command.contains("/bin/kill -0 4321"))
        XCTAssertTrue(command.contains("[ ! -e '/tmp/notch-notes.stop' ]"))
        XCTAssertTrue(guardCommand.launcherCommand.contains("/usr/bin/nohup /bin/sh -c"))
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

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = ["-n", "-c", command.launcherCommand]
        try launcher.run()
        launcher.waitUntilExit()

        XCTAssertEqual(launcher.terminationStatus, 0)
    }

    func testSleepDisabledParserRequiresEnabledValue() {
        XCTAssertTrue(SystemSleepGuardCommand.sleepIsDisabled(in: "SleepDisabled\t\t1\n"))
        XCTAssertFalse(SystemSleepGuardCommand.sleepIsDisabled(in: "SleepDisabled 0\n"))
        XCTAssertFalse(SystemSleepGuardCommand.sleepIsDisabled(in: "sleep 1\n"))
    }
}
