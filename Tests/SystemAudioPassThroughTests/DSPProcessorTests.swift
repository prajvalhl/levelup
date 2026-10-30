import LevelUpDSP
import XCTest

final class DSPProcessorTests: XCTestCase {
    private func makeProcessor(_ compressor: CompressorParameters,
                              limiter: LimiterParameters = LimiterParameters(ceilingDBFS: 0),
                              sampleRate: Double = 48_000,
                              channels: Int = 1) throws -> DSPProcessor {
        try DSPProcessor(mode: .custom(compressor: compressor, limiter: limiter),
                         sampleRate: sampleRate, channelCount: channels)
    }

    private func process(_ processor: inout DSPProcessor, input: [Float]) -> [Float] {
        var output = Array(repeating: Float.zero, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else { return }
                processor.process(input: sourceBase, output: destinationBase,
                                  frameCount: input.count / processor.channelCount)
            }
        }
        return output
    }

    func testBypassIsExactSampleCopy() throws {
        var processor = try DSPProcessor(mode: .bypass, sampleRate: 48_000, channelCount: 2)
        let input: [Float] = [0.25, -0.75, -0.0, 1.25, .nan, .infinity]
        let output = process(&processor, input: input)
        XCTAssertEqual(output.map(\.bitPattern), input.map(\.bitPattern))
    }

    func testSteadyStateCompressionReducesGain() throws {
        var processor = try makeProcessor(CompressorParameters(thresholdDBFS: -20, ratio: 4,
                                                               attackMilliseconds: 3, releaseMilliseconds: 80,
                                                               makeupGainDB: 0))
        let input = Array(repeating: Float(0.8), count: 24_000)
        let output = process(&processor, input: input)
        let tail = output.suffix(4_800)
        let rms = sqrt(tail.reduce(Float.zero) { $0 + $1 * $1 } / Float(tail.count))
        let inputRMS = sqrt(input.suffix(4_800).reduce(Float.zero) { $0 + $1 * $1 } / 4_800)
        let inputDB = 20 * log10f(inputRMS)
        let expectedReduction: Float = -(20 * log10f(0.8) - -20) * (1 - 0.25)
        let measuredOutputDB = 20 * log10f(rms)
        print(String(format: "DSP measurement: steady input=0.800000; gainReduction=%.3f dB; outputRMS=%.6f; outputPeak=%.6f", processor.currentGainReductionDB, rms, output.map(abs).max() ?? 0))
        XCTAssertEqual(processor.currentGainReductionDB, expectedReduction, accuracy: 0.12)
        XCTAssertEqual(measuredOutputDB - inputDB, expectedReduction, accuracy: 0.2)
        XCTAssertEqual(rms, inputRMS * powf(10, expectedReduction / 20), accuracy: 0.002)
    }

    func testAttackAndReleaseSmoothGainReduction() throws {
        var processor = try makeProcessor(CompressorParameters(thresholdDBFS: -20, ratio: 4,
                                                               attackMilliseconds: 5, releaseMilliseconds: 200,
                                                               makeupGainDB: 0))
        let high = Array(repeating: Float(0.8), count: 9_600)
        _ = process(&processor, input: high)
        let steadyReduction = processor.currentGainReductionDB
        XCTAssertLessThan(steadyReduction, -10)

        _ = process(&processor, input: Array(repeating: Float(0.01), count: 480))
        let earlyRelease = processor.currentGainReductionDB
        XCTAssertGreaterThan(earlyRelease, steadyReduction)
        XCTAssertLessThan(earlyRelease, -1)

        _ = process(&processor, input: Array(repeating: Float(0.01), count: 48_000))
        XCTAssertGreaterThan(processor.currentGainReductionDB, -0.5)
    }

    func testStereoLinkedDetectionAppliesEqualGainToBothChannels() throws {
        var processor = try makeProcessor(CompressorParameters(thresholdDBFS: -20, ratio: 4,
                                                               attackMilliseconds: 3, releaseMilliseconds: 100,
                                                               makeupGainDB: 0), channels: 2)
        var input: [Float] = []
        input.reserveCapacity(9_600)
        for _ in 0..<4_800 {
            input.append(0.8)
            input.append(0.2)
        }
        let output = process(&processor, input: input)
        let leftGain = output[output.count - 2] / 0.8
        let rightGain = output[output.count - 1] / 0.2
        XCTAssertLessThan(leftGain, 0.5)
        XCTAssertEqual(leftGain, rightGain, accuracy: 0.00001)
    }

    func testLimiterKeepsOutputBelowConfiguredCeiling() throws {
        var processor = try makeProcessor(CompressorParameters(thresholdDBFS: 0, ratio: 1,
                                                               attackMilliseconds: 10, releaseMilliseconds: 100,
                                                               makeupGainDB: 12),
                                            limiter: LimiterParameters(ceilingDBFS: -1))
        let output = process(&processor, input: Array(repeating: Float(0.8), count: 4_800))
        let ceiling = powf(10, -1 / 20)
        let measuredPeak = output.map(abs).max() ?? 0
        XCTAssertEqual(measuredPeak, ceiling, accuracy: 0.00001)
        XCTAssertLessThan(processor.currentLimiterGain, 1)
        XCTAssertEqual(processor.currentLimiterGain, ceiling / (0.8 * powf(10, 12 / 20)), accuracy: 0.00001)
    }

    func testSilenceRemainsFiniteAndSilent() throws {
        var processor = try DSPProcessor(mode: .preset(.balanced), sampleRate: 48_000, channelCount: 2)
        let output = process(&processor, input: Array(repeating: Float.zero, count: 9_600))
        XCTAssertTrue(output.allSatisfy { $0 == 0 && $0.isFinite })
        XCTAssertTrue(processor.currentGainReductionDB.isFinite)
        XCTAssertTrue(processor.currentLimiterGain.isFinite)
    }

    func testNonFiniteProcessedInputIsSilenced() throws {
        var processor = try DSPProcessor(mode: .preset(.gentle), sampleRate: 48_000, channelCount: 1)
        let output = process(&processor, input: [.nan, .infinity, -.infinity, 0.25])
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertEqual(Array(output.prefix(3)), [0, 0, 0])
    }

    func testExtremeFiniteInputCannotEmitNaNOrExceedLimiterCeiling() throws {
        var processor = try DSPProcessor(mode: .preset(.balanced), sampleRate: 48_000, channelCount: 2)
        let extreme = Float.greatestFiniteMagnitude
        let output = process(&processor, input: [extreme, -extreme, extreme, -extreme])
        let ceiling = powf(10, -1 / 20)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0, ceiling)
    }

    func testInvalidConfigurationAndInputShapesAreRejected() {
        XCTAssertThrowsError(try DSPProcessor(mode: .bypass, sampleRate: .nan, channelCount: 2))
        XCTAssertThrowsError(try DSPProcessor(mode: .bypass, sampleRate: 48_000, channelCount: 3))
        XCTAssertThrowsError(try makeProcessor(CompressorParameters(thresholdDBFS: 1, ratio: 2,
                                                                     attackMilliseconds: 10, releaseMilliseconds: 100,
                                                                     makeupGainDB: 0)))
        XCTAssertThrowsError(try makeProcessor(CompressorParameters(thresholdDBFS: -20, ratio: 0.5,
                                                                     attackMilliseconds: 10, releaseMilliseconds: 100,
                                                                     makeupGainDB: 0)))
        XCTAssertNil(DSPMode(argument: "experimental"))
        XCTAssertEqual(DSPMode(argument: "BALANCED"), .preset(.balanced))
    }

    func testFrameCountOverflowLeavesOutputUntouched() throws {
        var processor = try DSPProcessor(mode: .preset(.balanced), sampleRate: 48_000, channelCount: 2)
        let input: [Float] = [0.1, 0.2]
        var output: [Float] = [0.7, 0.8]
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                processor.process(input: source.baseAddress!, output: destination.baseAddress!, frameCount: Int.max)
            }
        }
        XCTAssertEqual(output, [0.7, 0.8])
    }

    func testPresetsHaveDocumentedStableValues() {
        XCTAssertEqual(DSPPreset.gentle.compressor.thresholdDBFS, -18)
        XCTAssertEqual(DSPPreset.gentle.compressor.ratio, 1.5)
        XCTAssertEqual(DSPPreset.balanced.compressor.thresholdDBFS, -24)
        XCTAssertEqual(DSPPreset.balanced.compressor.ratio, 4)
        XCTAssertEqual(DSPPreset.strong.compressor.thresholdDBFS, -30)
        XCTAssertEqual(DSPPreset.strong.compressor.ratio, 6)
        XCTAssertEqual(DSPPreset.balanced.limiter.ceilingDBFS, -1)
    }

    func testPresetGainReductionAndOutputPeaksNumerically() throws {
        for preset in DSPPreset.allCases {
            var processor = try DSPProcessor(mode: .preset(preset), sampleRate: 48_000, channelCount: 1)
            let output = process(&processor, input: Array(repeating: Float(0.8), count: 24_000))
            let parameters = preset.compressor
            let inputDB = 20 * log10f(0.8)
            let expectedReduction = min(0, -(inputDB - parameters.thresholdDBFS) * (1 - 1 / parameters.ratio))
            let compressedPeak = 0.8 * powf(10, (expectedReduction + parameters.makeupGainDB) / 20)
            let expectedPeak = min(compressedPeak, powf(10, preset.limiter.ceilingDBFS / 20))
            let steadyTailPeak = output.suffix(4_800).map(abs).max() ?? 0
            print(String(format: "DSP preset measurement: %@; gainReduction=%.3f dB; steadyOutputPeak=%.6f; allSamplesPeak=%.6f", preset.rawValue, processor.currentGainReductionDB, steadyTailPeak, output.map(abs).max() ?? 0))
            XCTAssertEqual(processor.currentGainReductionDB, expectedReduction, accuracy: 0.02, "\(preset)")
            XCTAssertEqual(steadyTailPeak, expectedPeak, accuracy: 0.0002, "\(preset)")
            XCTAssertLessThanOrEqual(output.map(abs).max() ?? 0,
                                     powf(10, preset.limiter.ceilingDBFS / 20) + 0.00001,
                                     "\(preset) transient ceiling")
        }
    }

    func testBalancedFourToOneRatioReducesMoreThanPreviousThreeToOneRatio() throws {
        let balanced = DSPPreset.balanced
        XCTAssertEqual(balanced.compressor.ratio, 4)

        let previousCompressor = CompressorParameters(thresholdDBFS: balanced.compressor.thresholdDBFS,
                                                      ratio: 3,
                                                      attackMilliseconds: balanced.compressor.attackMilliseconds,
                                                      releaseMilliseconds: balanced.compressor.releaseMilliseconds,
                                                      makeupGainDB: balanced.compressor.makeupGainDB)
        var balancedProcessor = try DSPProcessor(mode: .preset(.balanced), sampleRate: 48_000, channelCount: 1)
        var previousProcessor = try makeProcessor(previousCompressor, limiter: balanced.limiter)
        let steadySignal = Array(repeating: Float(0.8), count: 24_000)

        _ = process(&balancedProcessor, input: steadySignal)
        _ = process(&previousProcessor, input: steadySignal)

        XCTAssertEqual(balancedProcessor.currentGainReductionDB, -16.546, accuracy: 0.02)
        XCTAssertEqual(previousProcessor.currentGainReductionDB, -14.708, accuracy: 0.02)
        XCTAssertLessThan(balancedProcessor.currentGainReductionDB, previousProcessor.currentGainReductionDB)
    }
}
