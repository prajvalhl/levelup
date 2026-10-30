import Foundation

public enum DSPError: Error, Equatable {
    case invalidSampleRate
    case unsupportedChannelCount(Int)
    case invalidThreshold
    case invalidRatio
    case invalidAttack
    case invalidRelease
    case invalidMakeupGain
    case invalidLimiterCeiling
}

public struct CompressorParameters: Equatable, Sendable {
    public let thresholdDBFS: Float
    public let ratio: Float
    public let attackMilliseconds: Float
    public let releaseMilliseconds: Float
    public let makeupGainDB: Float

    public init(thresholdDBFS: Float, ratio: Float, attackMilliseconds: Float,
                releaseMilliseconds: Float, makeupGainDB: Float) {
        self.thresholdDBFS = thresholdDBFS
        self.ratio = ratio
        self.attackMilliseconds = attackMilliseconds
        self.releaseMilliseconds = releaseMilliseconds
        self.makeupGainDB = makeupGainDB
    }
}

public struct LimiterParameters: Equatable, Sendable {
    public let ceilingDBFS: Float
    public let releaseMilliseconds: Float

    public init(ceilingDBFS: Float, releaseMilliseconds: Float = 80) {
        self.ceilingDBFS = ceilingDBFS
        self.releaseMilliseconds = releaseMilliseconds
    }
}

public enum DSPPreset: String, CaseIterable, Sendable {
    case gentle
    case balanced
    case strong

    public var compressor: CompressorParameters {
        switch self {
        case .gentle:
            return CompressorParameters(thresholdDBFS: -18, ratio: 1.5, attackMilliseconds: 30,
                                        releaseMilliseconds: 180, makeupGainDB: 2)
        case .balanced:
            return CompressorParameters(thresholdDBFS: -24, ratio: 4, attackMilliseconds: 12,
                                        releaseMilliseconds: 120, makeupGainDB: 4)
        case .strong:
            return CompressorParameters(thresholdDBFS: -30, ratio: 6, attackMilliseconds: 5,
                                        releaseMilliseconds: 80, makeupGainDB: 6)
        }
    }

    public var limiter: LimiterParameters { LimiterParameters(ceilingDBFS: -1, releaseMilliseconds: 80) }
}

public enum DSPMode: Equatable, Sendable {
    case bypass
    case preset(DSPPreset)
    case custom(compressor: CompressorParameters, limiter: LimiterParameters)

    public init?(argument: String) {
        switch argument.lowercased() {
        case "bypass": self = .bypass
        case "gentle": self = .preset(.gentle)
        case "balanced": self = .preset(.balanced)
        case "strong": self = .preset(.strong)
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .bypass: return "bypass"
        case let .preset(preset): return preset.rawValue
        case .custom: return "custom"
        }
    }
}

/// Stateful, allocation-free interleaved Float32 compressor and peak limiter.
/// Construct and configure before entering an audio callback. Calls to `process`
/// mutate only preallocated scalar state and the caller-owned audio buffers.
public struct DSPProcessor: Sendable {
    public let sampleRate: Double
    public let channelCount: Int
    public let mode: DSPMode

    private let compressor: CompressorParameters?
    private let envelopeAttackCoefficient: Float
    private let envelopeReleaseCoefficient: Float
    private let gainAttackCoefficient: Float
    private let gainReleaseCoefficient: Float
    private let limiterReleaseCoefficient: Float
    private let makeupGain: Float
    private let limiterCeiling: Float

    private var detectorEnvelope: Float = 0
    private var gainReductionDB: Float = 0
    private var limiterGain: Float = 1

    public private(set) var currentGainReductionDB: Float = 0
    public private(set) var currentLimiterGain: Float = 1

