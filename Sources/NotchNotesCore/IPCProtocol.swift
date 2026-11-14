import Darwin
import Foundation

public enum PanelCommand: String, Codable, Equatable, Sendable {
    case open
    case close
    case toggle
}

public enum ShelfOperation: String, Codable, Equatable, Sendable {
    case list
    case add
    case remove
    case clear
}

public enum IPCAction: String, Codable, Equatable, Sendable {
    case list
    case get
    case add
    case append
    case update
    case delete
    case search
    case shelf
    case panel
}

public struct IPCRequest: Codable, Equatable, Sendable {
    public var action: IPCAction
    public var target: String?
    public var text: String?
    public var select: Bool?
    public var noNewline: Bool?
    public var query: String?
    public var shelfOperation: ShelfOperation?
    public var paths: [String]?
    public var shelfTarget: String?
    public var panelCommand: PanelCommand?

    public init(
        action: IPCAction,
        target: String? = nil,
        text: String? = nil,
        select: Bool? = nil,
        noNewline: Bool? = nil,
        query: String? = nil,
        shelfOperation: ShelfOperation? = nil,
        paths: [String]? = nil,
        shelfTarget: String? = nil,
        panelCommand: PanelCommand? = nil
    ) {
        self.action = action
        self.target = target
        self.text = text
        self.select = select
        self.noNewline = noNewline
        self.query = query
        self.shelfOperation = shelfOperation
        self.paths = paths
        self.shelfTarget = shelfTarget
        self.panelCommand = panelCommand
    }
}

public struct NoteSummaryPayload: Codable, Equatable, Sendable {
    public var index: Int
    public var id: String
    public var title: String
    public var characterCount: Int
    public var isActive: Bool
    public var createdAt: String

    public init(
        index: Int,
        id: String,
        title: String,
        characterCount: Int,
        isActive: Bool,
        createdAt: String
    ) {
        self.index = index
        self.id = id
        self.title = title
        self.characterCount = characterCount
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

public struct NoteDetailPayload: Codable, Equatable, Sendable {
    public var index: Int
    public var id: String
    public var title: String
    public var text: String
    public var characterCount: Int
    public var isActive: Bool
    public var createdAt: String

    public init(
        index: Int,
        id: String,
        title: String,
        text: String,
        characterCount: Int,
        isActive: Bool,
        createdAt: String
    ) {
        self.index = index
        self.id = id
        self.title = title
        self.text = text
        self.characterCount = characterCount
        self.isActive = isActive
        self.createdAt = createdAt
    }
}

public struct DeleteNotePayload: Codable, Equatable, Sendable {
    public var deletedID: String
    public var title: String
    public var activeTabID: String
    public var remainingCount: Int

    public init(deletedID: String, title: String, activeTabID: String, remainingCount: Int) {
        self.deletedID = deletedID
        self.title = title
        self.activeTabID = activeTabID
        self.remainingCount = remainingCount
    }
}

public struct SearchMatchPayload: Codable, Equatable, Sendable {
    public var index: Int
    public var id: String
    public var title: String
    public var line: Int
    public var snippet: String

    public init(index: Int, id: String, title: String, line: Int, snippet: String) {
        self.index = index
        self.id = id
        self.title = title
        self.line = line
        self.snippet = snippet
    }
}

public struct ShelfItemPayload: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var path: String
    public var addedAt: String
    public var isDirectory: Bool
    public var fileExtension: String?
    public var exists: Bool

    public init(
        id: String,
        name: String,
        path: String,
        addedAt: String,
        isDirectory: Bool,
        fileExtension: String?,
        exists: Bool
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
        self.isDirectory = isDirectory
        self.fileExtension = fileExtension
        self.exists = exists
    }
}

public struct ShelfMutationPayload: Codable, Equatable, Sendable {
    public var operation: ShelfOperation
    public var affectedCount: Int
    public var items: [ShelfItemPayload]

