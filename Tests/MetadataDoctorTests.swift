import XCTest
@testable import Aria___Music_Browser

/// Metadata Doctor detection rules and the library edit/undo API.
@MainActor
final class MetadataDoctorTests: XCTestCase {

    private func item(_ title: String, artist: String? = nil, album: String? = nil,
                      art: Bool = false, id: UUID = UUID()) -> MetadataDoctor.Item {
        MetadataDoctor.Item(id: id, title: title, artist: artist, album: album, hasArtwork: art)
    }

    // MARK: - Normalisation / variants

    func test_key_ignoresCasePunctuationAccentsAndThe() {
        XCTAssertEqual(MetadataDoctor.key("A.R. Rahman"), MetadataDoctor.key("AR Rahman"))
        XCTAssertEqual(MetadataDoctor.key("a r rahman"), MetadataDoctor.key("A.R. Rahman"))
        XCTAssertEqual(MetadataDoctor.key("Beyoncé"), MetadataDoctor.key("Beyonce"))
        XCTAssertEqual(MetadataDoctor.key("The Weeknd"), MetadataDoctor.key("Weeknd"))
        XCTAssertEqual(MetadataDoctor.key("Simon & Garfunkel"), MetadataDoctor.key("Simon and Garfunkel"))
        XCTAssertNotEqual(MetadataDoctor.key("Anirudh"), MetadataDoctor.key("Anirudh Ravichander"))
    }

