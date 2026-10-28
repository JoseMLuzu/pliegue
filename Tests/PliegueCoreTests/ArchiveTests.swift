import CryptoKit
import Foundation
@testable import PliegueCore
import XCTest

final class ArchiveTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try FileUtilities.makeWorkspace() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func file(_ name: String, data: Data, subfolder: String = "") throws -> InputFile {
        let folder = directory.appendingPathComponent(subfolder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return try InputFile(url: url)
    }

    private func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        let errors = Pipe(); process.standardError = errors
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testZIP64RoundTripPreservesMixedContentsAndUnicodeNames() throws {
        let text = Data(String(repeating: "A little less space. Every byte intact.\n", count: 50_000).utf8)
        let binary = Data((0..<1_100_000).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        let files = try [file("notes.txt", data: text), file("写真.bin", data: binary), file("empty.txt", data: Data())]
        let result = try ZIPCompressor().compress(files, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        let extracted = directory.appendingPathComponent("extracted")
        try unzip(result.url, to: extracted)
        for file in files {
            XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent(file.name)), try Data(contentsOf: file.url))
        }
    }

    func testDuplicateNamesAreNotOverwritten() throws {
        let first = try file("photo.jpg", data: Data("first".utf8), subfolder: "one")
        let second = try file("photo.jpg", data: Data("second".utf8), subfolder: "two")
        let result = try ZIPCompressor().compress([first, second], quality: .detail, cancellation: CancellationToken())
        defer { result.discard() }
        let extracted = directory.appendingPathComponent("extracted")
        try unzip(result.url, to: extracted)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("photo.jpg")), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("photo (2).jpg")), Data("second".utf8))
    }

    func testIncompressibleInputCrossingBlockBoundariesStillRoundTrips() throws {
        var generator: UInt64 = 0x8e134ac987621df1
        var bytes = [UInt8](repeating: 0, count: 2_100_017)
        for index in bytes.indices {
            generator ^= generator << 13; generator ^= generator >> 7; generator ^= generator << 17
            bytes[index] = UInt8(truncatingIfNeeded: generator >> 24)
        }
        let data = Data(bytes)
        let input = try file("random.bin", data: data)
        let result = try ZIPCompressor().compress([input], quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertFalse(result.hasSavings)
        XCTAssertGreaterThan(result.outputSize, input.size)
        let destination = directory.appendingPathComponent("random-output")
        try unzip(result.url, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(input.name)), data)
    }

    func testAllLevelsPreserveBytesIncludingEmptyFiles() throws {
        for quality in CompressionQuality.allCases {
            let input = try file("empty.bin", data: Data())
            let result = try ZIPCompressor().compress([input], quality: quality, cancellation: CancellationToken())
            defer { result.discard() }
            XCTAssertEqual(result.originalSize, 0)
            XCTAssertGreaterThan(result.outputSize, 0)
            XCTAssertFalse(result.hasSavings)
            let destination = directory.appendingPathComponent(quality.rawValue)
            try unzip(result.url, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(input.name)), Data())
        }
    }

    func testCancellationDuringCompressionRemovesPartialResult() throws {
        let input = try file("large.bin", data: Data(repeating: 7, count: 3_000_000))
        let token = CancellationToken()
        XCTAssertThrowsError(try ZIPCompressor().compress([input], quality: .balanced, cancellation: token) { _ in token.cancel() }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try FileUtilities.size(of: input.url), input.size)
    }

    func testChangedInputIsRejected() throws {
        let input = try file("changed.txt", data: Data("before".utf8))
        try Data("after with different size".utf8).write(to: input.url)
        XCTAssertThrowsError(try ZIPCompressor().compress([input], quality: .balanced, cancellation: CancellationToken()))
    }

    func testSaveNeverOverwritesAnInputOrHardLink() throws {
        let input = try file("source.txt", data: Data(repeating: 32, count: 4_000))
        let result = try ZIPCompressor().compress([input], quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertThrowsError(try ResultSaver.save(result, to: input.url, protecting: [input.url]))
        let alias = directory.appendingPathComponent("hard-link.txt")
        try FileManager.default.linkItem(at: input.url, to: alias)
        XCTAssertThrowsError(try ResultSaver.save(result, to: alias, protecting: [input.url]))
        XCTAssertEqual(try Data(contentsOf: input.url), Data(repeating: 32, count: 4_000))
    }

    func testSaveCreatesAndAtomicallyReplacesOnlyChosenResult() throws {
        let input = try file("source.txt", data: Data(repeating: 65, count: 8_000))
        let result = try ZIPCompressor().compress([input], quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        let destination = directory.appendingPathComponent("saved.zip")
        try ResultSaver.save(result, to: destination, protecting: [input.url])
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: result.url))
        try Data("old result".utf8).write(to: destination)
        try ResultSaver.save(result, to: destination, protecting: [input.url])
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: result.url))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.url.path))
    }

    func testCancelledSaveKeepsExistingDestination() throws {
        let input = try file("source.txt", data: Data(repeating: 65, count: 8_000))
        let result = try ZIPCompressor().compress([input], quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        let destination = directory.appendingPathComponent("saved.zip")
        let oldData = Data("previous result".utf8)
        try oldData.write(to: destination)
        let token = CancellationToken()
        XCTAssertThrowsError(try ResultSaver.save(result, to: destination, protecting: [input.url], cancellation: token) { _ in token.cancel() })
        XCTAssertEqual(try Data(contentsOf: destination), oldData)
    }
}
