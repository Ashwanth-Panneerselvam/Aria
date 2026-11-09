import AVFoundation
import Foundation

/// Text tags read straight from an audio file.
///
/// Why this exists: Aria's importer asked AVFoundation for `commonMetadata`,
/// which on iOS doesn't surface FLAC's Vorbis comments — so FLAC imports got
/// the file name as the title, "This Device" as the artist and no album.
/// `read(fileURL:)` parses FLAC's VORBIS_COMMENT block directly (skipping
/// pictures by seeking, so large embedded covers aren't read), and falls back
/// to AVFoundation's full (non-common) metadata for other formats.
nonisolated struct AudioTags: Equatable {
    var title: String?
    var artist: String?
    var albumArtist: String?
    var album: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?

    var isEmpty: Bool {
        title == nil && artist == nil && albumArtist == nil && album == nil
            && trackNumber == nil && discNumber == nil && year == nil
    }

    /// Best available artist for display: track artist, else album artist.
    var displayArtist: String? { artist ?? albumArtist }

    // MARK: - Entry point

    static func read(fileURL url: URL) -> AudioTags? {
        if let flac = readFLAC(url), !flac.isEmpty { return flac }
        return nil
    }

    /// FLAC first, then AVFoundation's per-format metadata (ID3, iTunes).
    static func readAny(fileURL url: URL) async -> AudioTags? {
        if let flac = read(fileURL: url) { return flac }
        return await readWithAVFoundation(url)
    }

    // MARK: - FLAC

    static let maxCommentBlock = 1 << 20

    static func readFLAC(_ url: URL) -> AudioTags? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        func read(_ count: Int) -> Data? {
            guard count >= 0, let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return d
        }

        guard var magic = read(4) else { return nil }
        // Some taggers put an ID3v2 block in front of "fLaC".
        if magic.prefix(3) == Data("ID3".utf8) {
            guard let rest = read(6) else { return nil }
            let header = magic + rest
            let b = [UInt8](header)
            let size = (Int(b[6] & 0x7F) << 21) | (Int(b[7] & 0x7F) << 14) | (Int(b[8] & 0x7F) << 7) | Int(b[9] & 0x7F)
            let footer = (b[5] & 0x10) != 0 ? 10 : 0
            guard (try? handle.seek(toOffset: UInt64(10 + size + footer))) != nil, let m = read(4) else { return nil }
            magic = m
        }
        guard magic == Data("fLaC".utf8) else { return nil }

        for _ in 0..<128 {
            guard let header = read(4) else { return nil }
            let h = [UInt8](header)
            let isLast = (h[0] & 0x80) != 0
            let type = h[0] & 0x7F
            let length = (Int(h[1]) << 16) | (Int(h[2]) << 8) | Int(h[3])
            if type == 4 {
                guard length <= maxCommentBlock, let block = read(length) else { return nil }
                return parseVorbisComment(block)
            }
            // Skip the block (pictures can be megabytes).
            guard let pos = try? handle.offset(),
                  (try? handle.seek(toOffset: pos + UInt64(length))) != nil else { return nil }
            if isLast { break }
        }
        return nil
    }

    /// VORBIS_COMMENT block: little-endian lengths, UTF-8 "KEY=value" pairs.
    static func parseVorbisComment(_ data: Data) -> AudioTags? {
        let bytes = [UInt8](data)
        var i = 0
        func u32() -> Int? {
            guard i + 4 <= bytes.count else { return nil }
            let v = Int(bytes[i]) | (Int(bytes[i + 1]) << 8) | (Int(bytes[i + 2]) << 16) | (Int(bytes[i + 3]) << 24)
            i += 4
            return v
        }
        guard let vendorLength = u32(), i + vendorLength <= bytes.count else { return nil }
        i += vendorLength
        guard let count = u32() else { return nil }

        var fields: [String: [String]] = [:]
        for _ in 0..<min(count, 10_000) {
            guard let len = u32(), len >= 0, i + len <= bytes.count else { break }
            let entry = String(decoding: bytes[i..<(i + len)], as: UTF8.self)
            i += len
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let key = entry[..<eq].uppercased()
            let value = entry[entry.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            fields[key, default: []].append(value)
        }
        return tags(from: fields)
    }

    static func tags(from fields: [String: [String]]) -> AudioTags {
        func first(_ keys: String...) -> String? {
            for k in keys { if let v = fields[k]?.first { return v } }
            return nil
        }
        // Multiple ARTIST entries are separate credits.
        let artists = (fields["ARTIST"] ?? []).reduce(into: [String]()) { acc, a in
            if !acc.contains(a) { acc.append(a) }
        }
        return AudioTags(
            title: first("TITLE"),
            artist: artists.isEmpty ? nil : artists.joined(separator: ", "),
            albumArtist: first("ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST"),
            album: first("ALBUM"),
            trackNumber: leadingInt(first("TRACKNUMBER", "TRACK")),
            discNumber: leadingInt(first("DISCNUMBER", "DISC")),
            year: leadingInt(first("DATE", "YEAR", "ORIGINALDATE")).flatMap { $0 > 999 ? $0 : nil }
        )
    }

    /// "3/12" → 3, "2019-05-01" → 2019, "07" → 7.
    static func leadingInt(_ s: String?) -> Int? {
        guard let s else { return nil }
        let digits = s.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }
        return Int(digits)
    }

    // MARK: - Other formats

    static func readWithAVFoundation(_ url: URL) async -> AudioTags? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata), !items.isEmpty else { return nil }
        var tags = AudioTags()
        for item in items {
            guard let id = item.identifier?.rawValue else { continue }
            let value = try? await item.load(.stringValue)
            switch id {
            case _ where id.hasSuffix("/TIT2") || id.hasSuffix("/%A9nam") || id == "common/title":
                tags.title = tags.title ?? nonEmpty(value)
            case _ where id.hasSuffix("/TPE1") || id.hasSuffix("/%A9ART") || id == "common/artist":
                tags.artist = tags.artist ?? nonEmpty(value)
            case _ where id.hasSuffix("/TPE2") || id.hasSuffix("/aART"):
                tags.albumArtist = tags.albumArtist ?? nonEmpty(value)
            case _ where id.hasSuffix("/TALB") || id.hasSuffix("/%A9alb") || id == "common/albumName":
                tags.album = tags.album ?? nonEmpty(value)
            case _ where id.hasSuffix("/TRCK"):
                tags.trackNumber = tags.trackNumber ?? leadingInt(value)
            case _ where id.hasSuffix("/TPOS"):
                tags.discNumber = tags.discNumber ?? leadingInt(value)
            default:
                break
            }
        }
        return tags.isEmpty ? nil : tags
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
