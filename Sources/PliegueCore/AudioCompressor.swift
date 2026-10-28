import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

public struct AudioCompressor: Sendable {
    private let blockFrames: AVAudioFrameCount = 16_384
    public init() {}

    public static func encoderIsAvailable(for fidelity: MediaFidelity) -> Bool {
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size) == noErr, size > 0 else { return false }
        var formats = [AudioFormatID](repeating: 0, count: Int(size) / MemoryLayout<AudioFormatID>.size)
        let status = formats.withUnsafeMutableBytes { AudioFormatGetProperty(kAudioFormatProperty_EncodeFormatIDs, 0, nil, &size, $0.baseAddress!) }
        let codec = fidelity == .lossless ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC
        return status == noErr && formats.contains(codec)
    }

    public func compress(_ file: InputFile, fidelity: MediaFidelity, quality: CompressionQuality,
                         cancellation: CancellationToken, progress: ProgressHandler = { _ in }) throws -> CompressionResult {
        try cancellation.check(); try file.checkUnchanged()
        guard !file.isDirectory else { throw CompressionError.audio("Select one audio file. Use ZIP for folders.") }
        progress(.init(.analyzing, fraction: 0, filename: file.name))
        try cancellation.check()
        let source: AVAudioFile
        do { source = try AVAudioFile(forReading: file.url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw CompressionError.audio("macOS cannot decode this audio format. Use ZIP to keep the original. \(error.localizedDescription)") }
        let format = source.processingFormat
        let originalFormat = source.fileFormat.streamDescription.pointee
        guard source.length > 0, format.channelCount > 0, format.channelCount <= 8, format.sampleRate > 0 else {
            throw CompressionError.audio("This audio has an unsupported duration, sample rate, or channel layout.")
        }
        let lossless = fidelity == .lossless
        let sourceBits = Int(originalFormat.mBitsPerChannel)
        if lossless {
            let losslessIDs: [AudioFormatID] = [kAudioFormatLinearPCM, kAudioFormatAppleLossless, kAudioFormatFLAC]
            guard losslessIDs.contains(originalFormat.mFormatID), sourceBits <= 24,
                  !(originalFormat.mFormatID == kAudioFormatLinearPCM && originalFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0) else {
                throw CompressionError.audio("Lossless ALAC supports integer PCM up to 24-bit, FLAC, and ALAC. For this source, choose High quality AAC or use ZIP for exact file contents.")
            }
        } else if format.channelCount > 2 {
            throw CompressionError.audio("AAC compression currently supports mono and stereo without downmixing. Use lossless ALAC or ZIP for surround audio.")
        }
        guard Self.encoderIsAvailable(for: fidelity) else {
            throw CompressionError.audio("macOS is not providing the selected audio encoder in this environment. The original is untouched; use ZIP or try Pliegue on a Mac with encoder access.")
        }
        let workspace = try FileUtilities.makeWorkspace()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: workspace) } }
        let url = workspace.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent + (lossless ? "-lossless.m4a" : "-smaller.m4a"))
        var settings: [String: Any] = [AVFormatIDKey: lossless ? kAudioFormatAppleLossless : kAudioFormatMPEG4AAC,
                                       AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount]
        if lossless { settings[AVEncoderBitDepthHintKey] = sourceBits > 0 ? max(16, sourceBits) : 24 }
        else { settings[AVEncoderBitRateKey] = quality.audioBitRate(channels: format.channelCount) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { throw CompressionError.audio("An audio buffer could not be allocated.") }
        var sourceHashes = Array(repeating: SHA256(), count: Int(format.channelCount))
        var frameCount: AVAudioFramePosition = 0
        do {
            let output: AVAudioFile
            do { output = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) }
            catch { throw CompressionError.audio("The requested audio encoder is unavailable. Use ZIP or another setting. \(error.localizedDescription)") }
            while source.framePosition < source.length {
                try cancellation.check()
                try source.read(into: buffer)
                guard buffer.frameLength > 0 else { throw CompressionError.audio("The source audio ended unexpectedly.") }
                if lossless { try hash(buffer, into: &sourceHashes) }
                try output.write(from: buffer)
                frameCount += AVAudioFramePosition(buffer.frameLength)
                progress(.init(.compressing, fraction: Double(frameCount) / Double(source.length) * 0.8, filename: file.name))
            }
        }
        try cancellation.check()
        progress(.init(.verifying, fraction: 0.8, filename: file.name))
        let decoded = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard decoded.processingFormat.channelCount == format.channelCount, decoded.processingFormat.sampleRate == format.sampleRate,
              abs(decoded.length - frameCount) <= (lossless ? 0 : 2048) else {
            throw CompressionError.verification("Audio duration, sample rate, or channels changed unexpectedly. The result was discarded.")
        }
        guard let verifyBuffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: blockFrames) else { throw CompressionError.audio("An audio verification buffer could not be allocated.") }
        var outputHashes = Array(repeating: SHA256(), count: Int(format.channelCount))
        var verified: AVAudioFramePosition = 0
        while decoded.framePosition < decoded.length {
            try cancellation.check()
            try decoded.read(into: verifyBuffer)
            guard verifyBuffer.frameLength > 0 else { throw CompressionError.verification("The output audio ended unexpectedly.") }
            if lossless { try hash(verifyBuffer, into: &outputHashes) }
            verified += AVAudioFramePosition(verifyBuffer.frameLength)
            progress(.init(.verifying, fraction: 0.8 + Double(verified) / Double(decoded.length) * 0.2, filename: file.name))
        }
        if lossless {
            guard sourceHashes.map({ $0.finalize() }) == outputHashes.map({ $0.finalize() }) else {
                throw CompressionError.verification("The audio samples did not match exactly. The result was discarded; use ZIP to preserve this source.")
            }
        }
        try cancellation.check(); try file.checkUnchanged()
        let size = try FileUtilities.size(of: url)
        if size >= file.size {
            return CompressionResult(url: file.url, workspace: nil, originalSize: file.size, outputSize: file.size, mode: .audio, originalRetained: true,
                                     detail: "This audio did not get smaller at the selected setting. The new copy was discarded. Already compressed sources may have little room for savings.", verification: "Original audio retained without changes")
        }
        keep = true
        return CompressionResult(url: url, workspace: workspace, originalSize: file.size, outputSize: size, mode: .audio,
                                 detail: "\(Int(format.sampleRate)) Hz · \(format.channelCount) channels · " + (lossless ? "ALAC preserves decoded samples. File metadata may change; use ZIP for exact file contents." : "AAC re-encoding has loss. Sample rate and channel count are preserved; metadata may change."),
                                 verification: lossless ? "Decoded audio samples SHA-256 verified" : "Full audio decoding, duration, and channels checked")
    }

    private func hash(_ buffer: AVAudioPCMBuffer, into hashes: inout [SHA256]) throws {
        guard let channels = buffer.floatChannelData, !buffer.format.isInterleaved else { throw CompressionError.verification("The audio samples could not be verified.") }
        for channel in hashes.indices {
            let bytes = UnsafeRawBufferPointer(start: channels[channel], count: Int(buffer.frameLength) * MemoryLayout<Float>.size)
            hashes[channel].update(bufferPointer: bytes)
        }
    }
}