    func test_artistVariants_suggestsMostCommonSpelling() {
        let items = [
            item("a", artist: "A.R. Rahman"), item("b", artist: "A.R. Rahman"),
            item("c", artist: "AR Rahman"), item("d", artist: "Anirudh"), item("e", artist: nil),
        ]
        let groups = MetadataDoctor.artistVariants(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].suggested, "A.R. Rahman")
        XCTAssertEqual(groups[0].trackCount, 3)
    }

    func test_variants_tieBreaksTowardStyledSpelling() {
        let groups = MetadataDoctor.variants(["ar rahman", "A.R. Rahman"])
        XCTAssertEqual(groups.first?.suggested, "A.R. Rahman")
    }

    func test_noVariantsWhenSpellingsAgree() {
        XCTAssertTrue(MetadataDoctor.albumVariants([item("a", album: "Vikram"), item("b", album: "Vikram")]).isEmpty)
    }

    // MARK: - Titles

    func test_tidyTitle_rules() {
        XCTAssertEqual(MetadataDoctor.tidyTitle("01 - Hukum").0, "Hukum")
        XCTAssertEqual(MetadataDoctor.tidyTitle("03. Arabic Kuthu").0, "Arabic Kuthu")
        XCTAssertEqual(MetadataDoctor.tidyTitle("Naa Ready (Official Audio)").0, "Naa Ready")
        XCTAssertEqual(MetadataDoctor.tidyTitle("Song [HD] (Lyrics)").0, "Song")
        XCTAssertEqual(MetadataDoctor.tidyTitle("My_Song_Name").0, "My Song Name")
        XCTAssertEqual(MetadataDoctor.tidyTitle("Too   many  spaces ").0, "Too many spaces")
    }

    func test_tidyTitle_leavesRealTitlesAlone() {
        for title in ["2-Step", "99 Luftballons", "3.14 Pi", "7 Rings", "Aaluma Doluma (Extended Mix)",
                      "Song (feat. Someone)", "1999", "Jay-Z"] {
            let (new, reasons) = MetadataDoctor.tidyTitle(title)
            XCTAssertEqual(new, title, title)
            XCTAssertTrue(reasons.isEmpty, title)
        }
    }

    // MARK: - Artwork

    func test_artworkFixes_useAlbumMates_preferringSameArtist() {
        let withArtOther = item("x", artist: "Other", album: "Vikram", art: true)
        let withArtSame = item("y", artist: "Anirudh", album: "VIKRAM", art: true)
        let missing = item("z", artist: "Anirudh", album: "Vikram", art: false)
        let lonely = item("w", artist: "Anirudh", album: "Leo", art: false)
        let fixes = MetadataDoctor.artworkFixes([withArtOther, withArtSame, missing, lonely])
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes.first?.id, missing.id)
        XCTAssertEqual(fixes.first?.sourceID, withArtSame.id)
    }

    // MARK: - Split from title

    func test_split_titleArtistAlbum() {
        let t = item("10 Minutes - Lee Hyori - Stylish")
        let fix = MetadataDoctor.splitFixes([t], pattern: .titleArtistAlbum).first
        XCTAssertEqual(fix?.title, "10 Minutes")
        XCTAssertEqual(fix?.artist, "Lee Hyori")
        XCTAssertEqual(fix?.album, "Stylish")
    }

    func test_split_respectsHyphenatedNamesAndSkipsTaggedTracks() {
        XCTAssertEqual(MetadataDoctor.parts("Jay-Z - Empire State Of Mind"), ["Jay-Z", "Empire State Of Mind"])
        let tagged = item("A - B - C", artist: "Real")
        XCTAssertTrue(MetadataDoctor.splitFixes([tagged], pattern: .titleArtistAlbum).isEmpty)
        let fix = MetadataDoctor.splitFixes([item("Jay-Z – Empire")], pattern: .artistTitle).first
        XCTAssertEqual(fix?.artist, "Jay-Z")
        XCTAssertEqual(fix?.title, "Empire")
    }

    func test_likelyPattern() {
        let threes = [item("a - b - c"), item("d - e - f"), item("g - h")]
        XCTAssertEqual(MetadataDoctor.likelyPattern(threes), .titleArtistAlbum)
        let twos = [item("a - b"), item("c - d"), item("e - f - g")]
        XCTAssertEqual(MetadataDoctor.likelyPattern(twos), .artistTitle)
    }

    // MARK: - Library edits

    private final class NoCovers: CoverFetching {
        func fetchCoverImageData(title: String, artist: String?, durationSeconds: Double?) async -> Data? { nil }
    }

    func test_applyAndRestore_keepIdentity_andCopyArtwork() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("doctor-\(UUID().uuidString)")
        let libDir = tmp.appendingPathComponent("AriaLibrary", isDirectory: true)
        let artDir = libDir.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = UUID(), b = UUID()
        for id in [a, b] {
            try Data([0, 1, 2]).write(to: libDir.appendingPathComponent("\(id.uuidString).flac"))
        }
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0] + [UInt8](repeating: 7, count: 64))
        try jpeg.write(to: artDir.appendingPathComponent("\(a.uuidString).jpg"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let seed = [
            LocalTrack(id: a, title: "01 - Song", artist: "AR Rahman", artworkFileName: "\(a.uuidString).jpg",
                       fileName: "\(a.uuidString).flac", importedAt: date, fileSizeBytes: 3, durationSeconds: 10,
                       album: "Album"),
            LocalTrack(id: b, title: "Other", artist: "A.R. Rahman", artworkFileName: nil,
                       fileName: "\(b.uuidString).flac", importedAt: date, fileSizeBytes: 3, durationSeconds: 20,
                       album: "Album"),
        ]
        let manager = LocalLibraryManager(store: InMemoryKeyValueStore(seed: try JSONEncoder().encode(seed)),
                                          libraryDirectory: libDir, coverFetcher: NoCovers())

        let previous = manager.applyMetadataEdits([
            a: .init(title: "Song", artist: "A.R. Rahman"),
            b: .init(artworkFrom: a),
        ])
        XCTAssertEqual(Set(previous.map(\.id)), [a, b])

        let ta = try XCTUnwrap(manager.tracks.first { $0.id == a })
        XCTAssertEqual(ta.title, "Song")
        XCTAssertEqual(ta.artist, "A.R. Rahman")
        XCTAssertEqual(ta.fileName, "\(a.uuidString).flac")
        XCTAssertEqual(ta.importedAt, date)

        let tb = try XCTUnwrap(manager.tracks.first { $0.id == b })
        let artName = try XCTUnwrap(tb.artworkFileName)
        XCTAssertNotEqual(artName, "\(a.uuidString).jpg", "the target gets its own copy")
        XCTAssertEqual(try Data(contentsOf: artDir.appendingPathComponent(artName)), jpeg)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("AriaLibrary-before-metadata-doctor.json").path))

        // Undo.
        XCTAssertEqual(manager.restoreMetadata(previous), [a, b])
        XCTAssertEqual(manager.tracks.first { $0.id == a }?.title, "01 - Song")
        XCTAssertEqual(manager.tracks.first { $0.id == a }?.artist, "AR Rahman")
        XCTAssertNil(manager.tracks.first { $0.id == b }?.artworkFileName)

        // No-op edits report nothing.
        XCTAssertTrue(manager.applyMetadataEdits([a: .init(title: "01 - Song")]).isEmpty)
    }
}
