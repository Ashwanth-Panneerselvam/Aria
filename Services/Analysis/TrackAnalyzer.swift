import AVFoundation
import Accelerate
import Foundation

/// Decodes a local audio file once and measures everything `TrackAnalysis`
/// holds, in a single streaming pass. Pure and synchronous — call it off the
/// main thread (`LibraryAnalysisManager` does).
///
/// Cost: one full decode plus light per-sample math. On an A12 a 5-minute
/// 16/44.1 FLAC takes on the order of a second or two.
nonisolated enum TrackAnalyzer {

    nonisolated enum AnalyzerError: Error { case unreadable, empty, cancelled }

    static let waveformBuckets = 240
    private static let chunkFrames: AVAudioFrameCount = 32_768
    private static let fftLog2n: vDSP_Length = 12          // 4096-point
    private static let targetFFTCount = 160
    private static let onsetHop = 1024

    /// - Parameters:
    ///   - declaredBitDepth: source word length from the header; enables the
    ///     padded-16-bit check when > 16.
    ///   - isCancelled: polled between chunks.
    static func analyze(fileURL: URL,
                        declaredBitDepth: Int?,
                        isCancelled: () -> Bool = { false }) throws -> TrackAnalysis {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: fileURL) } catch { throw AnalyzerError.unreadable }

        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = file.length
        guard totalFrames > 0, sampleRate > 0, channelCount > 0 else { throw AnalyzerError.empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
              buffer.floatChannelData != nil else { throw AnalyzerError.unreadable }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
        let isMono = channelCount == 1

        // --- accumulators ---
        var acc = Accumulators(sampleRate: sampleRate, totalFrames: totalFrames,
                               buckets: waveformBuckets, channelsMeasured: isMono ? 1 : 2,
                               checkPadding: (declaredBitDepth ?? 0) > 16)
        let fft = SpectrumAccumulator(log2n: fftLog2n)
        let totalChunks = max(1, Int((totalFrames + Int64(chunkFrames) - 1) / Int64(chunkFrames)))
        let fftStride = max(1, totalChunks / targetFFTCount)

        var chunkIndex = 0
        while true {
            if isCancelled() { throw AnalyzerError.cancelled }
            do { try file.read(into: buffer, frameCount: chunkFrames) } catch { break }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let left = data[0]
            let right = isMono ? data[0] : data[1]

            acc.consume(left: left, right: right, count: n)

            if chunkIndex % fftStride == 0, n >= fft.size {
                fft.add(left: left, right: right, count: fft.size)
            }
            chunkIndex += 1
        }

        guard acc.framesSeen > 0 else { throw AnalyzerError.empty }
        acc.finish()

        let spectrum = fft.averagedPowerDB()
        let cutoff = spectrum.flatMap { SpectrumMath.cutoff(powerDB: $0, sampleRate: sampleRate, fftSize: fft.size) }
        let centroid = spectrum.map { SpectrumMath.centroid(powerDB: $0, sampleRate: sampleRate, fftSize: fft.size) } ?? 0
        let bass = spectrum.map { SpectrumMath.bassRatio(powerDB: $0, sampleRate: sampleRate, fftSize: fft.size) } ?? 0
        let tempo = TempoMath.estimate(envelope: acc.onsetEnvelope,
                                       envelopeRate: sampleRate / Double(onsetHop))

        return TrackAnalysis(
            version: TrackAnalysis.currentVersion,
            fileSize: fileSize,
            sampleRate: sampleRate,
            channels: channelCount,
            durationSeconds: Double(acc.framesSeen) / sampleRate,
            waveform: acc.waveformData(),
            samplePeakDBFS: acc.peak > 0 ? 20 * log10(Double(acc.peak)) : -144,
            clippedRuns: acc.clippedRuns,
            integratedLUFS: LoudnessMath.integratedLUFS(subBlockEnergies: acc.subBlockEnergies),
            dynamicRange: DynamicRangeMath.score(blocks: acc.drBlocks),
            spectralCutoffHz: cutoff?.hz,
            cutoffIsSharp: cutoff?.sharp ?? false,
            paddedTo16Bit: acc.paddingVerdict,
            features: TrackAnalysis.Features(
                tempoBPM: tempo?.bpm,
                pulseClarity: tempo?.clarity ?? 0,
                spectralCentroidHz: centroid,
                bassRatio: bass
            )
        )
    }
}

// MARK: - Per-sample accumulators

