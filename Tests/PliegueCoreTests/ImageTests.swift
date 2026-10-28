import CoreGraphics
import Foundation
import ImageIO
@testable import PliegueCore
import UniformTypeIdentifiers
import XCTest

final class ImageTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws { folder = try FileUtilities.makeWorkspace() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func makeImage(alpha: Bool = false) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: alpha ? 0.4 : 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 40, y: 40, width: 120, height: 80))
        return try XCTUnwrap(context.makeImage())
    }

    private func source(alpha: Bool = false) throws -> InputFile {
        let url = folder.appendingPathComponent("photo.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try makeImage(alpha: alpha), [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try InputFile(url: url)
    }

    func testLosslessPhotoProducesSmallerVerifiedPNG() throws {
        let input = try source()
        let original = try Data(contentsOf: input.url)
        let result = try ImageCompressor().compress(input, fidelity: .lossless, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        XCTAssertEqual(result.url.pathExtension, "png")
        XCTAssertTrue(result.verification.contains("SHA-256"))
        XCTAssertEqual(try Data(contentsOf: input.url), original)
    }

    func testTransparencyUsesPNGEvenWhenLossyIsSelected() throws {
        let input = try source(alpha: true)
        let result = try ImageCompressor().compress(input, fidelity: .highQuality, quality: .smaller, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        XCTAssertEqual(result.url.pathExtension, "png")
        XCTAssertTrue(result.verification.contains("SHA-256"))
    }

    func testHighQualityPhotoPreservesDimensions() throws {
        let input = try source()
        // A BMP source is opaque, so the high-quality path produces JPEG.
        let url = folder.appendingPathComponent("opaque.bmp")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(XCTUnwrap(CGImageSourceCreateWithURL(input.url as CFURL, nil)), 0, nil))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.bmp.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try ImageCompressor().compress(InputFile(url: url), fidelity: .highQuality, quality: .balanced, cancellation: CancellationToken())
        defer { result.discard() }
        XCTAssertTrue(result.hasSavings)
        XCTAssertEqual(result.url.pathExtension, "jpg")
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(output, 0, nil))
        XCTAssertEqual(decoded.width, 320); XCTAssertEqual(decoded.height, 180)
    }

    func testAnimatedImageIsNeverFlattened() throws {
        let url = folder.appendingPathComponent("animated.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationAddImage(destination, try makeImage(), nil)
        CGImageDestinationAddImage(destination, try makeImage(alpha: true), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try ImageCompressor().compress(InputFile(url: url), fidelity: .highQuality, quality: .balanced, cancellation: CancellationToken()))
    }

    func testCancelledImageDoesNotChangeSource() throws {
        let input = try source()
        let original = try Data(contentsOf: input.url)
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try ImageCompressor().compress(input, fidelity: .lossless, quality: .balanced, cancellation: token))
        XCTAssertEqual(try Data(contentsOf: input.url), original)
    }
}