    public init(operation: ShelfOperation, affectedCount: Int, items: [ShelfItemPayload]) {
        self.operation = operation
        self.affectedCount = affectedCount
        self.items = items
    }
}

public struct PanelStatePayload: Codable, Equatable, Sendable {
    public var action: PanelCommand
    public var isExpanded: Bool
    public var launchedApp: Bool

    public init(action: PanelCommand, isExpanded: Bool, launchedApp: Bool = false) {
        self.action = action
        self.isExpanded = isExpanded
        self.launchedApp = launchedApp
    }
}

public struct IPCResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    public var notes: [NoteSummaryPayload]?
    public var note: NoteDetailPayload?
    public var deleted: DeleteNotePayload?
    public var matches: [SearchMatchPayload]?
    public var shelfItems: [ShelfItemPayload]?
    public var shelfMutation: ShelfMutationPayload?
    public var panel: PanelStatePayload?

    public init(
        ok: Bool,
        error: String? = nil,
        notes: [NoteSummaryPayload]? = nil,
        note: NoteDetailPayload? = nil,
        deleted: DeleteNotePayload? = nil,
        matches: [SearchMatchPayload]? = nil,
        shelfItems: [ShelfItemPayload]? = nil,
        shelfMutation: ShelfMutationPayload? = nil,
        panel: PanelStatePayload? = nil
    ) {
        self.ok = ok
        self.error = error
        self.notes = notes
        self.note = note
        self.deleted = deleted
        self.matches = matches
        self.shelfItems = shelfItems
        self.shelfMutation = shelfMutation
        self.panel = panel
    }

    public static func failure(_ message: String) -> IPCResponse {
        IPCResponse(ok: false, error: message)
    }
}

public enum IPCPayloadBuilder {
    public static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func summary(for tab: NoteTab, index: Int, activeTabID: UUID) -> NoteSummaryPayload {
        NoteSummaryPayload(
            index: index + 1,
            id: tab.id.uuidString,
            title: NoteTitleExtractor.title(for: tab.text, index: index),
            characterCount: tab.text.count,
            isActive: tab.id == activeTabID,
            createdAt: formatISO8601(tab.createdAt)
        )
    }

    public static func detail(for tab: NoteTab, index: Int, activeTabID: UUID) -> NoteDetailPayload {
        NoteDetailPayload(
            index: index + 1,
            id: tab.id.uuidString,
            title: NoteTitleExtractor.title(for: tab.text, index: index),
            text: tab.text,
            characterCount: tab.text.count,
            isActive: tab.id == activeTabID,
            createdAt: formatISO8601(tab.createdAt)
        )
    }

