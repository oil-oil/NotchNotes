import Foundation
import XCTest
import SleepGuardCore
@testable import NotchNotesSleepHelper

final class WatchdogProcessTests: XCTestCase {
    func testLateRenewFromAnotherConnectionDoesNotRevokeActiveSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNotesWatchdogTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker")
        let script = """
        #!/bin/bash
        printf 'READY\\n'
        while IFS= read -r -t 2 stamp; do printf 'ALIVE\\n'; done
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let watchdog = WatchdogProcess(executable: executable, journal: EmptyJournal())
        let session = UUID()
        defer { try? watchdog.shutdown() }
        try watchdog.begin(session: session)

        XCTAssertThrowsError(try watchdog.renew(session: UUID()))
        XCTAssertNoThrow(try watchdog.renew(session: session))
        XCTAssertNoThrow(try watchdog.end(session: session))
    }
}

private struct EmptyJournal: SleepOwnershipStoring {
    func isOwned() throws -> Bool { false }
    func setOwned(_ owned: Bool) throws {}
}
