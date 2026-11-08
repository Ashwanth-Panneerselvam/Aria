import AVFoundation
import AudioToolbox
import Foundation
import os

/// What the post-EQ stage should do. Built on the UI thread from
/// `SoundProcessingSettings`; sample-rate–independent (coefficients are
/// derived on the render thread once the stream's rate is known).
struct DAPConfig: Equatable {
    struct Filter: Equatable {
        var kind: Biquad.Kind
        var frequency: Double
        var gainDB: Double
        var q: Double
    }

    /// bs2b-style crossfeed: low-passed opposite channel mixed in.
    struct Crossfeed: Equatable {
        var cutoffHz: Double
        /// bs2b "feed level" in dB — higher = *less* crossfeed.
        var feedDB: Double
    }

    var preGainDB: Double = 0
    var filters: [Filter] = []
    var crossfeed: Crossfeed?

    var isActive: Bool { !filters.isEmpty || crossfeed != nil || preGainDB != 0 }

    static let off = DAPConfig()
}

/// Real-time stage that runs inside `AudioEQTap` after the 10-band EQ:
/// headroom gain → up to 12 biquads (personal tuning / hearing profile) →
/// crossfeed. Works in place on the tap's Float32 non-interleaved buffers.
///
/// Threading: `update` is called from the UI thread and only writes a
/// pending config under a lock. The render thread picks it up with a
/// non-blocking try-lock at the top of `process` (skipping the update for
/// one buffer if contended), so the render path never waits and never
/// allocates — filter storage is preallocated.
final class DAPProcessor {
    static let maxFilters = 12

    private struct Pending {
        var config = DAPConfig.off
        var dirty = true
    }

    private let pending = OSAllocatedUnfairLock(uncheckedState: Pending())

    // Render-thread state.
    private var sampleRate: Double = 0
    private var channelCount = 0
    private var formatUsable = false
    private var active = false
    private var filterCount = 0
    private var preGain: Float = 1
    private let coefficients: UnsafeMutablePointer<Biquad.Coefficients>
    private let stateL: UnsafeMutablePointer<Biquad.State>
    private let stateR: UnsafeMutablePointer<Biquad.State>
    private var crossfeedOn = false
    private var cf = CrossfeedCoefficients()
    private var cfState = CrossfeedState()

    init() {
        coefficients = .allocate(capacity: Self.maxFilters)
        coefficients.initialize(repeating: .identity, count: Self.maxFilters)
        stateL = .allocate(capacity: Self.maxFilters)
        stateL.initialize(repeating: Biquad.State(), count: Self.maxFilters)
        stateR = .allocate(capacity: Self.maxFilters)
        stateR.initialize(repeating: Biquad.State(), count: Self.maxFilters)
    }

    deinit {
        coefficients.deallocate()
        stateL.deallocate()
        stateR.deallocate()
    }

    // MARK: - Control (UI thread)

    func update(_ config: DAPConfig) {
        pending.withLockUnchecked { (state: inout Pending) in
            state.config = config
            state.dirty = true
        }
    }

    // MARK: - Lifecycle (tap prepare)

    func prepare(format: AudioStreamBasicDescription) {
        let flags = format.mFormatFlags
        formatUsable = format.mFormatID == kAudioFormatLinearPCM
            && (flags & kAudioFormatFlagIsFloat) != 0
            && (flags & kAudioFormatFlagIsNonInterleaved) != 0
            && format.mBitsPerChannel == 32
            && format.mChannelsPerFrame >= 1
        sampleRate = format.mSampleRate
        channelCount = Int(format.mChannelsPerFrame)
        resetFilterState()
        // Coefficients depend on the rate: recompute on the next buffer.
        pending.withLockUnchecked { (state: inout Pending) in state.dirty = true }
    }

    // MARK: - Render

    func process(_ bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard formatUsable, frames > 0 else { return }
        applyPendingIfAvailable()
        guard active else { return }

        let list = UnsafeMutableAudioBufferListPointer(bufferList)
        guard list.count >= 1,
              let lRaw = list[0].mData else { return }
        let left = lRaw.assumingMemoryBound(to: Float.self)
        let n = min(frames, Int(list[0].mDataByteSize) / MemoryLayout<Float>.size)
        var right: UnsafeMutablePointer<Float>?
        if channelCount >= 2, list.count >= 2, let rRaw = list[1].mData {
            right = rRaw.assumingMemoryBound(to: Float.self)
        }

        let g = Double(preGain)
        let count = filterCount
        let c = coefficients
        for i in 0..<n {
            var l = Double(left[i]) * g
            for f in 0..<count { l = c[f].process(l, state: &stateL[f]) }
            if let right {
                var r = Double(right[i]) * g
                for f in 0..<count { r = c[f].process(r, state: &stateR[f]) }
                if crossfeedOn {
                    let out = crossfeed(l, r)
                    l = out.0
                    r = out.1
                }
                right[i] = Float(r)
            }
            left[i] = Float(l)
        }
    }

