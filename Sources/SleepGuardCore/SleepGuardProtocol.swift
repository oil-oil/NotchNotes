import Foundation
import Security

public enum SleepGuardService {
    public static let appIdentifier = "io.github.oiloil.NotchNotes"
    public static let identifier = "io.github.oiloil.NotchNotes.SleepGuard"
    public static let plistName = identifier + ".plist"
    public static let helperName = "NotchNotesSleepHelper"
    public static let leaseDuration: TimeInterval = 8

    // Derive the requirement from the bundled peer, including its signing anchor
    // (or exact cdhash for ad-hoc builds). Never trust an identifier alone or a PID.
    public static func signingRequirement(
        for executable: URL,
        expectedIdentifier: String = identifier,
        sameSignerAs trustedExecutable: URL? = nil
    ) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess,
              let text else {
            throw SleepGuardFailure("The keep-awake helper’s code signature couldn’t be verified. Reinstall NotchNotes.")
        }
        let info = try signingInfo(for: executable)
        guard info[kSecCodeInfoIdentifier] as? String == expectedIdentifier else {
            throw SleepGuardFailure("The keep-awake connection has an unexpected signing identity.")
        }
        if let trustedExecutable {
            let trusted = try signingInfo(for: trustedExecutable)
            guard info[kSecCodeInfoTeamIdentifier] as? String == trusted[kSecCodeInfoTeamIdentifier] as? String else {
                throw SleepGuardFailure("NotchNotes and its helper must be signed by the same developer.")
            }
        }
        return text as String
    }

    private static func signingInfo(for executable: URL) throws -> [CFString: Any] {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &code) == errSecSuccess,
              let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [CFString: Any] else {
            throw SleepGuardFailure("Couldn’t read the keep-awake code signature.")
        }
        return info
    }
}

@objc public protocol SleepGuardXPC {
    func begin(withReply reply: @escaping @Sendable (Bool, String?) -> Void)
    func renew(withReply reply: @escaping @Sendable (Bool, String?) -> Void)
    func recoverOwnedSleep(withReply reply: @escaping @Sendable (Bool, String?) -> Void)
    func recoverLegacySleep(withReply reply: @escaping @Sendable (Bool, String?) -> Void)
}

public struct SleepGuardFailure: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum SleepGuardPowerState {
    public static func isDisabled(in output: String) -> Bool {
        output.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= 2 && fields[0] == "SleepDisabled" && fields[1] == "1"
        }
    }
}