    public static func shelfItemPayload(for item: FileShelfItem) -> ShelfItemPayload {
        var isDirObjC: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: item.fallbackPath, isDirectory: &isDirObjC)
        return ShelfItemPayload(
            id: item.id.uuidString,
            name: item.originalName,
            path: item.fallbackPath,
            addedAt: formatISO8601(item.addedAt),
            isDirectory: exists ? isDirObjC.boolValue : (item.isDirectory ?? false),
            fileExtension: item.fileExtension,
            exists: exists
        )
    }

    public static func searchMatches(in tabs: [NoteTab], query: String) throws -> [SearchMatchPayload] {
        guard !query.isEmpty else {
            throw NoteStorageError.emptySearchQuery
        }

        var matches: [SearchMatchPayload] = []
        for (tabIndex, tab) in tabs.enumerated() {
            let title = NoteTitleExtractor.title(for: tab.text, index: tabIndex)
            var lineNumber = 1
            var lineStart = tab.text.startIndex
            while lineStart <= tab.text.endIndex {
                let lineEnd = tab.text[lineStart...].firstIndex(where: \.isNewline) ?? tab.text.endIndex
                let line = String(tab.text[lineStart..<lineEnd])
                if line.range(of: query, options: .caseInsensitive) != nil {
                    matches.append(
                        SearchMatchPayload(
                            index: tabIndex + 1,
                            id: tab.id.uuidString,
                            title: title,
                            line: lineNumber,
                            snippet: line.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }

                guard lineEnd < tab.text.endIndex else { break }
                lineStart = tab.text.index(after: lineEnd)
                lineNumber += 1
            }
        }
        return matches
    }
}

public enum IPCSocketError: LocalizedError, Equatable, Sendable {
    case socketPathTooLong(String)
    case insecureSocketDirectory(String)
    case socketAlreadyInUse(String)
    case nonSocketFileAtPath(String)
    case unauthorizedPeer(uid_t)
    case serverUnavailable(String)
    case systemCallFailed(String, Int32)
    case invalidProtocolPayload(String)

    public var errorDescription: String? {
        switch self {
        case let .socketPathTooLong(path):
            return "Socket path exceeds Unix domain socket limit: \(path)"
        case let .insecureSocketDirectory(reason):
            return "Insecure IPC socket directory: \(reason)"
        case let .socketAlreadyInUse(path):
            return "IPC socket is already in use by another running NotchNotes instance: \(path)"
        case let .nonSocketFileAtPath(path):
            return "Refusing to overwrite non-socket file at IPC path: \(path)"
        case let .unauthorizedPeer(uid):
            return "Rejected IPC connection from unauthorized peer UID \(uid)."
        case let .serverUnavailable(reason):
            return "NotchNotes IPC server is unavailable: \(reason)"
        case let .systemCallFailed(call, code):
            return "\(call) failed (\(code)): \(String(cString: strerror(code)))"
        case let .invalidProtocolPayload(reason):
            return "Invalid IPC payload: \(reason)"
        }
    }
}

public enum IPCSocketSecurity {
    public static let socketPathEnvKey = "NOTCHNOTES_SOCKET_PATH"
    public static let maxRequestBytes = 8 * 1024 * 1024

    public static func defaultSocketDirectoryPath(uid: uid_t = Darwin.getuid()) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = Darwin.confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        if length > 0 {
            let utf8Bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            let tempDir = String(decoding: utf8Bytes, as: UTF8.self)
            let candidate = URL(fileURLWithPath: tempDir, isDirectory: true)
                .appendingPathComponent("notchnotes-\(uid)", isDirectory: true)
                .path
            let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            if (candidate + "/ipc.sock").utf8CString.count <= maxPathBytes {
                return candidate
            }
        }
        return "/tmp/notchnotes-\(uid)"
    }

    public static func defaultSocketPath(uid: uid_t = Darwin.getuid()) -> String {
        "\(defaultSocketDirectoryPath(uid: uid))/ipc.sock"
    }

    public static func resolveSocketPath(
        customSocketPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (path: String, isCustomOverride: Bool) {
        if let customSocketPath = customSocketPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !customSocketPath.isEmpty {
            return ((customSocketPath as NSString).expandingTildeInPath, true)
        }

        if let envSocket = environment[socketPathEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envSocket.isEmpty {
            return ((envSocket as NSString).expandingTildeInPath, true)
        }

        return (defaultSocketPath(), false)
    }

    public static func makeSockAddrUn(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathBytes = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = Array(path.utf8CString)
        guard utf8.count <= maxPathBytes else {
            throw IPCSocketError.socketPathTooLong(path)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
            utf8.withUnsafeBytes { src in
                rawBuffer.copyBytes(from: src)
            }
        }
        return addr
    }

    public static func prepareSecureParentDirectory(
        for socketPath: String,
        enforceStrictPrivateDir: Bool,
        expectedUID: uid_t = Darwin.getuid()
    ) throws {
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        guard !dirPath.isEmpty else { return }

        if enforceStrictPrivateDir {
            if Darwin.mkdir(dirPath, S_IRWXU) != 0 && errno != EEXIST {
                throw IPCSocketError.systemCallFailed("mkdir(\(dirPath))", errno)
            }

            var st = Darwin.stat()
            guard Darwin.lstat(dirPath, &st) == 0 else {
                throw IPCSocketError.systemCallFailed("lstat(\(dirPath))", errno)
            }

            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                throw IPCSocketError.insecureSocketDirectory("'\(dirPath)' is not a real directory.")
            }

            guard st.st_uid == expectedUID else {
                throw IPCSocketError.insecureSocketDirectory(
                    "'\(dirPath)' is owned by UID \(st.st_uid), expected \(expectedUID)."
                )
            }

            if (st.st_mode & 0o777) != 0o700 {
                guard Darwin.chmod(dirPath, S_IRWXU) == 0 else {
                    throw IPCSocketError.systemCallFailed("chmod(\(dirPath))", errno)
                }
            }
        } else {
            var st = Darwin.stat()
            if Darwin.lstat(dirPath, &st) != 0 {
                try FileManager.default.createDirectory(
                    atPath: dirPath,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
        }
    }

    public static func validateClientSocketDirectoryIfDefault(
        socketPath: String,
        isCustomOverride: Bool,
        expectedUID: uid_t = Darwin.getuid()
    ) throws {
        guard !isCustomOverride else { return }
        let dirPath = (socketPath as NSString).deletingLastPathComponent
        var st = Darwin.stat()
        guard Darwin.lstat(dirPath, &st) == 0 else {
            if errno == ENOENT {
                throw IPCSocketError.serverUnavailable("Socket directory does not exist.")
            }
            throw IPCSocketError.systemCallFailed("lstat(\(dirPath))", errno)
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else {
            throw IPCSocketError.insecureSocketDirectory("'\(dirPath)' is not a directory.")
        }
        guard st.st_uid == expectedUID else {
            throw IPCSocketError.insecureSocketDirectory("'\(dirPath)' has unexpected owner UID \(st.st_uid).")
        }
        guard (st.st_mode & 0o077) == 0 else {
            throw IPCSocketError.insecureSocketDirectory("'\(dirPath)' has overly permissive mode \(String(st.st_mode & 0o777, radix: 8)).")
        }
    }

    public static func verifyPeerUID(fd: Int32, expectedUID: uid_t = Darwin.getuid()) throws {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard Darwin.getpeereid(fd, &peerUID, &peerGID) == 0 else {
            throw IPCSocketError.systemCallFailed("getpeereid", errno)
        }
        guard peerUID == expectedUID else {
            throw IPCSocketError.unauthorizedPeer(peerUID)
        }
    }

    public static func cleanupStaleSocketIfNeeded(at socketPath: String, expectedUID: uid_t = Darwin.getuid()) throws {
        var st = Darwin.stat()
        if Darwin.lstat(socketPath, &st) != 0 {
            if errno == ENOENT {
                return
            }
            throw IPCSocketError.systemCallFailed("lstat(\(socketPath))", errno)
        }

        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw IPCSocketError.nonSocketFileAtPath(socketPath)
        }

        guard st.st_uid == expectedUID else {
            throw IPCSocketError.insecureSocketDirectory(
                "Existing socket '\(socketPath)' belongs to UID \(st.st_uid), expected \(expectedUID)."
            )
        }

        var addr = try makeSockAddrUn(path: socketPath)
        let probeFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard probeFD >= 0 else {
            throw IPCSocketError.systemCallFailed("socket", errno)
        }
        defer { _ = Darwin.close(probeFD) }
        configureDescriptor(probeFD, timeoutSeconds: 1)

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(probeFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            throw IPCSocketError.socketAlreadyInUse(socketPath)
        }

        let err = errno
        if err == ECONNREFUSED || err == ENOENT {
            if Darwin.unlink(socketPath) != 0 && errno != ENOENT {
                throw IPCSocketError.systemCallFailed("unlink(\(socketPath))", errno)
            }
            return
        }

        throw IPCSocketError.systemCallFailed("connect(\(socketPath))", err)
    }

    public static func configureDescriptor(_ fd: Int32, timeoutSeconds: Int = 5) {
        let flags = Darwin.fcntl(fd, F_GETFD)
        if flags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFD, flags | FD_CLOEXEC)
        }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var timeout = Darwin.timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<Darwin.timeval>.size)
        )
        _ = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout<Darwin.timeval>.size)
        )
    }

    public static func readLine(from fd: Int32, maxBytes: Int = maxRequestBytes) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while buffer.count < maxBytes {
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead > 0 {
                if let newlineIndex = chunk[0..<bytesRead].firstIndex(of: UInt8(ascii: "\n")) {
                    buffer.append(contentsOf: chunk[0..<newlineIndex])
                    return buffer
                }
                buffer.append(contentsOf: chunk[0..<bytesRead])
            } else if bytesRead == 0 {
                return buffer
            } else {
                if errno == EINTR {
                    continue
                }
                throw IPCSocketError.systemCallFailed("read", errno)
            }
        }

        throw IPCSocketError.invalidProtocolPayload("IPC message exceeded maximum frame size.")
    }

    public static func writeLine(_ data: Data, to fd: Int32) throws {
        var frame = data
        frame.append(UInt8(ascii: "\n"))

        try frame.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(fd, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw IPCSocketError.systemCallFailed("write", errno)
                }
            }
        }
    }
}

