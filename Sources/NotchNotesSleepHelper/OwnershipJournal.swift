import Darwin
import Foundation
import SleepGuardCore
import Security

final class OwnershipJournal: SleepOwnershipStoring {
    private let directory = "/var/db/io.github.oiloil.NotchNotes.SleepGuard"
    private var marker: String { directory + "/restore-sleep" }

    init() throws {
        if mkdir(directory, 0o700) != 0, errno != EEXIST {
            throw SleepGuardFailure("Couldn’t create the sleep recovery journal.")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == 0, info.st_mode & 0o077 == 0 else {
            throw SleepGuardFailure("The sleep recovery journal has unsafe permissions.")
        }
    }

    func protectedWorker(copying executable: URL) throws -> URL {
        // Never execute a user-writable app path as root after installation.
        // Copy into the root-only journal directory, then check the protected
        // copy against the running daemon's kernel-bound signing requirement.
        var ownCode: SecCode?
        var ownStaticCode: SecStaticCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &ownCode) == errSecSuccess, let ownCode,
              SecCodeCheckValidity(ownCode, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(ownCode, [], &ownStaticCode) == errSecSuccess, let ownStaticCode,
              SecCodeCopyDesignatedRequirement(ownStaticCode, [], &requirement) == errSecSuccess,
              let requirement else { throw SleepGuardFailure("Couldn’t verify the running sleep helper.") }
        let temporary = URL(fileURLWithPath: directory).appendingPathComponent(UUID().uuidString)
        let destination = URL(fileURLWithPath: directory).appendingPathComponent("NotchNotesSleepWorker")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw SleepGuardFailure("Couldn’t open the installed sleep helper.") }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 64 * 1024 * 1024 else {
            throw SleepGuardFailure("The installed sleep helper isn’t a regular executable.")
        }
        let destinationFD = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
        guard destinationFD >= 0 else { throw SleepGuardFailure("Couldn’t create the protected sleep worker.") }
        defer { close(destinationFD) }
        var remaining = info.st_size
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while remaining > 0 {
            let count = read(source, &buffer, min(buffer.count, Int(remaining)))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw SleepGuardFailure("Couldn’t copy the installed sleep helper.") }
            try buffer.withUnsafeBytes { bytes in
                var written = 0
                while written < count {
                    let result = write(destinationFD, bytes.baseAddress!.advanced(by: written), count - written)
                    if result < 0, errno == EINTR { continue }
                    guard result > 0 else { throw SleepGuardFailure("Couldn’t save the protected sleep worker.") }
                    written += result
                }
            }
            remaining -= off_t(count)
        }
        guard fsync(destinationFD) == 0 else { throw SleepGuardFailure("Couldn’t persist the protected sleep worker.") }
        var copiedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(temporary as CFURL, [], &copiedCode) == errSecSuccess,
              let copiedCode,
              SecStaticCodeCheckValidity(copiedCode, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw SleepGuardFailure("The installed sleep helper changed. Reinstall NotchNotes.")
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw SleepGuardFailure("Couldn’t protect the sleep watchdog executable.")
        }
        return destination
    }

    func withExclusiveLock(_ operation: () throws -> Void) throws {
        let descriptor = open(directory + "/lock", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw SleepGuardFailure("Couldn’t lock the sleep recovery journal.") }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                throw SleepGuardFailure("The previous keep-awake session is still restoring sleep. Please try again.")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        defer { flock(descriptor, LOCK_UN) }
        try operation()
    }

    func isOwned() throws -> Bool {
        var info = stat()
        if lstat(marker, &info) != 0 {
            if errno == ENOENT { return false }
            throw SleepGuardFailure("Couldn’t read the sleep recovery journal.")
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == 0 else {
            throw SleepGuardFailure("Invalid sleep recovery marker.")
        }
        return true
    }

    func setOwned(_ owned: Bool) throws {
        if owned {
            let descriptor = open(marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor < 0 {
                guard errno == EEXIST, try isOwned() else {
                    throw SleepGuardFailure("Couldn’t save the sleep recovery marker.")
                }
            } else {
                defer { close(descriptor) }
                guard fsync(descriptor) == 0 else {
                    throw SleepGuardFailure("Couldn’t persist the sleep recovery marker.")
                }
            }
        } else if unlink(marker) != 0, errno != ENOENT {
            throw SleepGuardFailure("Couldn’t clear the sleep recovery marker.")
        }
        let descriptor = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SleepGuardFailure("Couldn’t sync the recovery journal.") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SleepGuardFailure("Couldn’t sync the recovery journal.") }
    }
}