    // MARK: - Internals

    private func applyPendingIfAvailable() {
        _ = pending.withLockIfAvailableUnchecked { (state: inout Pending) -> Bool in
            guard state.dirty else { return false }
            state.dirty = false
            load(state.config)
            return true
        }
    }

    /// Render thread, under the lock. Math only — no allocation.
    private func load(_ config: DAPConfig) {
        let wasActive = active
        let fs = sampleRate > 0 ? sampleRate : 48_000
        var count = 0
        for spec in config.filters where count < Self.maxFilters {
            coefficients[count] = Biquad.design(spec.kind, frequency: spec.frequency,
                                                gainDB: spec.gainDB, q: spec.q, sampleRate: fs)
            count += 1
        }
        if count < filterCount {
            // Removed filters: clear their history so a later re-add starts clean.
            for i in count..<filterCount {
                stateL[i] = Biquad.State()
                stateR[i] = Biquad.State()
            }
        }
        filterCount = count
        preGain = Float(pow(10, min(0, config.preGainDB) / 20))
        if let x = config.crossfeed {
            if !crossfeedOn { cfState = CrossfeedState() }
            cf = Self.crossfeedCoefficients(cutoffHz: x.cutoffHz, feedDB: x.feedDB, sampleRate: fs)
            crossfeedOn = true
        } else {
            crossfeedOn = false
        }
        active = config.isActive
        if active && !wasActive { resetFilterState() }
    }

    private func resetFilterState() {
        for i in 0..<Self.maxFilters {
            stateL[i] = Biquad.State()
            stateR[i] = Biquad.State()
        }
        cfState = CrossfeedState()
    }

    @inline(__always)
    private func crossfeed(_ l: Double, _ r: Double) -> (Double, Double) {
        cfState.loL = cf.a0Lo * l + cf.b1Lo * cfState.loL
        cfState.loR = cf.a0Lo * r + cf.b1Lo * cfState.loR
        cfState.hiL = cf.a0Hi * l + cf.a1Hi * cfState.asisL + cf.b1Hi * cfState.hiL
        cfState.hiR = cf.a0Hi * r + cf.a1Hi * cfState.asisR + cf.b1Hi * cfState.hiR
        cfState.asisL = l
        cfState.asisR = r
        return ((cfState.hiL + cfState.loR) * cf.gain,
                (cfState.hiR + cfState.loL) * cf.gain)
    }

    struct CrossfeedCoefficients: Equatable {
        var a0Lo = 0.0, b1Lo = 0.0, a0Hi = 1.0, a1Hi = 0.0, b1Hi = 0.0, gain = 1.0
    }

    struct CrossfeedState {
        var loL = 0.0, loR = 0.0, hiL = 0.0, hiR = 0.0, asisL = 0.0, asisR = 0.0
    }

    /// Bauer stereophonic-to-binaural (bs2b) filter design.
    static func crossfeedCoefficients(cutoffHz fcut: Double, feedDB level: Double,
                                      sampleRate fs: Double) -> CrossfeedCoefficients {
        let gbLo = level * -5.0 / 6.0 - 3.0
        let gbHi = level / 6.0 - 3.0
        let gLo = pow(10, gbLo / 20)
        let gHi = 1.0 - pow(10, gbHi / 20)
        let fcHi = fcut * pow(2.0, (gbLo - 20 * log10(gHi)) / 12.0)
        var c = CrossfeedCoefficients()
        var x = exp(-2 * Double.pi * fcut / fs)
        c.b1Lo = x
        c.a0Lo = gLo * (1 - x)
        x = exp(-2 * Double.pi * fcHi / fs)
        c.b1Hi = x
        c.a0Hi = 1 - gHi * (1 - x)
        c.a1Hi = -x
        c.gain = 1 / (1 - gHi + gLo)
        return c
    }
}