    public init(mode: DSPMode, sampleRate: Double, channelCount: Int) throws {
        guard sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 384_000 else {
            throw DSPError.invalidSampleRate
        }
        guard (1...2).contains(channelCount) else { throw DSPError.unsupportedChannelCount(channelCount) }

        let compressorParameters: CompressorParameters?
        let limiterParameters: LimiterParameters?
        switch mode {
        case .bypass:
            compressorParameters = nil
            limiterParameters = nil
        case let .preset(preset):
            compressorParameters = preset.compressor
            limiterParameters = preset.limiter
        case let .custom(comp, limit):
            compressorParameters = comp
            limiterParameters = limit
        }

        if let comp = compressorParameters {
            guard comp.thresholdDBFS.isFinite, (-60...0).contains(comp.thresholdDBFS) else { throw DSPError.invalidThreshold }
            guard comp.ratio.isFinite, (1...20).contains(comp.ratio) else { throw DSPError.invalidRatio }
            guard comp.attackMilliseconds.isFinite, (0.1...2_000).contains(comp.attackMilliseconds) else { throw DSPError.invalidAttack }
            guard comp.releaseMilliseconds.isFinite, (1...5_000).contains(comp.releaseMilliseconds) else { throw DSPError.invalidRelease }
            guard comp.makeupGainDB.isFinite, (0...24).contains(comp.makeupGainDB) else { throw DSPError.invalidMakeupGain }
        }
        if let limit = limiterParameters {
            guard limit.ceilingDBFS.isFinite, (-12...0).contains(limit.ceilingDBFS) else { throw DSPError.invalidLimiterCeiling }
            guard limit.releaseMilliseconds.isFinite, (1...5_000).contains(limit.releaseMilliseconds) else { throw DSPError.invalidRelease }
        }

        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.mode = mode
        compressor = compressorParameters
        if let comp = compressorParameters {
            envelopeAttackCoefficient = Self.coefficient(milliseconds: comp.attackMilliseconds, sampleRate: sampleRate)
            envelopeReleaseCoefficient = Self.coefficient(milliseconds: comp.releaseMilliseconds, sampleRate: sampleRate)
            gainAttackCoefficient = envelopeAttackCoefficient
            gainReleaseCoefficient = envelopeReleaseCoefficient
            makeupGain = Self.amplitude(forDB: comp.makeupGainDB)
        } else {
            envelopeAttackCoefficient = 0
            envelopeReleaseCoefficient = 0
            gainAttackCoefficient = 0
            gainReleaseCoefficient = 0
            makeupGain = 1
        }
        if let limit = limiterParameters {
            limiterReleaseCoefficient = Self.coefficient(milliseconds: limit.releaseMilliseconds, sampleRate: sampleRate)
            limiterCeiling = Self.amplitude(forDB: limit.ceilingDBFS)
        } else {
            limiterReleaseCoefficient = 0
            limiterCeiling = 1
        }
    }

    /// Processes `frameCount` interleaved frames. Buffers must contain at least
    /// `frameCount * channelCount` samples and must not be concurrently reused.
    /// Bypass is an exact sample copy and intentionally does not advance DSP state.
    public mutating func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0, frameCount <= Int.max / channelCount else { return }
        let sampleCount = frameCount * channelCount
        if case .bypass = mode {
            output.update(from: input, count: sampleCount)
            return
        }

        guard let compressor else { return }
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var linkedPeak: Float = 0
            for channel in 0..<channelCount {
                let value = input[base + channel]
                if value.isFinite { linkedPeak = max(linkedPeak, abs(value)) }
            }

            let envelopeCoefficient = linkedPeak > detectorEnvelope ? envelopeAttackCoefficient : envelopeReleaseCoefficient
            detectorEnvelope = linkedPeak + envelopeCoefficient * (detectorEnvelope - linkedPeak)
            let envelopeDB = 20 * log10f(max(detectorEnvelope, 1e-12))
            let overThresholdDB = max(0, envelopeDB - compressor.thresholdDBFS)
            let desiredGainReductionDB = -overThresholdDB * (1 - 1 / compressor.ratio)
            let gainCoefficient = desiredGainReductionDB < gainReductionDB ? gainAttackCoefficient : gainReleaseCoefficient
            gainReductionDB = desiredGainReductionDB + gainCoefficient * (gainReductionDB - desiredGainReductionDB)
            currentGainReductionDB = gainReductionDB

            let compressorGain = Self.amplitude(forDB: gainReductionDB) * makeupGain
            var postCompressorPeak: Float = 0
            for channel in 0..<channelCount {
                let value = input[base + channel].isFinite ? input[base + channel] : 0
                postCompressorPeak = max(postCompressorPeak, abs(value * compressorGain))
            }

            let desiredLimiterGain = postCompressorPeak > limiterCeiling ? limiterCeiling / postCompressorPeak : 1
            if desiredLimiterGain < limiterGain {
                limiterGain = desiredLimiterGain
            } else {
                limiterGain = desiredLimiterGain + limiterReleaseCoefficient * (limiterGain - desiredLimiterGain)
            }
            currentLimiterGain = limiterGain

            for channel in 0..<channelCount {
                let value = input[base + channel].isFinite ? input[base + channel] : 0
                let processed = value * compressorGain * limiterGain
                if processed.isFinite {
                    output[base + channel] = min(limiterCeiling, max(-limiterCeiling, processed))
                } else {
                    output[base + channel] = value.sign == .minus ? -limiterCeiling : limiterCeiling
                }
            }
        }
    }

    private static func coefficient(milliseconds: Float, sampleRate: Double) -> Float {
        expf(-1 / (milliseconds * 0.001 * Float(sampleRate)))
    }

    @inline(__always)
    private static func amplitude(forDB decibels: Float) -> Float {
        exp2f(decibels * 0.16609640474436813) // 10^(dB/20)
    }
}
