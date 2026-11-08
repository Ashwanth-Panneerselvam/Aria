import Foundation

/// Builds an "endless" mix from the local library that flows from a seed
/// track, using only on-device analysis (tempo, beat strength, brightness,
/// bass weight, loudness, dynamics). Nothing leaves the phone.
///
/// Each next pick is close to the previous track *and* anchored to the seed,
/// so the mix drifts gently instead of wandering off. Artists don't repeat
/// back-to-back and no album appears more than twice.
nonisolated enum LibraryRadio {

    nonisolated struct Candidate {
        let id: UUID
        let artist: String
        let album: String
        let analysis: TrackAnalysis
    }

    /// Relative importance of each feature dimension (after z-scoring).
    static let weights: [Double] = [1.0, 0.8, 1.2, 0.8, 0.6, 0.5]

    /// Raw feature vector: tempo (octave-folded into 80–160 BPM, log scale),
    /// pulse clarity, brightness (log Hz), bass share, loudness, DR.
    static func vector(_ a: TrackAnalysis) -> [Double] {
        var bpm = a.features.tempoBPM ?? 110
        if bpm > 0 {
            while bpm < 80 { bpm *= 2 }
            while bpm > 160 { bpm /= 2 }
        } else {
            bpm = 110
        }
        return [
            log2(bpm),
            a.features.pulseClarity,
            log2(max(a.features.spectralCentroidHz, 100)),
            a.features.bassRatio,
            a.integratedLUFS ?? -14,
            Double(a.dynamicRange ?? 8),
        ]
    }

    /// Ordered track IDs to queue after `seed` (the seed itself excluded).
    static func mix<R: RandomNumberGenerator>(seed: Candidate,
                                              candidates: [Candidate],
                                              count: Int,
                                              using rng: inout R) -> [UUID] {
        let pool = candidates.filter { $0.id != seed.id }
        guard !pool.isEmpty, count > 0 else { return [] }

        let all = [seed] + pool
        let raw = all.map { vector($0.analysis) }
        let normalized = zScores(raw)
        let seedVec = normalized[0]
        let vectors = Array(normalized.dropFirst())

        var used = Set<Int>()
        var albumCounts: [String: Int] = [:]
        albumCounts[albumKey(seed), default: 0] += 1
        var recentArtists: [String] = [seed.artist.lowercased()]
        var current = seedVec
        var result: [UUID] = []

        while result.count < count, used.count < pool.count {
            var scored: [(index: Int, score: Double)] = []
            for (i, c) in pool.enumerated() where !used.contains(i) {
                if albumCounts[albumKey(c), default: 0] >= 2 { continue }
                var score = distance(current, vectors[i]) + 0.35 * distance(seedVec, vectors[i])
                if recentArtists.suffix(2).contains(c.artist.lowercased()) { score += 0.6 }
                scored.append((i, score))
            }
            guard !scored.isEmpty else { break }
            scored.sort { $0.score < $1.score }
            // A little variety: pick among the closest few, nearer = likelier.
            let top = Array(scored.prefix(4))
            let weightsForPick = top.indices.map { 1.0 / Double($0 + 1) }
            let total = weightsForPick.reduce(0, +)
            var roll = Double.random(in: 0..<total, using: &rng)
            var chosen = top[0].index
            for (k, w) in weightsForPick.enumerated() {
                if roll < w { chosen = top[k].index; break }
                roll -= w
            }
            used.insert(chosen)
            let pick = pool[chosen]
            result.append(pick.id)
            albumCounts[albumKey(pick), default: 0] += 1
            recentArtists.append(pick.artist.lowercased())
            current = vectors[chosen]
        }
        return result
    }

    static func mix(seed: Candidate, candidates: [Candidate], count: Int) -> [UUID] {
        var rng = SystemRandomNumberGenerator()
        return mix(seed: seed, candidates: candidates, count: count, using: &rng)
    }

    // MARK: - Math

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        var s = 0.0
        for i in 0..<min(a.count, b.count) {
            let w = i < weights.count ? weights[i] : 1
            let d = a[i] - b[i]
            s += w * d * d
        }
        return s.squareRoot()
    }

    /// Per-dimension z-scores; a constant dimension maps to 0.
    static func zScores(_ rows: [[Double]]) -> [[Double]] {
        guard let width = rows.first?.count, rows.count > 1 else {
            return rows.map { $0.map { _ in 0 } }
        }
        var out = rows
        for d in 0..<width {
            let col = rows.map { $0[d] }
            let mean = col.reduce(0, +) / Double(col.count)
            let variance = col.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(col.count)
            let sd = variance.squareRoot()
            for r in 0..<rows.count {
                out[r][d] = sd > 1e-9 ? (rows[r][d] - mean) / sd : 0
            }
        }
        return out
    }

    private static func albumKey(_ c: Candidate) -> String {
        c.album.isEmpty ? "id:\(c.id.uuidString)" : "\(c.artist.lowercased())|\(c.album.lowercased())"
    }
}
