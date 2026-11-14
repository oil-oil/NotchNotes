import Darwin
import Foundation
import NotchNotesCore
import os

@MainActor
final class NotchNotesIPCServer {
    let socketPath: String
    private let isCustomSocketOverride: Bool
    private let store: NoteStore
    private let fileShelfStore: FileShelfStore
    private let onPanelAction: @MainActor (PanelCommand) -> Bool
    private var runtime: SocketListenerRuntime?

    var isRunning: Bool {
        runtime != nil
    }

    init(
        store: NoteStore,
        fileShelfStore: FileShelfStore,
        socketPath: String? = nil,
        onPanelAction: @escaping @MainActor (PanelCommand) -> Bool = { _ in false }
    ) {
        let resolved = IPCSocketSecurity.resolveSocketPath(customSocketPath: socketPath)
        self.socketPath = resolved.path
        self.isCustomSocketOverride = resolved.isCustomOverride
        self.store = store
        self.fileShelfStore = fileShelfStore
        self.onPanelAction = onPanelAction
    }

    private static let logger = Logger(subsystem: "io.github.oiloil.NotchNotes", category: "IPC")

    @discardableResult
    static func start(
        store: NoteStore,
        fileShelfStore: FileShelfStore,
        socketPath: String? = nil,
        onPanelAction: @escaping @MainActor (PanelCommand) -> Bool
    ) -> NotchNotesIPCServer? {
        let server = NotchNotesIPCServer(
            store: store,
            fileShelfStore: fileShelfStore,
            socketPath: socketPath,
            onPanelAction: onPanelAction
        )
        do {
            return try server.start()
        } catch {
            logger.error("Failed to start IPC server at \(server.socketPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @discardableResult
    func start() throws -> NotchNotesIPCServer {
        if runtime != nil {
            return self
        }

        try IPCSocketSecurity.prepareSecureParentDirectory(
            for: socketPath,
            enforceStrictPrivateDir: !isCustomSocketOverride
        )
        try IPCSocketSecurity.cleanupStaleSocketIfNeeded(at: socketPath)

        var addr = try IPCSocketSecurity.makeSockAddrUn(path: socketPath)
        let listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw IPCSocketError.systemCallFailed("socket", errno)
        }

        IPCSocketSecurity.configureDescriptor(listenFD, timeoutSeconds: 5)
        let statusFlags = Darwin.fcntl(listenFD, F_GETFL)
        if statusFlags >= 0 {
            _ = Darwin.fcntl(listenFD, F_SETFL, statusFlags | O_NONBLOCK)
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            _ = Darwin.close(listenFD)
            throw IPCSocketError.systemCallFailed("bind(\(socketPath))", err)
        }

        _ = Darwin.chmod(socketPath, S_IRUSR | S_IWUSR)

        guard Darwin.listen(listenFD, 16) == 0 else {
            let err = errno
            _ = Darwin.unlink(socketPath)
            _ = Darwin.close(listenFD)
            throw IPCSocketError.systemCallFailed("listen", err)
        }

        let handler: @MainActor @Sendable (IPCRequest) async -> IPCResponse = { [weak self] request in
            guard let self else {
                return .failure("NotchNotes IPC server has shut down.")
            }
            return await self.handleRequest(request)
        }

        let listener = SocketListenerRuntime(
            listenFD: listenFD,
            socketPath: socketPath,
            requestHandler: handler
        )
        listener.activate()
        runtime = listener
        return self
    }

    func stop() {
        runtime?.shutdown()
        runtime = nil
    }

    deinit {
        runtime?.shutdown()
    }

    private func handleRequest(_ request: IPCRequest) async -> IPCResponse {
        do {
            switch request.action {
            case .list:
                let summaries = store.tabs.enumerated().map { index, tab in
                    IPCPayloadBuilder.summary(for: tab, index: index, activeTabID: store.activeTabID)
                }
                return IPCResponse(ok: true, notes: summaries)

            case .get:
                let idx = try NoteTargetMatcher.resolveIndex(
                    in: store.tabs,
                    activeTabID: store.activeTabID,
                    target: request.target
                )
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(
                        for: store.tabs[idx],
                        index: idx,
                        activeTabID: store.activeTabID
                    )
                )

            case .add:
                let created = store.addTab(
                    text: request.text ?? "",
                    select: request.select ?? false
                )
                await store.flushAsync()
                let newIndex = store.tabs.firstIndex(where: { $0.id == created.id }) ?? (store.tabs.count - 1)
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(
                        for: store.tabs[newIndex],
                        index: newIndex,
                        activeTabID: store.activeTabID
                    )
                )

            case .append:
                let idx = try NoteTargetMatcher.resolveIndex(
                    in: store.tabs,
                    activeTabID: store.activeTabID,
                    target: request.target
                )
                let targetID = store.tabs[idx].id
                _ = store.appendText(
                    request.text ?? "",
                    to: targetID,
                    insertNewlineIfNeeded: !(request.noNewline ?? false)
                )
                await store.flushAsync()
                let updatedIdx = store.tabs.firstIndex(where: { $0.id == targetID }) ?? idx
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(
                        for: store.tabs[updatedIdx],
                        index: updatedIdx,
                        activeTabID: store.activeTabID
                    )
                )

            case .update:
                let idx = try NoteTargetMatcher.resolveIndex(
                    in: store.tabs,
                    activeTabID: store.activeTabID,
                    target: request.target
                )
                let targetID = store.tabs[idx].id
                _ = store.updateText(request.text ?? "", for: targetID)
                await store.flushAsync()
                let updatedIdx = store.tabs.firstIndex(where: { $0.id == targetID }) ?? idx
                return IPCResponse(
                    ok: true,
                    note: IPCPayloadBuilder.detail(
                        for: store.tabs[updatedIdx],
                        index: updatedIdx,
                        activeTabID: store.activeTabID
                    )
                )

            case .delete:
                let idx = try NoteTargetMatcher.resolveIndex(
                    in: store.tabs,
                    activeTabID: store.activeTabID,
                    target: request.target
                )
                guard store.tabs.count > 1 else {
                    throw NoteStorageError.cannotDeleteLastNote
                }
                let removedTab = store.tabs[idx]
                let removedTitle = store.title(for: removedTab.id)
                store.removeTab(removedTab.id)
                await store.flushAsync()
                return IPCResponse(
                    ok: true,
                    deleted: DeleteNotePayload(
                        deletedID: removedTab.id.uuidString,
                        title: removedTitle,
                        activeTabID: store.activeTabID.uuidString,
                        remainingCount: store.tabs.count
                    )
                )

            case .search:
                let matches = try IPCPayloadBuilder.searchMatches(
                    in: store.tabs,
                    query: request.query ?? ""
                )
                return IPCResponse(ok: true, matches: matches)

            case .shelf:
                return try handleShelfRequest(request)

            case .panel:
                let command = request.panelCommand ?? .toggle
                let isExpanded = onPanelAction(command)
                return IPCResponse(
                    ok: true,
                    panel: PanelStatePayload(action: command, isExpanded: isExpanded, launchedApp: false)
                )
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(message)
        }
    }

