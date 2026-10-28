import Foundation
@testable import PliegueCore
import XCTest

final class ModelTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws { directory = try FileUtilities.makeWorkspace() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func glb(_ json: String, bin: Data = Data((0..<32).map(UInt8.init))) throws -> InputFile {
        var chunk = Data(json.utf8)
        while chunk.count % 4 != 0 { chunk.append(0x20) }
        var result = Data()
        result.le(UInt32(0x46546c67)); result.le(UInt32(2)); result.le(UInt32(20 + chunk.count + 8 + bin.count))
        result.le(UInt32(chunk.count)); result.le(UInt32(0x4e4f534a)); result.append(chunk)
        result.le(UInt32(bin.count)); result.le(UInt32(0x004e4942)); result.append(bin)
        let url = directory.appendingPathComponent("scene.glb")
        try result.write(to: url)
        return try InputFile(url: url)
    }

    func testGLBMinifiesOnlyWhitespaceAndPreservesBinaryPayload() throws {
        let json = """
        {
            "asset": { "version": "2.0" },
            "buffers": [ { "byteLength": 32 } ],
            "extras": {
                "largeInteger": 1234567890123456789,
                "label": "keep  both  spaces and \\\"quotes\\\""
            }
        }
        """
        let input = try glb(json)
        let original = try Data(contentsOf: input.url)
        let result = try ModelCompressor().compressGLB(input, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        let output = try Data(contentsOf: result.url)
        XCTAssertEqual(output.u32(at: 8), UInt32(output.count))
        let jsonSize = Int(output.u32(at: 12))
        let compactJSON = String(decoding: output[20..<(20 + jsonSize)], as: UTF8.self)
        XCTAssertTrue(compactJSON.contains("1234567890123456789"))
        XCTAssertTrue(compactJSON.contains("keep  both  spaces"))
        XCTAssertEqual(output.suffix(40), original.suffix(40))
        XCTAssertEqual(try Data(contentsOf: input.url), original)
    }

    func testCompactGLBRetainsOriginalWithoutInventingSavings() throws {
        let input = try glb("{\"asset\":{\"version\":\"2.0\"}}")
        let result = try ModelCompressor().compressGLB(input, cancellation: CancellationToken())
        XCTAssertTrue(result.originalRetained)
        XCTAssertEqual(result.url, input.url)
        XCTAssertNil(result.workspace)
    }

    func testExternalTexturesRequireProjectFolder() throws {
        let input = try glb("{\"asset\":{\"version\":\"2.0\"},\"images\":[{\"uri\":\"textures/base.png\"}]}")
        XCTAssertThrowsError(try ModelCompressor().compressGLB(input, cancellation: CancellationToken())) { error in
            XCTAssertTrue(error.localizedDescription.contains("project folder"))
        }
    }

    func testMalformedChunkLengthIsRejected() throws {
        let input = try glb("{\"asset\":{\"version\":\"2.0\"}}")
        var data = try Data(contentsOf: input.url)
        data[8] ^= 0x01
        try data.write(to: input.url)
        XCTAssertThrowsError(try ModelCompressor().compressGLB(InputFile(url: input.url), cancellation: CancellationToken()))
    }

    func testProjectArchivePreservesRelativeTexturesAndEmptyFolders() throws {
        let root = directory.appendingPathComponent("Model Project")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("textures/empty"), withIntermediateDirectories: true)
        let model = Data("mtllib materials.mtl\nv 0 0 0\n".utf8)
        let material = Data("newmtl surface\nmap_Kd textures/base.png\n".utf8)
        let texture = Data(repeating: 7, count: 10_000)
        try model.write(to: root.appendingPathComponent("mesh.obj"))
        try material.write(to: root.appendingPathComponent("materials.mtl"))
        try texture.write(to: root.appendingPathComponent("textures/base.png"))
        let result = try ZIPCompressor().compress([InputFile(url: root)], quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        let destination = directory.appendingPathComponent("extracted")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", result.url.path, destination.path]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let extracted = destination.appendingPathComponent("Model Project")
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("mesh.obj")), model)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("materials.mtl")), material)
        XCTAssertEqual(try Data(contentsOf: extracted.appendingPathComponent("textures/base.png")), texture)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("textures/empty").path))
        XCTAssertEqual(result.originalSize, UInt64(model.count + material.count + texture.count))
        XCTAssertThrowsError(try ResultSaver.save(result, to: root.appendingPathComponent("mesh.obj"), protecting: [root]))
        XCTAssertThrowsError(try ResultSaver.save(result, to: root.appendingPathComponent("new.zip"), protecting: [root]))
    }

    func testProjectFolderDoesNotFollowExternalSymbolicLinks() throws {
        let root = directory.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("external"), withDestinationURL: directory)
        XCTAssertThrowsError(try ZIPCompressor().compress([InputFile(url: root)], quality: .balanced, cancellation: CancellationToken()))
    }
}
