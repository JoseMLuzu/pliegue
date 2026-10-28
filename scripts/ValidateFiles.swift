import CryptoKit
import Darwin
import Foundation

// Build with Sources/PliegueCore/*.swift and -lz; this tool is not bundled in the app.
#if !VALIDATION_APP
@main
#endif
struct ValidateFiles {
    struct Case: Decodable {
        let name: String
        let mode: String
        let fidelity: String?
        let quality: String?
        let files: [String]
    }
    struct Outcome: Codable {
        let name: String
        let mode: String
        let requestedFidelity: String
        let requestedQuality: String
        var status: String
        var originalBytes: UInt64?
        var outputBytes: UInt64?
        var savedPercent: Double?
        var outputPath: String?
        var verification: String?
        var detail: String?
        var error: String?
        var originalsUnchanged: Bool
        var seconds: Double
    }
    struct Report: Codable {
        let createdAt: String
        let operatingSystem: String
        let engine: String
        let executionContext: String
        let results: [Outcome]
    }

    static func main() async {
        do {
            guard CommandLine.arguments.count == 3 else {
                throw CompressionError.unsupportedFile("Usage: PliegueValidate manifest.json output-directory")
            }
            let manifest = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
            let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
            let report = try await run(manifest: manifest, destination: destination)
            if report.results.contains(where: { $0.status == "error" }) { exit(1) }
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(2)
        }
    }

    static func run(manifest: URL, destination: URL) async throws -> Report {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: manifest))
            guard Set(cases.map(\.name)).count == cases.count else {
                throw CompressionError.unsupportedFile("Validation case names must be unique.")
            }
            var outcomes: [Outcome] = []
            for item in cases {
                let start = Date()
                var outcome = Outcome(name: item.name, mode: item.mode, requestedFidelity: item.fidelity ?? "lossless", requestedQuality: item.quality ?? "balanced",
                                      status: "error", originalsUnchanged: false, seconds: 0)
                var urls: [URL] = []
                var originals: [String: String] = [:]
                do {
                    guard item.name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil,
                          let mode = CompressionMode(rawValue: item.mode),
                          let fidelity = MediaFidelity(rawValue: item.fidelity ?? "lossless"),
                          let quality = CompressionQuality(rawValue: item.quality ?? "balanced") else {
                        throw CompressionError.unsupportedFile("Invalid validation mode, fidelity, quality, or case name.")
                    }
                    urls = item.files.map { path in
                        path.hasPrefix("/") ? URL(fileURLWithPath: path) : manifest.deletingLastPathComponent().appendingPathComponent(path)
                    }
                    originals = try fingerprints(urls)
                    outcome.originalBytes = try totalSize(urls)
                    let inputs = try urls.map(InputFile.init)
                    let result = try await CompressionService.compress(files: inputs, mode: mode, quality: quality,
                                                                       fidelity: fidelity, cancellation: CancellationToken())
                    defer { result.discard() }
                    outcome.originalBytes = result.originalSize
                    outcome.outputBytes = result.outputSize
                    outcome.savedPercent = result.originalSize > 0 ? (1 - Double(result.outputSize) / Double(result.originalSize)) * 100 : 0
                    outcome.status = result.originalRetained ? "retained" : result.hasSavings ? "compressed" : "archive-no-savings"
                    outcome.verification = result.verification
                    outcome.detail = result.detail
                    if result.originalRetained { outcome.outputPath = result.url.path }
                    else {
                        let target = destination.appendingPathComponent(item.name + "-" + result.url.lastPathComponent)
                        try ResultSaver.save(result, to: target, protecting: urls)
                        guard try FileUtilities.size(of: target) == result.outputSize else {
                            throw CompressionError.verification("The saved size did not match the verified result.")
                        }
                        outcome.outputPath = target.path
                    }
                    outcome.originalsUnchanged = try fingerprints(urls) == originals
                    guard outcome.originalsUnchanged else { throw CompressionError.verification("An original file changed during validation.") }
                } catch {
                    outcome.status = "error"
                    outcome.error = String(describing: error) + " · " + error.localizedDescription
                    outcome.originalsUnchanged = !originals.isEmpty && (try? fingerprints(urls)) == originals
                }
                outcome.seconds = Date().timeIntervalSince(start)
                outcomes.append(outcome)
                print("\(outcome.name): \(outcome.status) · \(outcome.originalBytes.map(String.init) ?? "?") → \(outcome.outputBytes.map(String.init) ?? "?") bytes")
                if let error = outcome.error { print("  \(error)") }
            }
            let report = Report(createdAt: ISO8601DateFormatter().string(from: Date()),
                                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                                engine: "The app's native CompressionService and ResultSaver; no FFmpeg encoding fallback",
                                executionContext: executionContext, results: outcomes)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(report).write(to: destination.appendingPathComponent("results.json"), options: .atomic)
            let rows = outcomes.map { value in
                "| \(value.name) | \(value.status) | \(value.originalBytes.map(String.init) ?? "—") | \(value.outputBytes.map(String.init) ?? "—") | \(value.savedPercent.map { String(format: "%.2f%%", $0) } ?? "—") | \(value.originalsUnchanged ? "Yes" : "No") |"
            }.joined(separator: "\n")
            let markdown = """
            # Real File Validation

            Generated: \(report.createdAt). System: \(report.operatingSystem).

            \(report.engine).

            | Case | Status | Original bytes | Output bytes | Savings | Originals unchanged |
            | --- | --- | ---: | ---: | ---: | --- |
            \(rows)

            `retained` means the encoder did not produce a smaller accepted result. `error` is a failed operation, not a passing or skipped test. Detailed verification, paths, and errors are in results.json.
            """
            try markdown.write(to: destination.appendingPathComponent("results.md"), atomically: true, encoding: .utf8)
            return report
    }

    static var executionContext: String {
        #if VALIDATION_APP
        return "LaunchServices app with the same App Sandbox entitlements as Pliegue"
        #else
        return "Command-line process in the restricted development environment"
        #endif
    }

    static func regularFiles(_ urls: [URL]) throws -> [URL] {
        var result: [URL] = []
        for url in urls {
            let file = try InputFile(url: url)
            if file.isDirectory {
                guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
                    throw CompressionError.unsupportedFile("A selected folder could not be enumerated.")
                }
                for case let child as URL in iterator where try !InputFile(url: child).isDirectory { result.append(child) }
            } else { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func totalSize(_ urls: [URL]) throws -> UInt64 {
        try regularFiles(urls).reduce(UInt64(0)) { try $0 + FileUtilities.size(of: $1) }
    }

    static func fingerprints(_ urls: [URL]) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in try regularFiles(urls) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hash = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
            result[url.path] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}
