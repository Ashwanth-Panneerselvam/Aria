import Foundation
import Network

/// Result of handing an uploaded file to the library importer.
nonisolated enum TransferImportOutcome: Sendable {
    case imported(title: String)
    case duplicate
    case failed(String)
}

/// Things the UI cares about, delivered off the server queue.
nonisolated enum TransferEvent: Sendable {
    case ready(port: UInt16)
    case failed(String)
    case stopped
    case uploadStarted(id: UUID, name: String, bytes: Int64)
    case uploadProgress(id: UUID, received: Int64)
    case uploadFinished(id: UUID, outcome: TransferImportOutcome)
    case uploadAborted(id: UUID)
    case tooManyBadPins
}

/// The network side of Wi-Fi Transfer: a local-network-only TCP listener
/// speaking just enough HTTP for the transfer page.
///
///   GET  /             the transfer page
///   GET  /api/ping     PIN check
///   GET  /api/library  library listing (JSON)
///   PUT  /upload       one audio file; streamed to disk, then imported
///
/// Every API call needs the 6-digit PIN shown on the phone (`X-Aria-Pin`).
/// Twenty wrong PINs stop the server. Uploads stream to a temporary inbox
/// and are deleted after import. All state lives on `queue`.
nonisolated final class TransferServerCore {

    struct Handlers: Sendable {
        let pin: String
        let page: Data
        let library: @Sendable () async -> Data
        let importFile: @Sendable (URL) async -> TransferImportOutcome
        let event: @Sendable (TransferEvent) -> Void
    }

    static let allowedExtensions: Set<String> = ["flac", "m4a", "mp3", "wav", "wave", "aif", "aiff", "aac", "alac"]
    static let maxUploadBytes: Int64 = 4 * 1024 * 1024 * 1024
    static let maxBadPins = 20

    let queue = DispatchQueue(label: "com.aria.music.wifi-transfer")
    let handlers: Handlers
    let inbox: URL
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: TransferConnection] = [:]
    private var badPins = 0
    private var stopped = false

    init(handlers: Handlers, inbox: URL) {
        self.handlers = handlers
        self.inbox = inbox
    }

    func start(preferredPort: UInt16 = 8080) {
        queue.async { self.startOnQueue(preferredPort: preferredPort) }
    }

    func stop() {
        queue.async { self.stopOnQueue(notify: true) }
    }

    // MARK: - Queue

    private func startOnQueue(preferredPort: UInt16) {
        try? FileManager.default.removeItem(at: inbox)
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)

        let params = NWParameters.tcp
        params.acceptLocalOnly = true
        params.allowLocalEndpointReuse = true
        let made: NWListener?
        if let port = NWEndpoint.Port(rawValue: preferredPort),
           let l = try? NWListener(using: params, on: port) {
            made = l
        } else {
            made = try? NWListener(using: params)
        }
        guard let listener = made else {
            handlers.event(.failed("Couldn't open a network port."))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.handlers.event(.ready(port: listener.port?.rawValue ?? preferredPort))
            case .failed(let error):
                self.handlers.event(.failed(error.localizedDescription))
                self.stopOnQueue(notify: false)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, !self.stopped else { connection.cancel(); return }
            let c = TransferConnection(connection: connection, core: self)
            self.connections[ObjectIdentifier(c)] = c
            c.start()
        }
        listener.start(queue: queue)
    }

    private func stopOnQueue(notify: Bool) {
        guard !stopped else { return }
        stopped = true
        listener?.cancel()
        listener = nil
        for c in connections.values { c.close() }
        connections.removeAll()
        try? FileManager.default.removeItem(at: inbox)
        if notify { handlers.event(.stopped) }
    }

    // MARK: - Called by connections (on queue)

    func finished(_ connection: TransferConnection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    /// Constant-time PIN compare; counts failures.
    func checkPIN(_ candidate: String?) -> Bool {
        let expected = Array(handlers.pin.utf8)
        let given = Array((candidate ?? "").utf8)
        var diff = expected.count ^ given.count
        for i in 0..<expected.count {
            diff |= Int(expected[i] ^ (i < given.count ? given[i] : 0))
        }
        if diff == 0 { return true }
        badPins += 1
        if badPins >= Self.maxBadPins {
            handlers.event(.tooManyBadPins)
            stopOnQueue(notify: true)
        }
        return false
    }

    func hasRoom(for bytes: Int64) -> Bool {
        let values = try? inbox.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        // The importer copies the file into the library: allow for two copies.
        return free > bytes * 2 + 200 * 1024 * 1024
    }
}

