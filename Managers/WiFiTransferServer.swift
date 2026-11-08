import Foundation
import Combine
import Darwin

/// Main-actor face of Wi-Fi Transfer: owns the PIN, the server core, the
/// upload list the screen shows, and the hand-off to the library importer.
@MainActor
final class WiFiTransferServer: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case running(address: String, pin: String)
        case failed(String)
    }

    struct Upload: Identifiable, Equatable {
        enum Status: Equatable {
            case receiving
            case importing
            case imported(String)
            case duplicate
            case failed(String)
        }
        let id: UUID
        let name: String
        let totalBytes: Int64
        var receivedBytes: Int64 = 0
        var status: Status = .receiving

        var fraction: Double { totalBytes > 0 ? Double(receivedBytes) / Double(totalBytes) : 0 }
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var uploads: [Upload] = []
    @Published private(set) var importedCount = 0
    @Published private(set) var skippedCount = 0

    var isActive: Bool {
        switch state {
        case .starting, .running: return true
        default: return false
        }
    }

    private weak var library: LocalLibraryManager?
    private var core: TransferServerCore?

    func configure(library: LocalLibraryManager) {
        self.library = library
    }

    // MARK: - Lifecycle

    func start() {
        guard !isActive else { return }
        guard let ip = Self.wifiIPv4Address() else {
            state = .failed("Connect this iPhone to Wi-Fi — the same network as your computer.")
            return
        }
        let pin = String(format: "%06d", Int.random(in: 0...999_999))
        state = .starting
        uploads = []
        importedCount = 0
        skippedCount = 0

        let inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiFiInbox", isDirectory: true)
        let handlers = TransferServerCore.Handlers(
            pin: pin,
            page: TransferPage.data,
            library: { [weak self] in
                await self?.libraryJSON() ?? Data("{\"count\":0,\"tracks\":[]}".utf8)
            },
            importFile: { [weak self] url in
                await self?.importUploaded(url) ?? .failed("Transfer stopped")
            },
            event: { [weak self] event in
                Task { @MainActor in self?.handle(event, ip: ip, pin: pin) }
            }
        )
        let core = TransferServerCore(handlers: handlers, inbox: inbox)
        self.core = core
        core.start()
    }

    func stop() {
        core?.stop()
        core = nil
        if case .failed = state { return }
        state = .stopped
    }

    // MARK: - Events

    private func handle(_ event: TransferEvent, ip: String, pin: String) {
        switch event {
        case .ready(let port):
            state = .running(address: port == 80 ? "http://\(ip)" : "http://\(ip):\(port)", pin: pin)
        case .failed(let message):
            state = .failed(message)
            core = nil
        case .stopped:
            if case .running = state { state = .stopped }
        case .tooManyBadPins:
            state = .failed("Stopped after too many wrong PINs. Start again for a new PIN.")
            core = nil
        case .uploadStarted(let id, let name, let bytes):
            uploads.insert(Upload(id: id, name: name, totalBytes: bytes), at: 0)
            if uploads.count > 200 { uploads.removeLast(uploads.count - 200) }
        case .uploadProgress(let id, let received):
            update(id) {
                $0.receivedBytes = received
                if received >= $0.totalBytes { $0.status = .importing }
            }
        case .uploadFinished(let id, let outcome):
            update(id) { upload in
                switch outcome {
                case .imported(let title):
                    upload.status = .imported(title)
                    importedCount += 1
                case .duplicate:
                    upload.status = .duplicate
                    skippedCount += 1
                case .failed(let message):
                    upload.status = .failed(message)
                }
            }
        case .uploadAborted(let id):
            update(id) { $0.status = .failed("Connection lost") }
        }
    }

    private func update(_ id: UUID, _ change: (inout Upload) -> Void) {
        guard let i = uploads.firstIndex(where: { $0.id == id }) else { return }
        change(&uploads[i])
    }

    // MARK: - Library hand-off

    /// Imports through the same pipeline as Files/Folder import. A file with
    /// the same extension and exact byte size as a library track is treated
    /// as already imported, so re-sending a folder doesn't duplicate it.
    private func importUploaded(_ url: URL) async -> TransferImportOutcome {
        guard let library else { return .failed("Library unavailable") }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let ext = url.pathExtension.lowercased()
        if size > 0, library.tracks.contains(where: {
            $0.fileSizeBytes == size && ($0.fileName as NSString).pathExtension.lowercased() == ext
        }) {
            return .duplicate
        }
        do {
            let track = try await library.importFile(at: url)
            return .imported(title: track.title)
        } catch let error as ImportError {
            switch error {
            case .unsupportedFormat(let format):
                return .failed("\(format.displayName) isn't supported")
            case .fileNotDownloaded:
                return .failed("File not available")
            case .zeroByteFile:
                return .failed("Empty file")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func libraryJSON() -> Data {
        let tracks = library?.tracks ?? []
        let list: [[String: Any]] = tracks.prefix(5_000).map { t in
            [
                "title": t.title,
                "artist": t.artist ?? "",
                "album": t.album ?? "",
                "format": (t.fileName as NSString).pathExtension.uppercased(),
                "bytes": t.fileSizeBytes,
            ]
        }
        let payload: [String: Any] = ["count": tracks.count, "tracks": list]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"count\":0}".utf8)
    }

    // MARK: - Network address

    /// The Wi-Fi interface's IPv4 address (en0), if connected.
    static func wifiIPv4Address() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let iface = current.pointee
            if let addr = iface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: iface.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: host)
                }
            }
            ptr = iface.ifa_next
        }
        return address
    }
}
