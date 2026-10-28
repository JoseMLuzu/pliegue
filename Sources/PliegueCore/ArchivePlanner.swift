import Foundation

struct ArchiveSource {
    let file: InputFile
    let path: String
}

enum ArchivePlanner {
    static func expand(_ inputs: [InputFile], cancellation: CancellationToken) throws -> [ArchiveSource] {
        var sources: [ArchiveSource] = []
        var used = Set<String>()
        for input in inputs {
            try cancellation.check()
            try input.checkUnchanged()
            let rootName = FileUtilities.uniqueArchiveName(input.name, used: &used)
            sources.append(ArchiveSource(file: input, path: rootName + (input.isDirectory ? "/" : "")))
            guard input.isDirectory else { continue }
            var traversalError: Error?
            guard let enumerator = FileManager.default.enumerator(at: input.url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: [], errorHandler: { _, error in
                traversalError = error; return false
            }) else { throw CompressionError.archive("The selected folder could not be read.") }
            for case let url as URL in enumerator {
                try cancellation.check()
                let child = try InputFile(url: url)
                let rootPath = input.url.standardizedFileURL.path + "/"
                guard url.standardizedFileURL.path.hasPrefix(rootPath) else { throw CompressionError.archive("A folder entry points outside the selected folder.") }
                let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
                // Keep internal path components exact so model and texture links survive extraction.
                sources.append(ArchiveSource(file: child, path: rootName + "/" + relative + (child.isDirectory ? "/" : "")))
                guard sources.count <= 10_000 else { throw CompressionError.archive("This selection contains more than 10,000 archive entries.") }
            }
            if let traversalError { throw traversalError }
        }
        guard !sources.isEmpty, sources.count <= 10_000 else { throw CompressionError.archive("Select between 1 and 10,000 archive entries.") }
        return sources
    }
}