/// Everything measured sample-by-sample in the streaming pass.
nonisolated struct Accumulators {
    let sampleRate: Double
    let totalFrames: Int64
    let buckets: Int
    let channelsMeasured: Int
    let checkPadding: Bool

    var framesSeen: Int64 = 0
    var peak: Float = 0

    // Waveform: per-bucket energy.
    private var bucketSumSq: [Double]
    private var bucketCount: [Int]

    // Clipping.
    var clippedRuns = 0
    private var clipRun = 0

    // BS.1770: K-weighting per channel, 100 ms sub-blocks.
    private var kLeft: KWeighting
    private var kRight: KWeighting
    private let subBlockFrames: Int
    private var subSumL = 0.0, subSumR = 0.0, subCount = 0
    private(set) var subBlockEnergies: [Double] = []

    // DR: 3 s blocks, per channel RMS (√2 scaled) + peak.
    private let drBlockFrames: Int
    private var drSumL = 0.0, drSumR = 0.0, drPeakL: Float = 0, drPeakR: Float = 0, drCount = 0
    private(set) var drBlocks: [DynamicRangeMath.Block] = []

    // Onset envelope: mono energy per hop.
    private var hopSum = 0.0, hopCount = 0
    private(set) var onsetEnvelope: [Float] = []

    // Padded bit depth: samples checked / samples off the 16-bit grid.
    private var padChecked = 0, padNonZero = 0, padOffGrid = 0
    private static let padCheckLimit = 4_000_000

    init(sampleRate: Double, totalFrames: Int64, buckets: Int, channelsMeasured: Int, checkPadding: Bool) {
        self.sampleRate = sampleRate
        self.totalFrames = totalFrames
        self.buckets = buckets
        self.channelsMeasured = channelsMeasured
        self.checkPadding = checkPadding
        bucketSumSq = Array(repeating: 0, count: buckets)
        bucketCount = Array(repeating: 0, count: buckets)
        kLeft = KWeighting(sampleRate: sampleRate)
        kRight = KWeighting(sampleRate: sampleRate)
        subBlockFrames = max(1, Int(sampleRate / 10))
        drBlockFrames = max(1, Int(sampleRate * 3))
    }

    mutating func consume(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        let total = max(totalFrames, 1)
        let stereo = channelsMeasured == 2
        for i in 0..<count {
            let l = left[i]
            let r = right[i]
            let al = abs(l), ar = abs(r)
            let m = max(al, ar)
            if m > peak { peak = m }

            // clipping
            if m >= 0.9999 {
                clipRun += 1
                if clipRun == 3 { clippedRuns += 1 }
            } else {
                clipRun = 0
            }

            // waveform bucket
            let frame = framesSeen + Int64(i)
            let b = min(buckets - 1, Int(frame * Int64(buckets) / total))
            let mono = Double(l + r) * 0.5
            bucketSumSq[b] += mono * mono
            bucketCount[b] += 1

            // loudness
            let kl = kLeft.process(Double(l))
            subSumL += kl * kl
            if stereo {
                let kr = kRight.process(Double(r))
                subSumR += kr * kr
            }
            subCount += 1
            if subCount == subBlockFrames {
                let energy = (subSumL + (stereo ? subSumR : 0)) / Double(subCount)
                subBlockEnergies.append(energy)
                subSumL = 0; subSumR = 0; subCount = 0
            }

            // DR blocks
            drSumL += Double(l) * Double(l)
            drSumR += Double(r) * Double(r)
            if al > drPeakL { drPeakL = al }
            if ar > drPeakR { drPeakR = ar }
            drCount += 1
            if drCount == drBlockFrames { closeDRBlock() }

            // onset envelope
            hopSum += mono * mono
            hopCount += 1
            if hopCount == 1024 {
                onsetEnvelope.append(Float(hopSum / Double(hopCount)))
                hopSum = 0; hopCount = 0
            }

            // padded bit depth (24-bit file carrying 16-bit audio)
            if checkPadding, padChecked < Self.padCheckLimit {
                padChecked += 1
                if l != 0 {
                    padNonZero += 1
                    let scaled = Double(l) * 32_768
                    if abs(scaled - scaled.rounded()) > 1e-4 { padOffGrid += 1 }
                }
            }
        }
        framesSeen += Int64(count)
    }

    private mutating func closeDRBlock() {
        let n = Double(max(drCount, 1))
        drBlocks.append(DynamicRangeMath.Block(
            rmsLeft: (2 * drSumL / n).squareRoot(),
            rmsRight: (2 * drSumR / n).squareRoot(),
            peakLeft: Double(drPeakL), peakRight: Double(drPeakR)))
        drSumL = 0; drSumR = 0; drPeakL = 0; drPeakR = 0; drCount = 0
    }

    mutating func finish() {
        // Keep a trailing partial DR block if it's at least a second long.
        if Double(drCount) >= sampleRate { closeDRBlock() }
    }

    /// nil when not checked or too little non-silent audio to judge.
    var paddingVerdict: Bool? {
        guard checkPadding, padNonZero >= 10_000 else { return nil }
        return padOffGrid == 0
    }

    func waveformData() -> Data {
        var rms = [Double](repeating: 0, count: buckets)
        for i in 0..<buckets where bucketCount[i] > 0 {
            rms[i] = (bucketSumSq[i] / Double(bucketCount[i])).squareRoot()
        }
        let maxRMS = rms.max() ?? 0
        guard maxRMS > 0 else { return Data(repeating: 0, count: buckets) }
        let range = 36.0
        let bytes: [UInt8] = rms.map { v in
            guard v > 0 else { return 0 }
            let db = 20 * log10(v / maxRMS)
            let norm = min(1, max(0, (db + range) / range))
            return UInt8((norm * 255).rounded())
        }
        return Data(bytes)
    }
}

