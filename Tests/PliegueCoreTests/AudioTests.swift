import AVFoundation
import Foundation
@testable import PliegueCore
import XCTest

final class AudioTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try FileUtilities.makeWorkspace() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func source(floatingPoint: Bool = false) throws -> InputFile {
        let url = folder.appendingPathComponent("sound.wav")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200))
        buffer.frameLength = 88_200
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<Int(buffer.frameLength) {
            channels[0][index] = Float((index % 100) - 50) / 128
            channels[1][index] = Float((index % 80) - 40) / 128
        }
        do {
            let output = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                        AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: floatingPoint ? 32 : 16,
                                        AVLinearPCMIsFloatKey: floatingPoint, AVLinearPCMIsBigEndianKey: false,
                                        AVLinearPCMIsNonInterleaved: false], commonFormat: .pcmFormatFloat32, interleaved: false)
            try output.write(from: buffer)
        }
        return try InputFile(url: url)
    }

    func testLosslessALACReducesPCMAndVerifiesEveryChannel() throws {
        try XCTSkipUnless(AudioCompressor.encoderIsAvailable(for: .lossless), "Core Audio does not expose the ALAC encoder in this process. The independent system afconvert control reports it unavailable too.")
        let input = try source()
        let original = try Data(contentsOf: input.url)
        let result = try AudioCompressor().compress(input, fidelity: .lossless, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        XCTAssertEqual(result.url.pathExtension, "m4a")
        XCTAssertTrue(result.verification.contains("SHA-256"))
        let output = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(output.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertEqual(output.length, 88_200)
        XCTAssertEqual(try Data(contentsOf: input.url), original)
    }

    func testHighQualityAACPreservesRateAndChannels() throws {
        try XCTSkipUnless(AudioCompressor.encoderIsAvailable(for: .highQuality), "Core Audio does not expose the AAC encoder in this process.")
        let input = try source()
        let result = try AudioCompressor().compress(input, fidelity: .highQuality, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        let output = try AVAudioFile(forReading: result.url)
        XCTAssertEqual(output.processingFormat.sampleRate, 44_100)
        XCTAssertEqual(output.processingFormat.channelCount, 2)
        XCTAssertLessThanOrEqual(abs(output.length - 88_200), 2048)
    }

    func testFloatingPointSourceIsNotPresentedAsLosslessALAC() throws {
        let input = try source(floatingPoint: true)
        XCTAssertThrowsError(try AudioCompressor().compress(input, fidelity: .lossless, quality: .balanced, cancellation: CancellationToken()))
    }

    func testAudioCancellationPreservesSource() throws {
        let input = try source()
        let original = try Data(contentsOf: input.url)
        let token = CancellationToken()
        XCTAssertThrowsError(try AudioCompressor().compress(input, fidelity: .lossless, quality: .balanced, cancellation: token) { _ in token.cancel() })
        XCTAssertEqual(try Data(contentsOf: input.url), original)
    }

    func testUnavailableEncoderIsReportedWithoutChangingSource() throws {
        try XCTSkipIf(AudioCompressor.encoderIsAvailable(for: .lossless), "This environment has ALAC; the encoding integration test covers it.")
        let input = try source()
        let original = try Data(contentsOf: input.url)
        XCTAssertThrowsError(try AudioCompressor().compress(input, fidelity: .lossless, quality: .balanced, cancellation: CancellationToken())) { error in
            XCTAssertTrue(error.localizedDescription.contains("encoder"))
        }
        XCTAssertEqual(try Data(contentsOf: input.url), original)
    }
}
