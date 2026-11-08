import XCTest
@testable import Aria___Music_Browser

/// Library radio mixing rules and the Wi-Fi transfer HTTP helpers.
@MainActor
final class LibraryRadioAndTransferTests: XCTestCase {

    // MARK: - Library radio

    private func analysis(bpm: Double, centroid: Double, lufs: Double = -12) -> TrackAnalysis {
        TrackAnalysis(version: TrackAnalysis.currentVersion, fileSize: 1, sampleRate: 44_100, channels: 2,
                      durationSeconds: 200, waveform: Data(), samplePeakDBFS: -1, clippedRuns: 0,
                      integratedLUFS: lufs, dynamicRange: 8, spectralCutoffHz: 20_000, cutoffIsSharp: false,
                      paddedTo16Bit: nil,
                      features: .init(tempoBPM: bpm, pulseClarity: 0.5, spectralCentroidHz: centroid, bassRatio: 0.2))
    }

    private func candidate(_ artist: String, _ album: String, bpm: Double, centroid: Double) -> LibraryRadio.Candidate {
        LibraryRadio.Candidate(id: UUID(), artist: artist, album: album,
                               analysis: analysis(bpm: bpm, centroid: centroid))
    }

    func test_mix_excludesSeed_noDuplicates_respectsCount() {
        let seed = candidate("A", "One", bpm: 120, centroid: 2_000)
        let pool = [seed] + (0..<20).map { i in
            candidate("Artist \(i)", "Album \(i)", bpm: 90 + Double(i) * 3, centroid: 1_000 + Double(i) * 150)
        }
        var rng = SeededGenerator(seed: 1)
        let mix = LibraryRadio.mix(seed: seed, candidates: pool, count: 10, using: &rng)
        XCTAssertEqual(mix.count, 10)
        XCTAssertFalse(mix.contains(seed.id))
        XCTAssertEqual(Set(mix).count, mix.count)
    }

    func test_mix_prefersSimilarTracks() {
        let seed = candidate("A", "One", bpm: 128, centroid: 3_000)
        let near = (0..<6).map { i in candidate("Near \(i)", "N\(i)", bpm: 126 + Double(i), centroid: 2_950 + Double(i) * 20) }
        let far = (0..<8).map { i in candidate("Far \(i)", "F\(i)", bpm: 72 + Double(i), centroid: 600 + Double(i) * 10) }
        var rng = SeededGenerator(seed: 9)
        let mix = LibraryRadio.mix(seed: seed, candidates: [seed] + near + far, count: 4, using: &rng)
        let nearIDs = Set(near.map(\.id))
        XCTAssertGreaterThanOrEqual(mix.filter { nearIDs.contains($0) }.count, 3)
    }

    func test_mix_capsTracksPerAlbum() {
        let seed = candidate("Band", "Record", bpm: 120, centroid: 2_000)
        let sameAlbum = (0..<6).map { _ in candidate("Band", "Record", bpm: 120, centroid: 2_000) }
        let others = (0..<6).map { i in candidate("Other \(i)", "X\(i)", bpm: 100, centroid: 1_000) }
        var rng = SeededGenerator(seed: 5)
        let mix = LibraryRadio.mix(seed: seed, candidates: [seed] + sameAlbum + others, count: 10, using: &rng)
        let albumIDs = Set(sameAlbum.map(\.id))
        // The seed already counts once, so at most one more from its album.
        XCTAssertLessThanOrEqual(mix.filter { albumIDs.contains($0) }.count, 1)
    }

    func test_tempoIsOctaveFolded() {
        let slow = LibraryRadio.vector(analysis(bpm: 60, centroid: 1_000))
        let fast = LibraryRadio.vector(analysis(bpm: 120, centroid: 1_000))
        XCTAssertEqual(slow[0], fast[0], accuracy: 1e-9)
    }

    // MARK: - HTTP

    func test_parseRequestHead() throws {
        let raw = "PUT /upload?pin=123456&x=a%20b HTTP/1.1\r\nHost: 192.168.1.5:8080\r\nContent-Length: 1234\r\nX-File-Name: 01%20Song.flac"
        let head = try XCTUnwrap(HTTPRequestHead.parse(Data(raw.utf8)))
        XCTAssertEqual(head.method, "PUT")
        XCTAssertEqual(head.path, "/upload")
        XCTAssertEqual(head.query["pin"], "123456")
        XCTAssertEqual(head.query["x"], "a b")
        XCTAssertEqual(head.contentLength, 1234)
        XCTAssertEqual(head.headers["x-file-name"], "01%20Song.flac")
    }

    func test_parseRejectsGarbage() {
        XCTAssertNil(HTTPRequestHead.parse(Data("NONSENSE".utf8)))
    }

    func test_sanitizedFileName_stripsPathsAndHiddenNames() {
        XCTAssertEqual(HTTPRequestHead.sanitizedFileName("01%20Song.flac"), "01 Song.flac")
        XCTAssertEqual(HTTPRequestHead.sanitizedFileName("../../etc/passwd.flac"), "passwd.flac")
        XCTAssertEqual(HTTPRequestHead.sanitizedFileName("C:\\Music\\Album\\track.wav"), "track.wav")
        XCTAssertNil(HTTPRequestHead.sanitizedFileName(".."))
        XCTAssertNil(HTTPRequestHead.sanitizedFileName(".hidden.flac"))
        XCTAssertNil(HTTPRequestHead.sanitizedFileName(""))
    }

    func test_responseFormat() {
        let data = HTTPRequestHead.response(status: 200, reason: "OK", contentType: "text/plain", body: Data("hi".utf8))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nhi"))
    }

    func test_transferPageIsSelfContained() {
        let html = TransferPage.html
        XCTAssertTrue(html.contains("/upload"))
        XCTAssertFalse(html.contains("http://"), "no external resources")
        XCTAssertFalse(html.contains("https://"), "no external resources")
    }

    // MARK: - Quality hints

    func test_hints_lossyFileIsNeverCalledATranscode() {
        var a = analysis(bpm: 120, centroid: 2_000)
        a.spectralCutoffHz = 16_000
        a.cutoffIsSharp = true
        XCTAssertTrue(QualityHint.hints(for: a, isLossless: false, declaredBitDepth: nil).isEmpty)
        XCTAssertEqual(QualityHint.hints(for: a, isLossless: true, declaredBitDepth: 16).first,
                       .likelyLossySource(cutoffKHz: 16))
    }

    func test_hints_hiResWithoutUltrasonicContentIsLikelyUpsampled() {
        var a = analysis(bpm: 120, centroid: 2_000)
        a.sampleRate = 96_000
        a.spectralCutoffHz = 21_000
        XCTAssertTrue(QualityHint.hints(for: a, isLossless: true, declaredBitDepth: 24)
            .contains(.likelyUpsampled(cutoffKHz: 21)))
    }
}