// MARK: - K-weighting (ITU-R BS.1770-4), any sample rate

nonisolated struct KWeighting {
    private var s1 = Biquad.State(), s2 = Biquad.State()
    private let shelf: Biquad.Coefficients
    private let highpass: Biquad.Coefficients

    init(sampleRate fs: Double) {
        // Coefficient derivation as in libebur128.
        var f0 = 1681.974450955533
        let gainDB = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gainDB / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        shelf = Biquad.Coefficients(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0)

        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        highpass = Biquad.Coefficients(
            b0: 1, b1: -2, b2: 1,
            a1: 2 * (k * k - 1) / a0,
            a2: (1 - k / q + k * k) / a0)
    }

    mutating func process(_ x: Double) -> Double {
        let sh = shelf, hp = highpass
        let y = sh.process(x, state: &s1)
        return hp.process(y, state: &s2)
    }
}

// MARK: - Loudness / DR

nonisolated enum LoudnessMath {
    /// Gated integrated loudness from 100 ms mean-square sub-blocks
    /// (400 ms blocks, 75 % overlap, −70 LUFS absolute and −10 LU relative gates).
    static func integratedLUFS(subBlockEnergies e: [Double]) -> Double? {
        guard e.count >= 4 else { return nil }
        var blocks: [Double] = []
        blocks.reserveCapacity(e.count)
        for i in 0...(e.count - 4) {
            blocks.append((e[i] + e[i + 1] + e[i + 2] + e[i + 3]) / 4)
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10 * log10(max(z, 1e-20)) }
        let absGated = blocks.filter { lufs($0) > -70 }
        guard !absGated.isEmpty else { return nil }
        let relGate = lufs(absGated.reduce(0, +) / Double(absGated.count)) - 10
        let gated = absGated.filter { lufs($0) > relGate }
        guard !gated.isEmpty else { return nil }
        return lufs(gated.reduce(0, +) / Double(gated.count))
    }
}

nonisolated enum DynamicRangeMath {
    nonisolated struct Block {
        let rmsLeft: Double, rmsRight: Double
        let peakLeft: Double, peakRight: Double
    }

    /// DR score: per channel, second-highest block peak over the RMS of the
    /// loudest 20 % of 3 s blocks, in dB; averaged over channels.
    static func score(blocks: [Block]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        func channelDR(rms: [Double], peaks: [Double]) -> Double? {
            let sortedRMS = rms.sorted(by: >)
            let top = max(1, Int(Double(sortedRMS.count) * 0.2))
            let meanSq = sortedRMS.prefix(top).reduce(0) { $0 + $1 * $1 } / Double(top)
            let rmsTop = meanSq.squareRoot()
            let sortedPeaks = peaks.sorted(by: >)
            let pk = sortedPeaks.count > 1 ? sortedPeaks[1] : sortedPeaks[0]
            guard rmsTop > 0, pk > 0 else { return nil }
            return 20 * log10(pk / rmsTop)
        }
        let values = [
            channelDR(rms: blocks.map(\.rmsLeft), peaks: blocks.map(\.peakLeft)),
            channelDR(rms: blocks.map(\.rmsRight), peaks: blocks.map(\.peakRight)),
        ].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return Int((values.reduce(0, +) / Double(values.count)).rounded())
    }
}

