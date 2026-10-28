import CryptoKit
import Foundation

public struct ModelCompressor: Sendable {
    public init() {}

    public func compressGLB(_ file: InputFile, cancellation: CancellationToken,
                            progress: ProgressHandler = { _ in }) throws -> CompressionResult {
        try cancellation.check(); try file.checkUnchanged()
        guard !file.isDirectory, file.url.pathExtension.lowercased() == "glb" else {
            throw CompressionError.model("Select a self-contained GLB, or use ZIP for a model project folder.")
        }
        progress(.init(.analyzing, fraction: 0, filename: file.name))
        let source = try FileHandle(forReadingFrom: file.url)
        defer { try? source.close() }
        let header = try read(source, count: 20)
        guard header.u32(at: 0) == 0x46546c67, header.u32(at: 4) == 2,
              UInt64(header.u32(at: 8)) == file.size, header.u32(at: 16) == 0x4e4f534a else {
            throw CompressionError.model("This is not a valid GLB 2.0 container. Use ZIP to preserve it as-is.")
        }
        let jsonLength = Int(header.u32(at: 12))
        guard jsonLength > 0, jsonLength % 4 == 0, jsonLength <= 32 * 1024 * 1024, UInt64(jsonLength) + 20 <= file.size else {
            throw CompressionError.model("The GLB JSON chunk is invalid or exceeds the 32 MiB optimization limit. Use ZIP instead.")
        }
        let json = try read(source, count: jsonLength)
        let object = try JSONSerialization.jsonObject(with: json)
        guard let dictionary = object as? [String: Any], let asset = dictionary["asset"] as? [String: Any], asset["version"] as? String == "2.0" else {
            throw CompressionError.model("The GLB does not declare glTF 2.0 asset data.")
        }
        guard !containsExternalURI(object) else {
            throw CompressionError.model("This GLB references external files. Choose the entire project folder so linked textures and buffers are included in ZIP.")
        }
        let tailOffset = UInt64(20 + jsonLength)
        var cursor = tailOffset
        var hasBinaryChunk = false
        while cursor < file.size {
            try cancellation.check()
            guard file.size - cursor >= 8 else { throw CompressionError.model("The GLB contains an incomplete chunk header.") }
            try source.seek(toOffset: cursor)
            let chunkHeader = try read(source, count: 8)
            let length = UInt64(chunkHeader.u32(at: 0))
            guard length % 4 == 0, length <= file.size - cursor - 8, chunkHeader.u32(at: 4) != 0x4e4f534a else {
                throw CompressionError.model("The GLB contains an invalid or duplicate JSON chunk.")
            }
            if chunkHeader.u32(at: 4) == 0x004e4942 {
                guard !hasBinaryChunk, cursor == tailOffset else { throw CompressionError.model("The GLB binary chunk must appear once, immediately after JSON.") }
                hasBinaryChunk = true
            }
            cursor += 8 + length
        }
        var compact = minifyJSON(json)
        while compact.count % 4 != 0 { compact.append(0x20) }
        guard compact.count < json.count else {
            try file.checkUnchanged()
            return CompressionResult(url: file.url, workspace: nil, originalSize: file.size, outputSize: file.size,
                                     mode: .model, originalRetained: true, detail: "The GLB JSON is already compact. Geometry and embedded textures were not altered. Use ZIP if you need a compressed container.", verification: "Original model retained without changes")
        }
        let workspace = try FileUtilities.makeWorkspace()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: workspace) } }
        let url = workspace.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent + "-smaller.glb")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CompressionError.model("The optimized model could not be created.") }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let outputSize = file.size - UInt64(json.count) + UInt64(compact.count)
        var newHeader = Data()
        newHeader.le(UInt32(0x46546c67)); newHeader.le(UInt32(2)); newHeader.le(UInt32(outputSize))
        newHeader.le(UInt32(compact.count)); newHeader.le(UInt32(0x4e4f534a))
        try output.write(contentsOf: newHeader); try output.write(contentsOf: compact)
        try source.seek(toOffset: tailOffset)
        var hash = SHA256()
        var copied: UInt64 = 0
        while let data = try source.read(upToCount: 1_048_576), !data.isEmpty {
            try cancellation.check()
            hash.update(data: data); try output.write(contentsOf: data); copied += UInt64(data.count)
            progress(.init(.compressing, fraction: file.size > tailOffset ? Double(copied) / Double(file.size - tailOffset) * 0.8 : 0.8, filename: file.name))
        }
        try output.synchronize()
        progress(.init(.verifying, fraction: 0.8, filename: file.name))
        let check = try FileHandle(forReadingFrom: url)
        defer { try? check.close() }
        let verifiedHeader = try read(check, count: 20)
        guard verifiedHeader == newHeader, try read(check, count: compact.count) == compact,
              minifyJSON(compact) == minifyJSON(json) else { throw CompressionError.verification("The optimized model JSON did not match the source.") }
        var outputHash = SHA256()
        while let data = try check.read(upToCount: 1_048_576), !data.isEmpty {
            try cancellation.check(); outputHash.update(data: data)
        }
        guard outputHash.finalize() == hash.finalize(), try FileUtilities.size(of: url) == outputSize else {
            throw CompressionError.verification("The model's binary chunks changed. The result was discarded.")
        }
        try cancellation.check(); try file.checkUnchanged()
        keep = true
        return CompressionResult(url: url, workspace: workspace, originalSize: file.size, outputSize: outputSize, mode: .model,
                                 detail: "GLB JSON whitespace removed. Numeric values, geometry, animations, and embedded binary chunks were not re-encoded. This does not decimate meshes or shrink embedded textures.",
                                 verification: "JSON tokens and binary chunk SHA-256 verified")
    }

    private func containsExternalURI(_ object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if key == "uri", let uri = value as? String, !uri.hasPrefix("data:"), !uri.hasPrefix("#") { return true }
                if containsExternalURI(value) { return true }
            }
        } else if let array = object as? [Any] { return array.contains(where: containsExternalURI) }
        return false
    }

    private func minifyJSON(_ input: Data) -> Data {
        var output = Data(); output.reserveCapacity(input.count)
        var inString = false, escaped = false
        for byte in input {
            if inString {
                output.append(byte)
                if escaped { escaped = false }
                else if byte == 0x5c { escaped = true }
                else if byte == 0x22 { inString = false }
            } else if byte == 0x22 { inString = true; output.append(byte) }
            else if ![UInt8(0x20), 0x09, 0x0a, 0x0d].contains(byte) { output.append(byte) }
        }
        return output
    }

    private func read(_ file: FileHandle, count: Int) throws -> Data {
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw CompressionError.model("The model file ended unexpectedly.") }
        return data
    }
}

extension Data {
    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
