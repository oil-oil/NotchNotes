import Darwin
import Foundation
import XCTest
@testable import SleepGuardCore

final class SystemSleepPowerTests: XCTestCase {
    func testRepeatedQueriesReleaseDescriptorsWithoutCallerAutoreleasePool() throws {
        let power = SystemSleepPower(executable: URL(fileURLWithPath: "/usr/bin/true"))
        _ = try power.isSleepDisabled() // Warm up Foundation before measuring.
        let baseline = descriptorCount()
        for _ in 0..<24 { _ = try power.isSleepDisabled() }
        XCTAssertEqual(descriptorCount(), baseline)
    }

    func testLaunchFailuresReleaseBothPipeEndsAndPreserveError() {
        let power = SystemSleepPower(executable: URL(fileURLWithPath: "/nonexistent/NotchNotes-test-command"))
        let baseline = descriptorCount()
        for _ in 0..<100 {
            XCTAssertThrowsError(try power.isSleepDisabled()) {
                XCTAssertEqual(($0 as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual(($0 as NSError).code, NSFileNoSuchFileError)
            }
        }
        XCTAssertEqual(descriptorCount(), baseline)
    }

    func testNonzeroExitsReleaseDescriptors() {
        let power = SystemSleepPower(executable: URL(fileURLWithPath: "/usr/bin/false"))
        let baseline = descriptorCount()
        for _ in 0..<6 { XCTAssertThrowsError(try power.isSleepDisabled()) }
        XCTAssertEqual(descriptorCount(), baseline)
    }

    func testTimeoutReapsChildAndReleasesDescriptors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNotesPowerTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let command = directory.appendingPathComponent("command")
        // exec keeps the PID unchanged and leaves no shell child behind.
        try "#!/bin/sh\necho $$ > \"$0.pid\"\ntrap '' TERM\nexec /bin/sleep 30\n".write(to: command, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
        let power = SystemSleepPower(executable: command)
        let baseline = descriptorCount()
        XCTAssertThrowsError(try power.isSleepDisabled()) {
            XCTAssertEqual($0.localizedDescription, "The macOS power command timed out.")
        }
        let text = try String(contentsOfFile: command.path + ".pid", encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(descriptorCount(), baseline)
    }

    private func descriptorCount() -> Int {
        // No descriptor is opened by this measurement.
        (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }
}
