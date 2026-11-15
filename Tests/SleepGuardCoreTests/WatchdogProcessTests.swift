import Darwin
import Foundation
import XCTest
import SleepGuardCore
@testable import NotchNotesSleepHelper

final class WatchdogProcessTests: XCTestCase {
    func testRuntimeFailureKeepsItsCategoryAcrossWorkerPipe() throws {
        let failure = SleepGuardFailure("Power-setting conflict", code: .powerConflict)
        try withWorker(finalReply: "ERROR: " + failure.wireMessage) { watchdog, session in
            XCTAssertThrowsError(try watchdog.renew(session: session)) { error in
                XCTAssertEqual((error as? SleepGuardFailure)?.code, .powerConflict)
                XCTAssertEqual(error.localizedDescription, failure.message)
            }
        }
    }

    func testClosedPipeIsWorkerExitRatherThanTimeout() throws {
        try withWorker(finalReply: nil) { watchdog, session in
            XCTAssertThrowsError(try watchdog.renew(session: session)) { error in
                XCTAssertEqual((error as? SleepGuardFailure)?.code, .workerExited)
            }
        }
    }

    func testCleanupFailureDoesNotReplaceOriginalSessionError() throws {
        let failure = SleepGuardFailure("Original session failure", code: .powerConflict)
        try withWorker(finalReply: "ERROR: " + failure.wireMessage, journal: FailingJournal()) { watchdog, session in
            XCTAssertThrowsError(try watchdog.renew(session: session)) {
                XCTAssertEqual(($0 as? SleepGuardFailure)?.code, .powerConflict)
                XCTAssertEqual($0.localizedDescription, failure.message)
            }
        }
    }

    func testFailedLaunchesReleaseAllConnectionDescriptors() {
        let watchdog = WatchdogProcess(executable: URL(fileURLWithPath: "/nonexistent/NotchNotes-test-worker"), journal: EmptyJournal())
        let baseline = descriptorCount()
        for _ in 0..<100 { XCTAssertThrowsError(try watchdog.begin(session: UUID())) }
        XCTAssertEqual(descriptorCount(), baseline)
    }

    func testFailedRecoveryRepliesReleaseDescriptorsAndAllowRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNotesRecoveryTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker")
        try "#!/bin/sh\nprintf 'ERROR: recovery rejected\\n'\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let watchdog = WatchdogProcess(executable: executable, journal: OwnedJournal())
        let baseline = descriptorCount()
        for _ in 0..<20 {
            XCTAssertThrowsError(try watchdog.recoverAfterRestart()) {
                XCTAssertEqual($0.localizedDescription, "recovery rejected")
            }
        }
        XCTAssertEqual(descriptorCount(), baseline)
    }

    private func descriptorCount() -> Int {
        (0..<4096).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }

    private func withWorker(
        finalReply: String?,
        journal: any SleepOwnershipStoring = EmptyJournal(),
        body: (WatchdogProcess, UUID) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNotesReplyTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("worker")
        let lastLine = finalReply.map { "printf '%s\\n' '\($0)'" } ?? "exit 0"
        let script = "#!/bin/bash\nprintf 'READY\\n'\nIFS= read -r stamp\nprintf 'ALIVE\\n'\nIFS= read -r stamp\n" + lastLine + "\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let watchdog = WatchdogProcess(executable: executable, journal: journal)
        defer { try? watchdog.shutdown() }
        let session = UUID()
        try watchdog.begin(session: session)
        try body(watchdog, session)
    }

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

private struct FailingJournal: SleepOwnershipStoring {
    func isOwned() throws -> Bool { throw SleepGuardFailure("Cleanup journal failure") }
    func setOwned(_ owned: Bool) throws {}
}

private struct OwnedJournal: SleepOwnershipStoring {
    func isOwned() throws -> Bool { true }
    func setOwned(_ owned: Bool) throws {}
}
