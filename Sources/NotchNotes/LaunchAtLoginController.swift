import Foundation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    init(_ systemStatus: SMAppService.Status) {
        switch systemStatus {
        case .notRegistered:
            self = .notRegistered
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .requiresApproval
        case .notFound:
            self = .notFound
        @unknown default:
            self = .notFound
        }
    }

    var isEnabled: Bool {
        self == .enabled
    }
}

enum LaunchAtLoginError: Error, Equatable, LocalizedError {
    case approvalRequired
    case notPackaged
    case registrationFailed(String)
    case unregistrationFailed(String)

    var userMessage: String {
        userMessage(for: .english)
    }

    func userMessage(for language: AppLanguage = .english) -> String {
        AppStrings(language: language).launchAtLoginErrorMessage(self)
    }

    var errorDescription: String? {
        userMessage
    }
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject {
    var canConfigure: Bool { get }
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
    func openApprovalSettings()
}

extension LaunchAtLoginControlling {
    func openApprovalSettings() {
        SystemSleepGuard.openApprovalSettings()
    }
}

@MainActor
final class LaunchAtLoginController: LaunchAtLoginControlling {
    private let bundleURLProvider: () -> URL

    init(bundleURLProvider: @escaping () -> URL = { Bundle.main.bundleURL }) {
        self.bundleURLProvider = bundleURLProvider
    }

    var canConfigure: Bool {
        bundleURLProvider().pathExtension == "app"
    }

    var status: LaunchAtLoginStatus {
        guard canConfigure else { return .notFound }
        return LaunchAtLoginStatus(SMAppService.mainApp.status)
    }

    func register() throws {
        guard canConfigure else {
            throw LaunchAtLoginError.notPackaged
        }

        let service = SMAppService.mainApp
        if service.status == .notRegistered || service.status == .notFound {
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval {
                    throw LaunchAtLoginError.approvalRequired
                }
                throw LaunchAtLoginError.registrationFailed(error.localizedDescription)
            }
        }

        switch service.status {
        case .enabled:
            return
        case .requiresApproval:
            throw LaunchAtLoginError.approvalRequired
        default:
            throw LaunchAtLoginError.registrationFailed("macOS didn’t enable Launch at Login. Please try again.")
        }
    }

    func unregister() throws {
        guard canConfigure else { return }

        let service = SMAppService.mainApp
        guard service.status == .enabled || service.status == .requiresApproval else {
            return
        }

        do {
            try service.unregister()
        } catch {
            throw LaunchAtLoginError.unregistrationFailed(error.localizedDescription)
        }
    }

    func openApprovalSettings() {
        SystemSleepGuard.openApprovalSettings()
    }
}
