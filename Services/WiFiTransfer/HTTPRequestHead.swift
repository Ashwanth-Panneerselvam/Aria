import Foundation

/// Minimal HTTP/1.1 request head parser for the Wi-Fi transfer server.
/// Only what the transfer page sends: a request line plus headers.
nonisolated struct HTTPRequestHead: Equatable {
    let method: String
    let path: String
    let query: [String: String]
    /// Header names lowercased.
    let headers: [String: String]

    static let terminator = Data("\r\n\r\n".utf8)
    static let maxHeadBytes = 16 * 1024

    var contentLength: Int64? {
        headers["content-length"].flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// `head` is the bytes before the blank line (terminator excluded).
    static func parse(_ head: Data) -> HTTPRequestHead? {
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else {
            return nil
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let queryString = target[target.index(after: q)...]
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequestHead(method: method, path: path, query: query, headers: headers)
    }

    /// Reduces an uploaded file name to a safe single path component.
    static func sanitizedFileName(_ raw: String) -> String? {
        let decoded = raw.removingPercentEncoding ?? raw
        let last = decoded
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init) ?? ""
        let cleaned = last
            .components(separatedBy: CharacterSet(charactersIn: "\0:"))
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.hasPrefix(".") else { return nil }
        return String(cleaned.prefix(200))
    }

    /// HTTP response bytes.
    static func response(status: Int, reason: String, contentType: String, body: Data) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}