/// One HTTP exchange (the page sends `Connection: close` semantics).
nonisolated final class TransferConnection {
    private let connection: NWConnection
    private weak var core: TransferServerCore?
    private var headBuffer = Data()
    private var head: HTTPRequestHead?

    // Upload state.
    private var uploadID = UUID()
    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var expected: Int64 = 0
    private var received: Int64 = 0
    private var lastReported: Int64 = 0
    private var done = false

    init(connection: NWConnection, core: TransferServerCore) {
        self.connection = connection
        self.core = core
    }

    func start() {
        guard let core else { return }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cleanup(aborted: true)
            default:
                break
            }
        }
        connection.start(queue: core.queue)
        receive()
    }

    func close() {
        cleanup(aborted: true)
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let data, !data.isEmpty { self.consume(data) }
            if self.done { return }
            if error != nil || isComplete {
                self.cleanup(aborted: true)
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func consume(_ data: Data) {
        if head == nil {
            headBuffer.append(data)
            guard let range = headBuffer.range(of: HTTPRequestHead.terminator) else {
                if headBuffer.count > HTTPRequestHead.maxHeadBytes {
                    respond(431, "Request Header Fields Too Large", json: ["error": "Header too large"])
                }
                return
            }
            guard let parsed = HTTPRequestHead.parse(headBuffer.subdata(in: 0..<range.lowerBound)) else {
                respond(400, "Bad Request", json: ["error": "Malformed request"])
                return
            }
            head = parsed
            let body = headBuffer.subdata(in: range.upperBound..<headBuffer.count)
            headBuffer = Data()
            route(parsed, initialBody: body)
        } else if fileHandle != nil {
            appendBody(data)
        }
    }

    // MARK: - Routing

    private func route(_ req: HTTPRequestHead, initialBody: Data) {
        guard let core else { return }
        let pin = req.headers["x-aria-pin"] ?? req.query["pin"]
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            send(HTTPRequestHead.response(status: 200, reason: "OK",
                                          contentType: "text/html; charset=utf-8",
                                          body: core.handlers.page))
        case ("GET", "/api/ping"):
            guard core.checkPIN(pin) else { return unauthorized() }
            respond(200, "OK", json: ["ok": true])
        case ("GET", "/api/library"):
            guard core.checkPIN(pin) else { return unauthorized() }
            let library = core.handlers.library
            Task {
                let body = await library()
                self.send(HTTPRequestHead.response(status: 200, reason: "OK",
                                                   contentType: "application/json", body: body))
            }
        case ("PUT", "/upload"), ("POST", "/upload"):
            guard core.checkPIN(pin) else { return unauthorized() }
            beginUpload(req, core: core, initialBody: initialBody)
        default:
            respond(404, "Not Found", json: ["error": "Not found"])
        }
    }

    private func unauthorized() {
        respond(401, "Unauthorized", json: ["error": "Wrong PIN"])
    }

    // MARK: - Upload

    private func beginUpload(_ req: HTTPRequestHead, core: TransferServerCore, initialBody: Data) {
        guard let rawName = req.headers["x-file-name"],
              let name = HTTPRequestHead.sanitizedFileName(rawName) else {
            return respond(400, "Bad Request", json: ["error": "Missing file name"])
        }
        let ext = (name as NSString).pathExtension.lowercased()
        guard TransferServerCore.allowedExtensions.contains(ext) else {
            return respond(415, "Unsupported Media Type", json: ["error": "Not a supported audio file"])
        }
        guard let length = req.contentLength, length > 0 else {
            return respond(411, "Length Required", json: ["error": "Empty upload"])
        }
        guard length <= TransferServerCore.maxUploadBytes else {
            return respond(413, "Payload Too Large", json: ["error": "File too large"])
        }
        guard core.hasRoom(for: length) else {
            return respond(507, "Insufficient Storage", json: ["error": "Not enough free space on the iPhone"])
        }
        let folder = core.inbox.appendingPathComponent(uploadID.uuidString, isDirectory: true)
        let url = folder.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try FileHandle(forWritingTo: url)
        } catch {
            return respond(500, "Internal Server Error", json: ["error": "Couldn't create a temporary file"])
        }
        fileURL = url
        expected = length
        core.handlers.event(.uploadStarted(id: uploadID, name: name, bytes: length))
        if !initialBody.isEmpty { appendBody(initialBody) }
    }

    private func appendBody(_ data: Data) {
        guard let handle = fileHandle, let core else { return }
        let remaining = expected - received
        let chunk = Int64(data.count) > remaining ? data.prefix(Int(remaining)) : data
        do {
            try handle.write(contentsOf: chunk)
        } catch {
            respond(500, "Internal Server Error", json: ["error": "Write failed"])
            return
        }
        received += Int64(chunk.count)
        if received - lastReported >= 1_048_576 || received == expected {
            lastReported = received
            core.handlers.event(.uploadProgress(id: uploadID, received: received))
        }
        if received >= expected { finishUpload(core: core) }
    }

    private func finishUpload(core: TransferServerCore) {
        try? fileHandle?.close()
        fileHandle = nil
        guard let url = fileURL else { return }
        let id = uploadID
        let importer = core.handlers.importFile
        let events = core.handlers.event
        Task {
            let outcome = await importer(url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            events(.uploadFinished(id: id, outcome: outcome))
            let json: [String: Any]
            switch outcome {
            case .imported(let title): json = ["ok": true, "status": "imported", "title": title]
            case .duplicate: json = ["ok": true, "status": "duplicate"]
            case .failed(let message): json = ["ok": false, "status": "failed", "error": message]
            }
            self.respond(200, "OK", json: json)
        }
    }

    // MARK: - Responses

    private func respond(_ status: Int, _ reason: String, json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        send(HTTPRequestHead.response(status: status, reason: reason,
                                      contentType: "application/json", body: body))
    }

    private func send(_ data: Data) {
        guard let core else { return }
        core.queue.async {
            guard !self.done else { return }
            self.done = true
            self.connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.connection.cancel()
            })
        }
    }

    private func cleanup(aborted: Bool) {
        if let handle = fileHandle {
            try? handle.close()
            fileHandle = nil
            if aborted, let url = fileURL {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                core?.handlers.event(.uploadAborted(id: uploadID))
            }
        }
        if aborted || done { core?.finished(self) }
    }
}
