import AVFoundation
import CryptoKit
import Foundation
import VideoToolbox
@testable import PliegueCore
import XCTest

final class VideoTests: XCTestCase {
    func testMarkerOnlyAudioBufferDoesNotChangePayloadHash() throws {
        var marker: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                               formatDescription: nil, sampleCount: 0,
                                               sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                               sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                               sampleBufferOut: &marker)
        XCTAssertEqual(status, noErr)
        let sample = try XCTUnwrap(marker)
        CMSetAttachment(sample, key: kCMSampleBufferAttachmentKey_EmptyMedia,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        let payload = Data("audio payload before an empty-edit marker".utf8)
        var digest = SHA256(); digest.update(data: payload)
        try VideoCompressor.updateAudioHash(&digest, sample: sample)
        XCTAssertEqual(digest.finalize(), SHA256.hash(data: payload))
    }

    func testNonemptyAudioBufferWithoutPayloadIsRejected() throws {
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 44_100),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var size = 2
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                               formatDescription: nil, sampleCount: 1,
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                               sampleBufferOut: &sample)
        XCTAssertEqual(status, noErr)
        let missingPayload = try XCTUnwrap(sample)
        XCTAssertEqual(CMSampleBufferGetNumSamples(missingPayload), 1)
        var digest = SHA256()
        XCTAssertThrowsError(try VideoCompressor.updateAudioHash(&digest, sample: missingPayload))
    }

    private func requireNativeEncoder() throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: 320, height: 180, codecType: kCMVideoCodecType_HEVC,
                                                encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        try XCTSkipIf(status != noErr, "Native HEVC is unavailable in this process (VideoToolbox status \(status)). Run this integration test on a Mac with encoder access.")
    }
    private func fixture(_ name: String) throws -> InputFile {
        try InputFile(url: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures")))
    }

    func testNativeHEVCProducesSmallerVideoWithMatchingResolutionAndAudio() async throws {
        try requireNativeEncoder()
        let input = try fixture("source")
        let originalDigest = SHA256.hash(data: try Data(contentsOf: input.url))
        let result = try await VideoCompressor().compress(input, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        XCTAssertLessThan(result.outputSize, input.size)
        XCTAssertEqual(result.url.pathExtension, "mp4")
        XCTAssertTrue(result.verification.contains("Audio SHA-256"))
        let outputAsset = AVURLAsset(url: result.url)
        let sourceAsset = AVURLAsset(url: input.url)
        let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .video)
        let outputTracks = try await outputAsset.loadTracks(withMediaType: .video)
        let sourceTrack = try XCTUnwrap(sourceTracks.first)
        let outputTrack = try XCTUnwrap(outputTracks.first)
        let sourceSize = try await sourceTrack.load(.naturalSize)
        let outputSize = try await outputTrack.load(.naturalSize)
        XCTAssertEqual(sourceSize, outputSize)
        let formats = try await outputTrack.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_HEVC)
        let audio = try await outputAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: input.url)), originalDigest)
    }

    func testPortraitOrientationIsPreserved() async throws {
        try requireNativeEncoder()
        let input = try fixture("portrait")
        let result = try await VideoCompressor().compress(input, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        let sourceTracks = try await AVURLAsset(url: input.url).loadTracks(withMediaType: .video)
        let outputTracks = try await AVURLAsset(url: result.url).loadTracks(withMediaType: .video)
        let sourceTransform = try await XCTUnwrap(sourceTracks.first).load(.preferredTransform)
        let outputTransform = try await XCTUnwrap(outputTracks.first).load(.preferredTransform)
        XCTAssertNotEqual(sourceTransform, .identity)
        XCTAssertEqual(sourceTransform, outputTransform)
    }

    func testTinyVideoIsSmallerOrRetainsOriginalWithoutLargerOutput() async throws {
        try requireNativeEncoder()
        let input = try fixture("tiny")
        let result = try await VideoCompressor().compress(input, quality: .detail, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertLessThanOrEqual(result.outputSize, input.size)
        if result.originalRetained {
            XCTAssertEqual(result.url, input.url)
            XCTAssertEqual(result.outputSize, input.size)
            XCTAssertNil(result.workspace)
        } else {
            // Native encoder versions differ; a tiny input can still have real savings.
            XCTAssertTrue(result.hasSavings)
            XCTAssertLessThan(result.outputSize, input.size)
        }
    }

    func testVideoCancellationNeverChangesTheSource() async throws {
        try requireNativeEncoder()
        let input = try fixture("source")
        let digest = SHA256.hash(data: try Data(contentsOf: input.url))
        let token = CancellationToken()
        do {
            let result = try await VideoCompressor().compress(input, quality: .balanced, cancellation: token) { value in
                if value.stage == .compressing { token.cancel() }
            }
            result.discard()
            XCTFail("A cancelled operation must not return a result")
        } catch is CancellationError {
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: input.url)), digest)
        }
    }

    func testMultipleVideosAreRejectedBeforeProcessing() async throws {
        let input = try fixture("source")
        do {
            _ = try await CompressionService.compress(files: [input, input], mode: .video, quality: .balanced, cancellation: CancellationToken())
            XCTFail("Video mode must accept only one video")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("one video"))
        }
    }

    func testQualitySettingsOrderTheTargetBitrates() {
        let smaller = CompressionQuality.smaller.videoBitRate(source: 8_000_000, width: 1920, height: 1080, frameRate: 30)
        let balanced = CompressionQuality.balanced.videoBitRate(source: 8_000_000, width: 1920, height: 1080, frameRate: 30)
        let detail = CompressionQuality.detail.videoBitRate(source: 8_000_000, width: 1920, height: 1080, frameRate: 30)
        XCTAssertLessThan(smaller, balanced)
        XCTAssertLessThan(balanced, detail)
    }
}