public enum IPCClient {
    public enum SendOutcome: Sendable {
        case connected(IPCResponse)
        case offline
    }

    public static func sendIfRunning(
        _ request: IPCRequest,
        customSocketPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SendOutcome {
        let resolved = IPCSocketSecurity.resolveSocketPath(
            customSocketPath: customSocketPath,
            environment: environment
        )

        do {
            try IPCSocketSecurity.validateClientSocketDirectoryIfDefault(
                socketPath: resolved.path,
                isCustomOverride: resolved.isCustomOverride
            )
        } catch IPCSocketError.serverUnavailable, IPCSocketError.insecureSocketDirectory {
            return .offline
        }

        var st = Darwin.stat()
        if Darwin.lstat(resolved.path, &st) != 0 {
            if errno == ENOENT {
                return .offline
            }
            throw IPCSocketError.systemCallFailed("lstat(\(resolved.path))", errno)
        }

        guard (st.st_mode & S_IFMT) == S_IFSOCK else {
            throw IPCSocketError.nonSocketFileAtPath(resolved.path)
        }

        var addr = try IPCSocketSecurity.makeSockAddrUn(path: resolved.path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCSocketError.systemCallFailed("socket", errno)
        }
        defer { _ = Darwin.close(fd) }
        IPCSocketSecurity.configureDescriptor(fd, timeoutSeconds: 5)

        let connectRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectRC != 0 {
            let err = errno
            if err == ECONNREFUSED || err == ENOENT {
                return .offline
            }
            throw IPCSocketError.systemCallFailed("connect(\(resolved.path))", err)
        }

        try IPCSocketSecurity.verifyPeerUID(fd: fd)

        let requestData = try JSONEncoder().encode(request)
        try IPCSocketSecurity.writeLine(requestData, to: fd)
        _ = Darwin.shutdown(fd, SHUT_WR)

        let responseLine = try IPCSocketSecurity.readLine(from: fd)
        guard !responseLine.isEmpty else {
            throw IPCSocketError.invalidProtocolPayload("Empty response from NotchNotes IPC server.")
        }

        let response: IPCResponse
        do {
            response = try JSONDecoder().decode(IPCResponse.self, from: responseLine)
        } catch {
            throw IPCSocketError.invalidProtocolPayload(error.localizedDescription)
        }

        return .connected(response)
    }
}
