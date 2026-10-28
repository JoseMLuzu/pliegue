import Foundation

public enum ResultSaver {
    public static func save(_ result: CompressionResult, to destination: URL, protecting inputs: [URL],
                            cancellation: CancellationToken = CancellationToken(), progress: ProgressHandler = { _ in }) throws {
        try cancellation.check()
        let normalized = destination.resolvingSymlinksInPath().standardizedFileURL
        for source in inputs + [result.url] {
            let sourceURL = source.resolvingSymlinksInPath().standardizedFileURL
            if normalized == sourceURL { throw CompressionError.unsafeDestination }
            if (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let root = sourceURL.path.precomposedStringWithCanonicalMapping.lowercased()
                let target = normalized.path.precomposedStringWithCanonicalMapping.lowercased()
                // Conservatively protect case variants on case-insensitive Mac volumes too.
                if target.hasPrefix(root == "/" ? root : root + "/") { throw CompressionError.unsafeDestination }
            }
            if FileManager.default.fileExists(atPath: normalized.path),
               let destinationID = try normalized.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
               let sourceID = try sourceURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
               destinationID == sourceID { throw CompressionError.unsafeDestination }
        }
        // Stage the complete file on the destination volume before replacing anything.
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedURL = staging.appendingPathComponent("result")
        guard FileManager.default.createFile(atPath: stagedURL.path, contents: nil) else {
            throw CompressionError.archive("The result could not be saved. Check the available disk space.")
        }
        let input = try FileHandle(forReadingFrom: result.url)
        let output = try FileHandle(forWritingTo: stagedURL)
        defer { try? input.close(); try? output.close() }
        var copied: UInt64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try cancellation.check()
            try output.write(contentsOf: chunk)
            copied += UInt64(chunk.count)
            progress(.init(.saving, fraction: result.outputSize > 0 ? Double(copied) / Double(result.outputSize) : 1, filename: destination.lastPathComponent))
        }
        guard copied == result.outputSize else { throw CompressionError.verification("The temporary result changed before saving. Compress the files again.") }
        try output.synchronize()
        try output.close()
        try cancellation.check()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        }
        progress(.init(.saving, fraction: 1, filename: destination.lastPathComponent))
    }
}
