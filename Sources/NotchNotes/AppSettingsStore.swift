import Combine
import Foundation

enum TriggerMode: String, CaseIterable, Identifiable {
    case hover
    case click

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hover:
            return "Hover"
        case .click:
            return "Click"
        }
    }

    var systemImage: String {
        switch self {
        case .hover:
            return "cursorarrow.motionlines"
        case .click:
            return "cursorarrow.click.2"
        }
    }
}

@MainActor
final class AppSettingsStore: ObservableObject {
    @Published var triggerMode: TriggerMode {
        didSet {
            UserDefaults.standard.set(triggerMode.rawValue, forKey: Self.triggerModeKey)
        }
    }
    @Published private(set) var isKeepingAwake = false
    @Published private(set) var isChangingKeepAwake = false
    @Published private(set) var keepAwakeErrorMessage: String?

    private static let triggerModeKey = "notchNotes.triggerMode"
    private var caffeinateProcess: Process?
    private let systemSleepGuard = SystemSleepGuard()
    private var keepAwakeTask: Task<Void, Never>?

    init() {
        let rawMode = UserDefaults.standard.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover
    }

    func toggleKeepAwake() {
        guard !isChangingKeepAwake else { return }

        if isKeepingAwake {
            stopKeepingAwake()
        } else {
            requestKeepAwake()
        }
    }

    func stopKeepingAwake() {
        keepAwakeTask?.cancel()
        keepAwakeTask = nil
        systemSleepGuard.requestStop()
        isChangingKeepAwake = systemSleepGuard.isRunning

        let process = caffeinateProcess
        caffeinateProcess = nil
        isKeepingAwake = false

        if let process, process.isRunning {
            process.terminate()
        }

        guard systemSleepGuard.isRunning else {
            isChangingKeepAwake = false
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            await self.systemSleepGuard.waitUntilStopped()
            guard !Task.isCancelled else { return }
            self.isChangingKeepAwake = false
            self.keepAwakeTask = nil
        }
    }

    func dismissKeepAwakeError() {
        keepAwakeErrorMessage = nil
    }

    private func requestKeepAwake() {
        guard caffeinateProcess == nil, !systemSleepGuard.isRunning else { return }

        isChangingKeepAwake = true
        keepAwakeErrorMessage = nil

        do {
            try systemSleepGuard.start()
        } catch {
            isChangingKeepAwake = false
            keepAwakeErrorMessage = "Administrator permission is required to prevent sleep when the lid is closed."
            return
        }

        keepAwakeTask = Task { [weak self] in
            guard let self else { return }
            let isReady = await self.systemSleepGuard.waitUntilReady()
            guard !Task.isCancelled else { return }

            guard isReady, self.startCaffeinate() else {
                self.systemSleepGuard.requestStop()
                await self.systemSleepGuard.waitUntilStopped()
                self.isChangingKeepAwake = false
                self.keepAwakeErrorMessage = "Administrator permission is required to prevent sleep when the lid is closed."
                self.keepAwakeTask = nil
                return
            }

            self.isKeepingAwake = true
            self.isChangingKeepAwake = false
            self.keepAwakeTask = nil
        }
    }

    private func startCaffeinate() -> Bool {
        guard caffeinateProcess == nil else { return true }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [
            "-dims",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        do {
            try process.run()
            caffeinateProcess = process
            return true
        } catch {
            caffeinateProcess = nil
            return false
        }
    }
}