    private func handleShelfRequest(_ request: IPCRequest) throws -> IPCResponse {
        let operation = request.shelfOperation ?? .list
        switch operation {
        case .list:
            return IPCResponse(
                ok: true,
                shelfItems: fileShelfStore.items.map(IPCPayloadBuilder.shelfItemPayload(for:))
            )

        case .add:
            let urls = (request.paths ?? []).map { URL(fileURLWithPath: $0).standardizedFileURL }
            let added = fileShelfStore.add(urls)
            return IPCResponse(
                ok: true,
                shelfMutation: ShelfMutationPayload(
                    operation: .add,
                    affectedCount: added,
                    items: fileShelfStore.items.map(IPCPayloadBuilder.shelfItemPayload(for:))
                )
            )

        case .remove:
            let removeIDs = try NoteStorage.resolveShelfRemovalIDs(
                in: fileShelfStore.items,
                target: request.shelfTarget ?? ""
            )
            fileShelfStore.remove(ids: removeIDs)
            return IPCResponse(
                ok: true,
                shelfMutation: ShelfMutationPayload(
                    operation: .remove,
                    affectedCount: removeIDs.count,
                    items: fileShelfStore.items.map(IPCPayloadBuilder.shelfItemPayload(for:))
                )
            )

        case .clear:
            let count = fileShelfStore.items.count
            fileShelfStore.removeAll()
            return IPCResponse(
                ok: true,
                shelfMutation: ShelfMutationPayload(operation: .clear, affectedCount: count, items: [])
            )
        }
    }
}

