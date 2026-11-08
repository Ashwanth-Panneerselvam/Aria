import XCTest
@testable import Aria___Music_Browser

/// The Galaxy map must keep sound-alike tracks together and be repeatable.
@MainActor
final class GalaxyLayoutTests: XCTestCase {

    /// Three well-separated clusters in feature space.
    private func clusteredFeatures(perCluster: Int = 30) -> (rows: [[Double]], labels: [Int]) {
        var rng = SeededGenerator(seed: 42)
        let centres: [[Double]] = [
            [log2(90), 0.2, log2(800), 0.40, -16, 12],
            [log2(128), 0.7, log2(3_000), 0.15, -8, 5],
            [log2(100), 0.4, log2(1_600), 0.25, -12, 8],
        ]
        var rows: [[Double]] = []
        var labels: [Int] = []
        for (c, centre) in centres.enumerated() {
            for _ in 0..<perCluster {
                rows.append(centre.map { $0 + Double.random(in: -0.02...0.02, using: &rng) * max(1, abs($0)) })
                labels.append(c)
            }
        }
        return (rows, labels)
    }

    func test_embed_returnsOnePointPerRow_inUnitRange() {
        let (rows, _) = clusteredFeatures()
        let points = GalaxyLayout.embed(rows, iterations: 300)
        XCTAssertEqual(points.count, rows.count)
        for p in points {
            XCTAssertLessThanOrEqual(abs(p.x), 1)
            XCTAssertLessThanOrEqual(abs(p.y), 1)
        }
    }

    func test_embed_keepsClustersTogether() {
        let (rows, labels) = clusteredFeatures()
        let points = GalaxyLayout.embed(rows, iterations: 400)
        // Each point's nearest neighbour on the map should be in its cluster.
        var agree = 0
        for i in points.indices {
            var best = -1
            var bestD = Double.infinity
            for j in points.indices where j != i {
                let d = points[i] - points[j]
                let dd = d.x * d.x + d.y * d.y
                if dd < bestD { bestD = dd; best = j }
            }
            if labels[best] == labels[i] { agree += 1 }
        }
        XCTAssertGreaterThan(Double(agree) / Double(points.count), 0.95)
    }

    func test_embed_isDeterministic() {
        let (rows, _) = clusteredFeatures(perCluster: 12)
        let a = GalaxyLayout.embed(rows, iterations: 200)
        let b = GalaxyLayout.embed(rows, iterations: 200)
        XCTAssertEqual(a, b)
    }

    func test_embed_tinyInputs() {
        XCTAssertTrue(GalaxyLayout.embed([]).isEmpty)
        XCTAssertEqual(GalaxyLayout.embed([[1, 2, 3, 4, 5, 6]]).count, 1)
        XCTAssertEqual(GalaxyLayout.embed([[1, 2, 3, 4, 5, 6], [2, 3, 4, 5, 6, 7]]).count, 2)
        // 3–4 points use PCA only and still stay in range.
        let few = GalaxyLayout.embed([[1, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0], [0, 0, 1, 0, 0, 0]])
        XCTAssertEqual(few.count, 3)
        XCTAssertTrue(few.allSatisfy { abs($0.x) <= 1 && abs($0.y) <= 1 })
    }

    func test_identicalTracks_doNotProduceNaN() {
        let rows = Array(repeating: [log2(120), 0.5, log2(2_000), 0.2, -10, 8], count: 10)
        let points = GalaxyLayout.embed(rows, iterations: 100)
        XCTAssertEqual(points.count, 10)
        XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func test_rankNormalized() {
        XCTAssertEqual(LibraryAnalysisManager.rankNormalized([5, 1, 3]), [1, 0, 0.5])
        XCTAssertEqual(LibraryAnalysisManager.rankNormalized([7]), [0.5])
    }
}
