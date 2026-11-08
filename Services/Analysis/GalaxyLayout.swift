import Foundation

/// Places every analysed track on a 2D map so that tracks which *sound*
/// alike sit close together — the Galaxy.
///
/// Method: the same six sound features Library Radio uses (z-scored and
/// weighted), embedded with exact t-SNE (perplexity ≤ 30, PCA initialisation,
/// early exaggeration). Deterministic: the same library gives the same map.
/// Exact t-SNE is O(n²) per iteration, fine for a few thousand tracks on an
/// A12 in the background; above `maxTSNEPoints` it falls back to PCA.
nonisolated enum GalaxyLayout {

    static let maxTSNEPoints = 1_500

    /// Normalised positions in −1…1 (both axes), one per input row.
    static func embed(_ features: [[Double]], weights: [Double] = LibraryRadio.weights,
                      iterations: Int = 750, isCancelled: () -> Bool = { false }) -> [SIMD2<Double>] {
        let n = features.count
        guard n > 0 else { return [] }
        guard n > 2 else {
            return n == 1 ? [SIMD2(0, 0)] : [SIMD2(-0.5, 0), SIMD2(0.5, 0)]
        }
        let x = weighted(LibraryRadio.zScores(features), weights: weights)
        var y = pca2D(x)
        if n <= maxTSNEPoints, n >= 5 {
            // Large libraries get fewer iterations to keep this to seconds.
            let iters = n > 800 ? min(iterations, 500) : iterations
            y = tsne(x, initial: y, iterations: iters, isCancelled: isCancelled) ?? y
        }
        return normalized(y)
    }

    // MARK: - Preprocessing

    static func weighted(_ rows: [[Double]], weights: [Double]) -> [[Double]] {
        rows.map { row in
            row.enumerated().map { i, v in v * (i < weights.count ? weights[i].squareRoot() : 1) }
        }
    }

    /// Projection onto the top two principal components (power iteration).
    static func pca2D(_ x: [[Double]]) -> [SIMD2<Double>] {
        let n = x.count
        let d = x.first?.count ?? 0
        guard d > 0 else { return Array(repeating: SIMD2(0, 0), count: n) }
        var mean = [Double](repeating: 0, count: d)
        for row in x { for j in 0..<d { mean[j] += row[j] } }
        for j in 0..<d { mean[j] /= Double(n) }
        var cov = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        for row in x {
            for a in 0..<d {
                let da = row[a] - mean[a]
                for b in a..<d { cov[a][b] += da * (row[b] - mean[b]) }
            }
        }
        for a in 0..<d { for b in a..<d { cov[a][b] /= Double(max(n - 1, 1)); cov[b][a] = cov[a][b] } }

        func topEigenvector(_ m: [[Double]], orthogonalTo other: [Double]?) -> [Double] {
            var v = (0..<d).map { 1.0 + Double($0) * 0.1 }
            for _ in 0..<100 {
                var w = [Double](repeating: 0, count: d)
                for a in 0..<d { for b in 0..<d { w[a] += m[a][b] * v[b] } }
                if let o = other {
                    let dot = zip(w, o).reduce(0) { $0 + $1.0 * $1.1 }
                    for a in 0..<d { w[a] -= dot * o[a] }
                }
                let norm = w.reduce(0) { $0 + $1 * $1 }.squareRoot()
                guard norm > 1e-12 else { break }
                v = w.map { $0 / norm }
            }
            return v
        }
        let e1 = topEigenvector(cov, orthogonalTo: nil)
        let e2 = topEigenvector(cov, orthogonalTo: e1)
        return x.map { row in
            var p = SIMD2<Double>(0, 0)
            for j in 0..<d {
                p.x += (row[j] - mean[j]) * e1[j]
                p.y += (row[j] - mean[j]) * e2[j]
            }
            return p
        }
    }

    // MARK: - t-SNE

    static func tsne(_ x: [[Double]], initial: [SIMD2<Double>], iterations: Int,
                     isCancelled: () -> Bool) -> [SIMD2<Double>]? {
        let n = x.count
        let perplexity = min(30.0, Double(n - 1) / 3.0)
        guard perplexity >= 1.5 else { return nil }

        // Squared distances.
        var dist = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                var s = 0.0
                for k in 0..<x[i].count { let t = x[i][k] - x[j][k]; s += t * t }
                dist[i * n + j] = s
                dist[j * n + i] = s
            }
        }

        // Conditional probabilities with per-point precision found by bisection.
        var p = [Double](repeating: 0, count: n * n)
        let targetEntropy = log(perplexity)
        var row = [Double](repeating: 0, count: n)
        for i in 0..<n {
            if isCancelled() { return nil }
            var beta = 1.0, lo = 0.0, hi = Double.infinity
            for _ in 0..<60 {
                var sum = 0.0, weighted = 0.0
                for j in 0..<n where j != i {
                    let v = exp(-dist[i * n + j] * beta)
                    row[j] = v
                    sum += v
                    weighted += v * dist[i * n + j]
                }
                row[i] = 0
                let sumSafe = max(sum, 1e-300)
                let entropy = log(sumSafe) + beta * weighted / sumSafe
                for j in 0..<n { row[j] /= sumSafe }
                let diff = entropy - targetEntropy
                if abs(diff) < 1e-5 { break }
                if diff > 0 {
                    lo = beta
                    beta = hi.isInfinite ? beta * 2 : (beta + hi) / 2
                } else {
                    hi = beta
                    beta = (beta + lo) / 2
                }
            }
            for j in 0..<n { p[i * n + j] = row[j] }
        }
        // Symmetrise and normalise.
        let twoN = 2.0 * Double(n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let v = max((p[i * n + j] + p[j * n + i]) / twoN, 1e-12)
                p[i * n + j] = v
                p[j * n + i] = v
            }
            p[i * n + i] = 0
        }

        dist = []  // no longer needed; free before the n² iteration buffers

        // Initial layout: PCA scaled to a small spread.
        var y = initial
        let spread = (y.reduce(0) { $0 + $1.x * $1.x + $1.y * $1.y } / Double(n)).squareRoot()
        let scale = spread > 0 ? 1e-2 / spread : 1
        for i in 0..<n { y[i] *= scale }

        var update = [SIMD2<Double>](repeating: .zero, count: n)
        var gains = [SIMD2<Double>](repeating: SIMD2(1, 1), count: n)
        var grad = [SIMD2<Double>](repeating: .zero, count: n)
        var q = [Double](repeating: 0, count: n * n)
        let exaggerationIters = min(250, iterations / 3)
        let learningRate = max(Double(n) / 12.0, 50.0)

        for iter in 0..<iterations {
            if iter % 25 == 0, isCancelled() { return nil }
            let exaggeration = iter < exaggerationIters ? 12.0 : 1.0
            let momentum = iter < exaggerationIters ? 0.5 : 0.8

            // Student-t affinities.
            var z = 0.0
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let d = y[i] - y[j]
                    let v = 1.0 / (1.0 + d.x * d.x + d.y * d.y)
                    q[i * n + j] = v
                    q[j * n + i] = v
                    z += 2 * v
                }
            }
            z = max(z, 1e-300)

            for i in 0..<n {
                var g = SIMD2<Double>(0, 0)
                let yi = y[i]
                for j in 0..<n where j != i {
                    let qij = q[i * n + j]
                    let mult = (exaggeration * p[i * n + j] - qij / z) * qij
                    g += mult * (yi - y[j])
                }
                grad[i] = 4 * g
            }

            for i in 0..<n {
                for axis in 0..<2 {
                    let gv = grad[i][axis]
                    let uv = update[i][axis]
                    var gain = gains[i][axis]
                    gain = (gv > 0) != (uv > 0) ? gain + 0.2 : gain * 0.8
                    gain = max(gain, 0.01)
                    gains[i][axis] = gain
                    update[i][axis] = momentum * uv - learningRate * gain * gv
                }
                y[i] += update[i]
            }

            // Re-centre.
            var c = SIMD2<Double>(0, 0)
            for v in y { c += v }
            c /= Double(n)
            for i in 0..<n { y[i] -= c }
        }
        return y
    }

    /// Centres and scales so the outermost points (ignoring the top 1 % as
    /// outliers) sit at ±1, clamping the rest.
    static func normalized(_ y: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard !y.isEmpty else { return [] }
        var c = SIMD2<Double>(0, 0)
        for v in y { c += v }
        c /= Double(y.count)
        let centred = y.map { $0 - c }
        let radii = centred.map { max(abs($0.x), abs($0.y)) }.sorted()
        let idx = min(radii.count - 1, Int(Double(radii.count) * 0.99))
        let r = max(radii[idx], 1e-9)
        return centred.map { v in
            SIMD2(max(-1, min(1, v.x / r)), max(-1, min(1, v.y / r)))
        }
    }
}