// MARK: - Spectrum

/// Averages windowed power spectra of a mono mix over many frames.
nonisolated final class SpectrumAccumulator {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup?
    private var window: [Float]
    private var frame: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var mags: [Float]
    private var sum: [Double]
    private var frames = 0

    init(log2n: vDSP_Length) {
        self.log2n = log2n
        size = 1 << Int(log2n)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        var w = [Float](repeating: 0, count: size)
        vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        window = w
        frame = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        mags = [Float](repeating: 0, count: size / 2)
        sum = [Double](repeating: 0, count: size / 2)
    }

    deinit {
        if let setup { vDSP_destroy_fftsetup(setup) }
    }

    func add(left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) {
        guard let setup, count >= size else { return }
        let half = size / 2
        for i in 0..<size {
            frame[i] = (left[i] + right[i]) * 0.5 * window[i]
        }
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                mags.withUnsafeMutableBufferPointer { mp in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, mp.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }
        // Bin 0 packs DC and Nyquist; drop it.
        mags[0] = 0
        for i in 0..<half { sum[i] += Double(mags[i]) }
        frames += 1
    }

    /// Mean power per bin in dB, or nil if nothing was added.
    func averagedPowerDB() -> [Double]? {
        guard frames > 0 else { return nil }
        let n = Double(frames)
        return sum.map { 10 * log10($0 / n + 1e-20) }
    }
}

nonisolated enum SpectrumMath {
    /// Highest frequency carrying content, and whether it ends in a cliff.
    static func cutoff(powerDB p: [Double], sampleRate: Double, fftSize: Int) -> (hz: Double, sharp: Bool)? {
        let binHz = sampleRate / Double(fftSize)
        let n = p.count
        guard n > 16 else { return nil }
        // Smooth over ~±150 Hz.
        let k = max(1, Int((150 / binHz).rounded(.up)))
        var smooth = [Double](repeating: 0, count: n)
        var running = 0.0
        var window = 0
        var lo = 0, hi = -1
        for i in 0..<n {
            while hi < min(n - 1, i + k) { hi += 1; running += p[hi]; window += 1 }
            while lo < max(0, i - k) { running -= p[lo]; lo += 1; window -= 1 }
            smooth[i] = running / Double(max(window, 1))
        }
        let startBin = max(1, Int(2_000 / binHz))
        let endBin = min(n - 1, Int(Double(n) * 0.985))
        guard endBin > startBin + 8 else { return nil }
        let region = smooth[startBin...endBin]
        guard let floor = region.min(), let top = region.max(), top - floor > 15 else {
            return (sampleRate / 2, false)
        }
        let threshold = floor + 12
        var cutBin = endBin
        while cutBin > startBin, smooth[cutBin] <= threshold { cutBin -= 1 }
        let hz = Double(cutBin) * binHz

        // Sharpness: mean level in the 1 kHz below vs. 300–1300 Hz above.
        let below0 = max(startBin, cutBin - Int(1_000 / binHz)), below1 = cutBin
        let above0 = min(n - 1, cutBin + Int(300 / binHz)), above1 = min(n - 1, cutBin + Int(1_300 / binHz))
        var sharp = false
        if above1 > above0, below1 > below0 {
            let belowMean = smooth[below0..<below1].reduce(0, +) / Double(below1 - below0)
            let aboveMean = smooth[above0..<above1].reduce(0, +) / Double(above1 - above0)
            sharp = belowMean - aboveMean >= 20
        }
        return (hz, sharp)
    }

    static func centroid(powerDB p: [Double], sampleRate: Double, fftSize: Int) -> Double {
        let binHz = sampleRate / Double(fftSize)
        var num = 0.0, den = 0.0
        for i in 1..<p.count {
            let f = Double(i) * binHz
            if f > 16_000 { break }
            let w = pow(10, p[i] / 10)
            num += f * w; den += w
        }
        return den > 0 ? num / den : 0
    }

    static func bassRatio(powerDB p: [Double], sampleRate: Double, fftSize: Int) -> Double {
        let binHz = sampleRate / Double(fftSize)
        var bass = 0.0, total = 0.0
        for i in 1..<p.count {
            let w = pow(10, p[i] / 10)
            total += w
            if Double(i) * binHz < 150 { bass += w }
        }
        return total > 0 ? bass / total : 0
    }
}

