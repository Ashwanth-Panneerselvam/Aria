import XCTest
@testable import Aria___Music_Browser

/// FLAC Vorbis-comment reading and the non-destructive library tag repair.
@MainActor
final class AudioTagsTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Building synthetic FLAC headers

    private func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func block(type: UInt8, last: Bool, _ body: [UInt8]) -> [UInt8] {
        let n = body.count
        return [(last ? 0x80 : 0) | type, UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)] + body
    }

    private func vorbis(_ comments: [String]) -> [UInt8] {
        let vendor = Array("reference libFLAC 1.4.3".utf8)
        var out = le32(vendor.count) + vendor + le32(comments.count)
        for c in comments {
            let b = Array(c.utf8)
            out += le32(b.count) + b
        }
        return out
    }

    /// STREAMINFO, a 300 KB PICTURE (must be skipped, not read), then tags.
    private func writeFLAC(_ comments: [String], id3Prefix: Bool = false) -> URL {
        var bytes: [UInt8] = []
        if id3Prefix {
            let tagBody = [UInt8](repeating: 0, count: 200)
            let size = tagBody.count
            bytes += Array("ID3".utf8) + [4, 0, 0,
                                          UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F),
                                          UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)] + tagBody
        }
        bytes += Array("fLaC".utf8)
        bytes += block(type: 0, last: false, [UInt8](repeating: 0, count: 34))
        bytes += block(type: 6, last: false, [UInt8](repeating: 0xAB, count: 300_000))
        bytes += block(type: 4, last: true, vorbis(comments))
        bytes += [UInt8](repeating: 0, count: 64) // "audio"
        let url = tmp.appendingPathComponent("\(UUID().uuidString).flac")
        try! Data(bytes).write(to: url)
        return url
    }

    // MARK: - Parser

    func test_readsVorbisCommentsAfterLargePicture() throws {
        let url = writeFLAC([
            "TITLE=10 Minutes", "ARTIST=Lee Hyori", "ALBUM=Stylish", "ALBUMARTIST=Lee Hyori",
            "tracknumber=3/12", "DISCNUMBER=1", "DATE=2003-08-13",
        ])
        let tags = try XCTUnwrap(AudioTags.read(fileURL: url))
        XCTAssertEqual(tags.title, "10 Minutes")
        XCTAssertEqual(tags.artist, "Lee Hyori")
        XCTAssertEqual(tags.album, "Stylish")
        XCTAssertEqual(tags.trackNumber, 3, "keys are case-insensitive; '3/12' → 3")
        XCTAssertEqual(tags.discNumber, 1)
        XCTAssertEqual(tags.year, 2003)
    }

    func test_multipleArtistsAreJoined_andAlbumArtistIsFallback() throws {
        let joined = try XCTUnwrap(AudioTags.read(fileURL: writeFLAC(["ARTIST=A.R. Rahman", "ARTIST=Sid Sriram"])))
        XCTAssertEqual(joined.artist, "A.R. Rahman, Sid Sriram")
        let onlyAlbumArtist = try XCTUnwrap(AudioTags.read(fileURL: writeFLAC(["ALBUM ARTIST=Anirudh", "TITLE=X"])))
        XCTAssertNil(onlyAlbumArtist.artist)
        XCTAssertEqual(onlyAlbumArtist.displayArtist, "Anirudh")
    }

    func test_id3PrefixedFLAC() throws {
        let tags = try XCTUnwrap(AudioTags.read(fileURL: writeFLAC(["ARTIST=Sean Roldan"], id3Prefix: true)))
        XCTAssertEqual(tags.artist, "Sean Roldan")
    }

    func test_nonFLACAndEmptyTags_returnNil() {
        let notFlac = tmp.appendingPathComponent("x.flac")
        try! Data("RIFF....WAVE".utf8).write(to: notFlac)
        XCTAssertNil(AudioTags.read(fileURL: notFlac))
        XCTAssertNil(AudioTags.read(fileURL: writeFLAC([])))
        XCTAssertNil(AudioTags.read(fileURL: tmp.appendingPathComponent("missing.flac")))
    }

    func test_leadingInt() {
        XCTAssertEqual(AudioTags.leadingInt("07"), 7)
        XCTAssertEqual(AudioTags.leadingInt(" 2/2"), 2)
        XCTAssertNil(AudioTags.leadingInt("A1"))
        XCTAssertNil(AudioTags.leadingInt(nil))
    }

    // MARK: - Library repair

    private final class NoCovers: CoverFetching {
        func fetchCoverImageData(title: String, artist: String?, durationSeconds: Double?) async -> Data? { nil }
    }

    func test_repair_fillsPlaceholdersOnly_andKeepsIdentity() async throws {
        let libDir = tmp.appendingPathComponent("AriaLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: libDir, withIntermediateDirectories: true)

        func place(_ comments: [String]) -> (id: UUID, fileName: String) {
            let id = UUID()
            let name = "\(id.uuidString).flac"
            try! FileManager.default.moveItem(at: writeFLAC(comments), to: libDir.appendingPathComponent(name))
            return (id, name)
        }
        let a = place(["TITLE=10 Minutes", "ARTIST=Lee Hyori", "ALBUM=Stylish"])
        let b = place(["TITLE=Tagged Title", "ARTIST=Other", "ALBUM=Kept?"])
        let importedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = [
            LocalTrack(id: a.id, title: "10 Minutes - Lee Hyori - Stylish", artist: "This Device",
                       artworkFileName: nil, fileName: a.fileName, importedAt: importedAt,
                       fileSizeBytes: 1, durationSeconds: 200, album: nil),
            // Already has an artist the user may have set: only the album fills in.
            LocalTrack(id: b.id, title: "My Title", artist: "Real Artist",
                       artworkFileName: nil, fileName: b.fileName, importedAt: importedAt,
                       fileSizeBytes: 1, durationSeconds: 100, album: nil),
        ]
        let store = InMemoryKeyValueStore(seed: try JSONEncoder().encode(seed))
        let manager = LocalLibraryManager(store: store, libraryDirectory: libDir, coverFetcher: NoCovers())

        let changed = await manager.repairTagsFromFiles()
        XCTAssertEqual(changed, [a.id, b.id])

        let ta = try XCTUnwrap(manager.tracks.first { $0.id == a.id })
        XCTAssertEqual(ta.title, "10 Minutes")
        XCTAssertEqual(ta.artist, "Lee Hyori")
        XCTAssertEqual(ta.album, "Stylish")
        XCTAssertEqual(ta.fileName, a.fileName)
        XCTAssertEqual(ta.importedAt, importedAt)
        XCTAssertEqual(ta.durationSeconds, 200)

        let tb = try XCTUnwrap(manager.tracks.first { $0.id == b.id })
        XCTAssertEqual(tb.title, "My Title", "title untouched when the artist was real")
        XCTAssertEqual(tb.artist, "Real Artist")
        XCTAssertEqual(tb.album, "Kept?")

        // Backup of the original list sits next to the library folder.
        let backup = tmp.appendingPathComponent("AriaLibrary-before-tag-repair.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        // Idempotent.
        let again = await manager.repairTagsFromFiles()
        XCTAssertTrue(again.isEmpty)
    }
}
