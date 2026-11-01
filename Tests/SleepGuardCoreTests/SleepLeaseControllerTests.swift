import Foundation
import XCTest
@testable import SleepGuardCore

final class SleepLeaseControllerTests: XCTestCase {
    private let session = UUID()

    func testNormalDisconnectRestoresSleepAndClearsJournal() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        XCTAssertTrue(fixture.power.disabled)
        XCTAssertTrue(fixture.journal.owned)
        XCTAssertTrue(fixture.power.wasJournaledBeforeEnabling)

        try fixture.controller.end(session: session)
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
    }

    func testMissingHeartbeatsRestoreSleepAndLateHeartbeatCannotReactivateIt() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        fixture.clock.time = 7
        try fixture.controller.renew(session: session)
        fixture.clock.time = 14
        try fixture.controller.tick()
        XCTAssertTrue(fixture.power.disabled)

        fixture.clock.time = 15
        try fixture.controller.tick()
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
        XCTAssertThrowsError(try fixture.controller.renew(session: session))
        XCTAssertFalse(fixture.power.disabled)
    }

    func testDaemonRestartRecoversStateLeftByKilledHelper() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        let restarted = SleepLeaseController(power: fixture.power, ownership: fixture.journal)

        try restarted.recoverAfterRestart()
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
        XCTAssertThrowsError(try restarted.renew(session: session))
    }

    func testGracefulHelperShutdownRestoresSleep() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        try fixture.controller.shutdown()
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
    }

    func testRecoveryFailureRetainsJournalAndRetriesWithoutClient() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        fixture.power.failRestore = true
        XCTAssertThrowsError(try fixture.controller.end(session: session))
        XCTAssertTrue(fixture.journal.owned)
        XCTAssertTrue(fixture.power.disabled)

        fixture.power.failRestore = false
        try fixture.controller.tick()
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
    }

    func testFailureToJournalNeverDisablesSleep() {
        let fixture = Fixture()
        fixture.journal.failWrite = true
        XCTAssertThrowsError(try fixture.controller.begin(session: session))
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertTrue(fixture.power.changes.isEmpty)
    }

    func testUnverifiedEnableRollsBackAndNeverStartsSession() {
        let fixture = Fixture()
        fixture.power.ignoreEnable = true
        XCTAssertThrowsError(try fixture.controller.begin(session: session))
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
        XCTAssertThrowsError(try fixture.controller.renew(session: session))
    }

    func testUnverifiedRestoreKeepsJournalUntilConfirmed() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        fixture.power.ignoreRestore = true
        XCTAssertThrowsError(try fixture.controller.end(session: session))
        XCTAssertTrue(fixture.journal.owned)
        fixture.power.ignoreRestore = false
        try fixture.controller.tick()
        XCTAssertFalse(fixture.journal.owned)
    }

    func testOtherConnectionCannotRenewOrStopActiveSession() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        let other = UUID()
        XCTAssertThrowsError(try fixture.controller.begin(session: other))
        XCTAssertThrowsError(try fixture.controller.renew(session: other))
        XCTAssertThrowsError(try fixture.controller.recoverLegacySleep())
        try fixture.controller.end(session: other)
        XCTAssertTrue(fixture.power.disabled)
        try fixture.controller.end(session: session)
        XCTAssertFalse(fixture.power.disabled)
    }

    func testDoesNotTakeOverExternalSleepSetting() throws {
        let fixture = Fixture()
        fixture.power.disabled = true
        XCTAssertThrowsError(try fixture.controller.begin(session: session))
        try fixture.controller.tick()
        try fixture.controller.shutdown()
        XCTAssertTrue(fixture.power.disabled)
        XCTAssertTrue(fixture.power.changes.isEmpty)
    }

    func testExplicitLegacyRecoveryRestoresOldPersistentSetting() throws {
        let fixture = Fixture()
        fixture.power.disabled = true
        try fixture.controller.recoverLegacySleep()
        XCTAssertFalse(fixture.power.disabled)
        XCTAssertFalse(fixture.journal.owned)
    }

    func testExternalStopEndsLeaseInsteadOfReenablingSleepPrevention() throws {
        let fixture = Fixture()
        try fixture.controller.begin(session: session)
        fixture.power.disabled = false
        XCTAssertThrowsError(try fixture.controller.renew(session: session))
        XCTAssertFalse(fixture.journal.owned)
        XCTAssertFalse(fixture.power.disabled)
    }
}

private final class Clock { var time: TimeInterval = 0 }

private final class Journal: SleepOwnershipStoring {
    var owned = false
    var failWrite = false
    func isOwned() throws -> Bool { owned }
    func setOwned(_ value: Bool) throws {
        if failWrite { throw SleepGuardFailure("Journal unavailable") }
        owned = value
    }
}

private final class Power: SleepPowerControlling {
    let journal: Journal
    var disabled = false
    var failRestore = false
    var ignoreRestore = false
    var ignoreEnable = false
    var changes: [Bool] = []
    var wasJournaledBeforeEnabling = false
    init(journal: Journal) { self.journal = journal }
    func isSleepDisabled() throws -> Bool { disabled }
    func setSleepDisabled(_ value: Bool) throws {
        if !value && failRestore { throw SleepGuardFailure("Restore failed") }
        changes.append(value)
        if value { wasJournaledBeforeEnabling = journal.owned }
        if (value && ignoreEnable) || (!value && ignoreRestore) { return }
        disabled = value
    }
}

private final class Fixture {
    let clock = Clock()
    let journal = Journal()
    let power: Power
    let controller: SleepLeaseController
    init() {
        power = Power(journal: journal)
        controller = SleepLeaseController(power: power, ownership: journal, now: { [clock] in clock.time })
    }
}
