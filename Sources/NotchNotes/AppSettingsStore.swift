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

    private static let triggerModeKey = "notchNotes.triggerMode"
    private var caffeinateProcess: Process?

    init() {
        let rawMode = UserDefaults.standard.string(forKey: Self.triggerModeKey)
        triggerMode = rawMode.flatMap(TriggerMode.init(rawValue:)) ?? .hover
    }

    func toggleKeepAwake() {
        if isKeepingAwake {
            stopKeepingAwake()
        } else {
            startKeepingAwake()
        }
    }

    func stopKeepingAwake() {
        let process = caffeinateProcess
        caffeinateProcess = nil
        isKeepingAwake = false

        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func startKeepingAwake() {
        guard caffeinateProcess == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = [
            "-di",
            "-w",
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        do {
            try process.run()
            caffeinateProcess = process
            isKeepingAwake = true
        } catch {
            caffeinateProcess = nil
            isKeepingAwake = false
        }
    }
}