private final class IPCResponseBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<IPCResponse>(
        initialState: .failure("Internal IPC error.")
    )

    func store(_ response: IPCResponse) {
        lock.withLock { $0 = response }
    }

    func load() -> IPCResponse {
        lock.withLock { $0 }
    }
}

private final class SocketListenerRuntime: Sendable {
    private struct ReadSourceBox: @unchecked Sendable {
        let rawValue: any DispatchSourceRead
    }

    private struct State: Sendable {
        var stopped = false
        var source: ReadSourceBox?
    }

    private let listenFD: Int32
    private let socketPath: String
    private let acceptQueue = DispatchQueue(label: "io.github.oiloil.NotchNotes.ipc.accept")
    private let clientQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "io.github.oiloil.NotchNotes.ipc.client"
        queue.maxConcurrentOperationCount = 16
        return queue
    }()
    private let requestHandler: @MainActor @Sendable (IPCRequest) async -> IPCResponse
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(
        listenFD: Int32,
        socketPath: String,
        requestHandler: @escaping @MainActor @Sendable (IPCRequest) async -> IPCResponse
    ) {
        self.listenFD = listenFD
        self.socketPath = socketPath
        self.requestHandler = requestHandler
    }

    func activate() {
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: acceptQueue)
        let fd = listenFD
        let handler = requestHandler
        let queue = clientQueue

        source.setEventHandler {
            while true {
                let clientFD = Darwin.accept(fd, nil, nil)
                if clientFD < 0 {
                    break
                }

                let fl = Darwin.fcntl(clientFD, F_GETFL)
                if fl >= 0 {
                    _ = Darwin.fcntl(clientFD, F_SETFL, fl & ~O_NONBLOCK)
                }
                IPCSocketSecurity.configureDescriptor(clientFD, timeoutSeconds: 5)

                queue.addOperation {
                    defer { _ = Darwin.close(clientFD) }
                    do {
                        try IPCSocketSecurity.verifyPeerUID(fd: clientFD)
                        let lineData = try IPCSocketSecurity.readLine(from: clientFD)
                        guard !lineData.isEmpty else { return }

                        let response: IPCResponse
                        do {
                            let request = try JSONDecoder().decode(IPCRequest.self, from: lineData)
                            let box = IPCResponseBox()
                            let replySemaphore = DispatchSemaphore(value: 0)
                            Task { @MainActor in
                                let handled = await handler(request)
                                box.store(handled)
                                replySemaphore.signal()
                            }
                            if replySemaphore.wait(timeout: .now() + .seconds(10)) == .timedOut {
                                response = .failure("IPC request timed out.")
                            } else {
                                response = box.load()
                            }
                        } catch {
                            response = .failure("Malformed IPC request: \(error.localizedDescription)")
                        }

                        let encoded = try JSONEncoder().encode(response)
                        try IPCSocketSecurity.writeLine(encoded, to: clientFD)
                    } catch {
                        // Unauthorized peer or broken client pipe; closed by defer.
                    }
                }
            }
        }

        source.setCancelHandler {
            _ = Darwin.close(fd)
        }

        let sourceBox = ReadSourceBox(rawValue: source)
        let shouldResume = state.withLock { state -> Bool in
            if state.stopped {
                return false
            }
            state.source = sourceBox
            return true
        }

        if shouldResume {
            sourceBox.rawValue.resume()
        } else {
            sourceBox.rawValue.cancel()
        }
    }

    func shutdown() {
        let sourceBox: ReadSourceBox? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.stopped = true
            let existing = state.source
            state.source = nil
            return existing
        }

        guard let sourceBox else { return }
        _ = Darwin.unlink(socketPath)
        sourceBox.rawValue.cancel()
    }
}