// MARK: - Tempo

nonisolated enum TempoMath {
    /// Autocorrelation of the onset-strength envelope over 70–180 BPM.
    static func estimate(envelope e: [Float], envelopeRate rate: Double) -> (bpm: Double, clarity: Double)? {
        guard e.count > 64, rate > 0 else { return nil }
        // Onset strength: half-wave rectified log-energy difference.
        var onset = [Double](repeating: 0, count: e.count)
        for i in 1..<e.count {
            let d = log(Double(e[i]) + 1e-9) - log(Double(e[i - 1]) + 1e-9)
            onset[i] = max(0, d)
        }
        let mean = onset.reduce(0, +) / Double(onset.count)
        for i in 0..<onset.count { onset[i] -= mean }

        func ac(_ lag: Int) -> Double {
            var s = 0.0
            for i in lag..<onset.count { s += onset[i] * onset[i - lag] }
            return s
        }
        let ac0 = ac(0)
        guard ac0 > 0 else { return nil }
        let minLag = max(1, Int((60 * rate / 180).rounded(.down)))
        let maxLag = min(onset.count / 2, Int((60 * rate / 70).rounded(.up)))
        guard maxLag > minLag + 1 else { return nil }
        var values = [Double](repeating: 0, count: maxLag + 2)
        var best = minLag
        for lag in minLag...(maxLag + 1) {
            values[lag] = ac(lag)
            if lag <= maxLag, values[lag] > values[best] { best = lag }
        }
        // Parabolic refinement around the peak.
        var refined = Double(best)
        if best > minLag, best < maxLag {
            let y0 = values[best - 1], y1 = values[best], y2 = values[best + 1]
            let denom = y0 - 2 * y1 + y2
            if denom != 0 { refined += 0.5 * (y0 - y2) / denom }
        }
        guard refined > 0 else { return nil }
        let clarity = max(0, min(1, values[best] / ac0))
        return (60 * rate / refined, clarity)
    }
}

// MARK: - Biquad (shared with the DSP stage)

nonisolated enum Biquad {
    nonisolated struct Coefficients: Equatable {
        var b0: Double, b1: Double, b2: Double, a1: Double, a2: Double

        static let identity = Coefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

        /// Transposed direct form II.
        @inline(__always)
        func process(_ x: Double, state s: inout State) -> Double {
            let y = b0 * x + s.z1
            s.z1 = b1 * x - a1 * y + s.z2
            s.z2 = b2 * x - a2 * y
            return y
        }

        /// Magnitude response in dB at `f`.
        func magnitudeDB(at f: Double, sampleRate fs: Double) -> Double {
            let w = 2 * Double.pi * f / fs
            let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
            let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
            let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
            let num = nr * nr + ni * ni, den = dr * dr + di * di
            guard den > 0, num > 0 else { return -120 }
            return 10 * log10(num / den)
        }
    }

    nonisolated struct State { var z1 = 0.0, z2 = 0.0 }

    nonisolated enum Kind: String, Codable { case lowShelf, highShelf, peak }

    /// RBJ cookbook designs.
    static func design(_ kind: Kind, frequency f: Double, gainDB: Double, q: Double,
                       sampleRate fs: Double) -> Coefficients {
        guard fs > 0, f > 0, f < fs / 2 else { return .identity }
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * f / fs
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * max(q, 0.05))
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case .peak:
            b0 = 1 + alpha * a; b1 = -2 * cw; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cw; a2 = 1 - alpha / a
        case .lowShelf:
            let sq = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cw + sq)
            b1 = 2 * a * ((a - 1) - (a + 1) * cw)
            b2 = a * ((a + 1) - (a - 1) * cw - sq)
            a0 = (a + 1) + (a - 1) * cw + sq
            a1 = -2 * ((a - 1) + (a + 1) * cw)
            a2 = (a + 1) + (a - 1) * cw - sq
        case .highShelf:
            let sq = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cw + sq)
            b1 = -2 * a * ((a - 1) + (a + 1) * cw)
            b2 = a * ((a + 1) + (a - 1) * cw - sq)
            a0 = (a + 1) - (a - 1) * cw + sq
            a1 = 2 * ((a - 1) - (a + 1) * cw)
            a2 = (a + 1) - (a - 1) * cw - sq
        }
        return Coefficients(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}
