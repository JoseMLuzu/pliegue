@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import VideoToolbox

public struct VideoCompressor: Sendable {
    public init() {}

    private final class Channel {
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let isVideo: Bool
        var finished = false
        var frames = 0
        var digest = SHA256()
        init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, isVideo: Bool) {
            self.output = output; self.input = input; self.isVideo = isVideo
        }
    }

    public func compress(_ file: InputFile, quality: CompressionQuality, cancellation: CancellationToken,
                         progress: ProgressHandler = { _ in }) async throws -> CompressionResult {
        try cancellation.check()
        try file.checkUnchanged()
        guard file.isVideo else { throw CompressionError.video("Select an MP4, MOV, or M4V video. Use ZIP for other file types.") }
        progress(.init(.analyzing, fraction: 0, filename: file.name))
        let asset = AVURLAsset(url: file.url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let allTracks = try await asset.load(.tracks)
        guard videoTracks.count == 1, allTracks.count == videoTracks.count + audioTracks.count else {
            throw CompressionError.video("This video has additional image, subtitle, or metadata tracks. Use lossless ZIP to preserve them.")
        }
        guard let video = videoTracks.first, let format = try await video.load(.formatDescriptions).first else {
            throw CompressionError.video("The video format could not be read.")
        }
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? ""
        let atoms = extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        guard !["SMPTE_ST_2084_PQ", "ITU_R_2100_HLG"].contains(transfer),
              !atoms.keys.contains(where: { ["dvcC", "dvvC", "dvwC"].contains($0) }),
              !extensions.keys.contains(where: { $0.localizedCaseInsensitiveContains("Dolby") }) else {
            throw CompressionError.video("HDR and Dolby Vision are not supported in this version. Use ZIP to preserve the original.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let width = Int(dimensions.width), height = Int(dimensions.height)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw CompressionError.video("This video has unsupported dimensions. Use ZIP to preserve the original.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw CompressionError.video("The video has no readable duration.") }
        let frameRate = Double(try await video.load(.nominalFrameRate))
        let sourceBitRate = Double(try await video.load(.estimatedDataRate))
        let transform = try await video.load(.preferredTransform)
        let workspace = try FileUtilities.makeWorkspace()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: workspace) } }
        var audioFormats: [CMFormatDescription] = []
        var audioTimeRanges: [CMTimeRange] = []
        for track in audioTracks {
            guard let audioFormat = try await track.load(.formatDescriptions).first else {
                throw CompressionError.video("An audio track could not be read.")
            }
            audioFormats.append(audioFormat)
            audioTimeRanges.append(try await track.load(.timeRange))
        }
        let mp4Audio = audioFormats.allSatisfy { [kAudioFormatMPEG4AAC, kAudioFormatMPEGLayer3, kAudioFormatAppleLossless].contains(CMFormatDescriptionGetMediaSubType($0)) }
        let fileType: AVFileType = mp4Audio ? .mp4 : .mov
        let outputURL = workspace.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent + "-smaller." + (mp4Audio ? "mp4" : "mov"))
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        let metadata = try await asset.load(.metadata)
        writer.metadata = metadata
        writer.shouldOptimizeForNetworkUse = true
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.videoBitRate(source: sourceBitRate, width: width, height: height, frameRate: frameRate > 0 ? frameRate : 30),
                AVVideoExpectedSourceFrameRateKey: frameRate > 0 ? frameRate : 30,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
                AVVideoAllowFrameReorderingKey: true,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ],
        ]
        var colors: [String: Any] = [:]
        for (source, destination) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                                      (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                                      (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
            if let value = extensions[source as String] as? String { colors[destination] = value }
        }
        if !colors.isEmpty { settings[AVVideoColorPropertiesKey] = colors }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw CompressionError.video("HEVC encoding is unavailable for this video on this Mac.")
        }
        let videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw CompressionError.video("The video track is not compatible with the encoder.") }
        reader.add(videoOutput); writer.add(videoInput)
        var channels = [Channel(output: videoOutput, input: videoInput, isVideo: true)]
        for (index, track) in audioTracks.enumerated() {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormats[index])
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw CompressionError.video("An audio track cannot be copied into this video container.") }
            reader.add(output); writer.add(input)
            channels.append(Channel(output: output, input: input, isVideo: false))
        }
        defer { if writer.status == .writing { writer.cancelWriting() }; if reader.status == .reading { reader.cancelReading() } }
        guard writer.startWriting() else {
            throw CompressionError.video("macOS could not start its HEVC encoder. Try reopening Pliegue, or use lossless ZIP. \(writer.error?.localizedDescription ?? "Encoding is unavailable in this environment.")")
        }
        guard reader.startReading() else { throw reader.error ?? CompressionError.video("The source video could not be decoded.") }
        writer.startSession(atSourceTime: .zero)
        try pump(channels: channels, reader: reader, writer: writer, duration: duration,
                 filename: file.name, cancellation: cancellation, progress: progress)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        try cancellation.check()
        guard writer.status == .completed else { throw writer.error ?? CompressionError.video("The video could not be finalized.") }
        try file.checkUnchanged()
        progress(.init(.verifying, fraction: 0.8, filename: file.name))
        try await verify(outputURL, width: width, height: height, transform: transform, duration: duration,
                         expectedFrames: channels[0].frames, audioDigests: channels.dropFirst().map { $0.digest.finalize() },
                         audioTimeRanges: audioTimeRanges,
                         cancellation: cancellation, progress: progress)
        try cancellation.check()
        let outputSize = try FileUtilities.size(of: outputURL)
        if outputSize >= file.size {
            return CompressionResult(url: file.url, workspace: nil, originalSize: file.size, outputSize: file.size,
                                     mode: .video, originalRetained: true,
                                     detail: "This setting did not produce a smaller video. The recoded copy was discarded. Try More savings, or keep the original.",
                                     verification: "Original file retained without changes")
        }
        keep = true
        progress(.init(.verifying, fraction: 1, filename: file.name))
        return CompressionResult(url: outputURL, workspace: workspace, originalSize: file.size, outputSize: outputSize,
                                 mode: .video, detail: "\(width) × \(height) · Same resolution and orientation. Video is re-encoded with loss; review it before replacing your original. Some metadata may change.",
                                 verification: audioTracks.isEmpty ? "All video frames decoded and checked" : "All video frames checked · Audio SHA-256 verified")
    }

    private func pump(channels: [Channel], reader: AVAssetReader, writer: AVAssetWriter, duration: Double,
                      filename: String, cancellation: CancellationToken, progress: ProgressHandler) throws {
        var lastActivity = Date()
        var lastReport = Date.distantPast
        while channels.contains(where: { !$0.finished }) {
            try cancellation.check()
            if reader.status == .failed || writer.status == .failed { throw reader.error ?? writer.error ?? CompressionError.video("Video processing failed.") }
            var worked = false
            for channel in channels where !channel.finished && channel.input.isReadyForMoreMediaData {
                try cancellation.check()
                if let sample = channel.output.copyNextSampleBuffer() {
                    // Reader control markers carry no media payload. Track timing is
                    // checked separately before a result is accepted.
                    if CMSampleBufferGetNumSamples(sample) == 0 { worked = true; continue }
                    if channel.isVideo { channel.frames += 1 }
                    else {
                        try Self.updateAudioHash(&channel.digest, sample: sample)
                    }
                    guard channel.input.append(sample) else { throw writer.error ?? CompressionError.video("A media sample could not be encoded.") }
                    if channel.isVideo, Date().timeIntervalSince(lastReport) > 0.1 {
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        progress(.init(.compressing, fraction: min(0.78, max(0, time / duration) * 0.78), filename: filename))
                        lastReport = Date()
                    }
                } else {
                    guard reader.status != .failed else { throw reader.error ?? CompressionError.video("The source video is damaged.") }
                    channel.input.markAsFinished(); channel.finished = true
                }
                worked = true
            }
            if worked { lastActivity = Date() }
            else {
                guard Date().timeIntervalSince(lastActivity) < 60 else { throw CompressionError.video("The video encoder stopped responding.") }
                Thread.sleep(forTimeInterval: 0.003)
            }
        }
    }

    private func verify(_ url: URL, width: Int, height: Int, transform: CGAffineTransform, duration: Double,
                        expectedFrames: Int, audioDigests: [SHA256.Digest], audioTimeRanges: [CMTimeRange], cancellation: CancellationToken,
                        progress: ProgressHandler) async throws {
        let asset = AVURLAsset(url: url)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await video.load(.formatDescriptions).first else {
            throw CompressionError.verification("The output video track is missing.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let outputTransform = try await video.load(.preferredTransform)
        let outputDuration = try await asset.load(.duration).seconds
        let sameTransform = [outputTransform.a - transform.a, outputTransform.b - transform.b, outputTransform.c - transform.c,
                             outputTransform.d - transform.d, outputTransform.tx - transform.tx, outputTransform.ty - transform.ty].allSatisfy { abs($0) < 0.01 }
        guard dimensions.width == width, dimensions.height == height, sameTransform, abs(outputDuration - duration) < 0.2 else {
            throw CompressionError.verification("The output resolution, orientation, or duration changed unexpectedly. The result was discarded.")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        guard reader.canAdd(output) else { throw CompressionError.verification("The output video could not be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CompressionError.verification("Output verification could not start.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        try verifyFrames(output: output, reader: reader, expected: expectedFrames, duration: duration,
                         cancellation: cancellation, progress: progress)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard audio.count == audioDigests.count else { throw CompressionError.verification("The number of audio tracks changed.") }
        for (index, track) in audio.enumerated() {
            try cancellation.check()
            let timeRange = try await track.load(.timeRange)
            guard abs(timeRange.start.seconds - audioTimeRanges[index].start.seconds) < 0.005,
                  abs(timeRange.duration.seconds - audioTimeRanges[index].duration.seconds) < 0.005 else {
                throw CompressionError.verification("The audio timing changed during compression. The result was discarded. Use ZIP to preserve this video.")
            }
            let audioReader = try AVAssetReader(asset: asset)
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard audioReader.canAdd(audioOutput) else { throw CompressionError.verification("The output audio could not be read.") }
            audioReader.add(audioOutput)
            guard audioReader.startReading() else { throw audioReader.error ?? CompressionError.verification("Audio verification could not start.") }
            var hash = SHA256()
            while let sample = audioOutput.copyNextSampleBuffer() {
                try cancellation.check(); try Self.updateAudioHash(&hash, sample: sample)
            }
            guard audioReader.status == .completed, hash.finalize() == audioDigests[index] else {
                throw CompressionError.verification("An audio track no longer matches the source. The result was discarded.")
            }
        }
    }

    private func verifyFrames(output: AVAssetReaderTrackOutput, reader: AVAssetReader, expected: Int, duration: Double,
                              cancellation: CancellationToken, progress: ProgressHandler) throws {
        var frames = 0
        var lastReport = Date.distantPast
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) == 0 { continue }
            try cancellation.check(); frames += 1
            if Date().timeIntervalSince(lastReport) > 0.15 {
                progress(.init(.verifying, fraction: 0.8 + min(1, max(0, CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration)) * 0.18))
                lastReport = Date()
            }
        }
        try cancellation.check()
        guard reader.status == .completed, frames == expected, frames > 0 else {
            throw CompressionError.verification("Not all video frames could be decoded. The result was discarded.")
        }
    }

    static func updateAudioHash(_ digest: inout SHA256, sample: CMSampleBuffer) throws {
        // Passthrough readers can emit marker-only buffers for empty edits or track endings.
        // They contain no audio payload to hash.
        if CMSampleBufferGetNumSamples(sample) == 0 { return }
        guard let block = CMSampleBufferGetDataBuffer(sample) else {
            throw CompressionError.verification("An audio sample could not be verified (\(CMSampleBufferGetNumSamples(sample)) samples, \(CMSampleBufferGetTotalSampleSize(sample)) bytes).")
        }
        let count = CMBlockBufferGetDataLength(block)
        if count == 0 { return }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
        guard status == kCMBlockBufferNoErr else { throw CompressionError.verification("An audio sample could not be verified.") }
        digest.update(data: data)
    }
}
