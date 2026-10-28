import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ImageCompressor: Sendable {
    public init() {}

    public func compress(_ file: InputFile, fidelity: MediaFidelity, quality: CompressionQuality,
                         cancellation: CancellationToken, progress: ProgressHandler = { _ in }) throws -> CompressionResult {
        try cancellation.check(); try file.checkUnchanged()
        progress(.init(.analyzing, fraction: 0, filename: file.name))
        guard !file.isDirectory, let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw CompressionError.image("This image cannot be opened by macOS. Use lossless ZIP to keep the original.")
        }
        guard CGImageSourceGetCount(source) == 1 else { throw CompressionError.image("Animated or multi-page images are not flattened. Use ZIP to keep all frames or pages.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0, width <= 64_000_000 / height else {
            throw CompressionError.image("Images above 64 megapixels use ZIP to avoid excessive memory use.")
        }
        for auxiliary in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, auxiliary) != nil {
                throw CompressionError.image("This image has HDR, depth, or portrait auxiliary data. Use ZIP to preserve it.")
            }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw CompressionError.image("The image pixels could not be decoded.")
        }
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let lossless = fidelity == .lossless || hasAlpha
        if lossless && image.bitsPerComponent > 8 {
            throw CompressionError.image("Lossless pixel verification currently supports up to 8 bits per component. Use ZIP for this image.")
        }
        let type = lossless ? UTType.png : UTType.jpeg
        let workspace = try FileUtilities.makeWorkspace()
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: workspace) } }
        let url = workspace.appendingPathComponent(file.url.deletingPathExtension().lastPathComponent + "-smaller." + (lossless ? "png" : "jpg"))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CompressionError.image("The image encoder could not create a result.")
        }
        var outputProperties = properties
        if !lossless { outputProperties[kCGImageDestinationLossyCompressionQuality as String] = quality.imageQuality }
        try cancellation.check()
        progress(.init(.compressing, fraction: 0.25, filename: file.name))
        CGImageDestinationAddImageFromSource(destination, source, 0, outputProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CompressionError.image("The image could not be encoded. Check available disk space.") }
        try cancellation.check()
        progress(.init(.verifying, fraction: 0.8, filename: file.name))
        guard let outputSource = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(outputSource) == 1,
              let decoded = CGImageSourceCreateImageAtIndex(outputSource, 0, nil) else {
            throw CompressionError.verification("The compressed image could not be decoded.")
        }
        let outputInfo = CGImageSourceCopyPropertiesAtIndex(outputSource, 0, nil) as? [String: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        let outputOrientation = (outputInfo[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
        guard decoded.width == image.width, decoded.height == image.height, orientation == outputOrientation else {
            throw CompressionError.verification("Image dimensions or orientation changed unexpectedly. The result was discarded.")
        }
        if lossless {
            let originalICC = image.colorSpace?.copyICCData() as Data?
            let outputICC = decoded.colorSpace?.copyICCData() as Data?
            guard image.bitsPerComponent == decoded.bitsPerComponent, originalICC == outputICC,
                  try pixelDigest(image) == pixelDigest(decoded) else {
                throw CompressionError.verification("The decoded pixels or color profile changed. Use ZIP to preserve this image exactly.")
            }
        }
        try cancellation.check(); try file.checkUnchanged()
        let size = try FileUtilities.size(of: url)
        if size >= file.size {
            return CompressionResult(url: file.url, workspace: nil, originalSize: file.size, outputSize: file.size, mode: .image,
                                     originalRetained: true, detail: "This image is already compact for the chosen settings. The new copy was discarded. High quality can save more, with loss.", verification: "Original image retained without changes")
        }
        keep = true
        progress(.init(.verifying, fraction: 1, filename: file.name))
        return CompressionResult(url: url, workspace: workspace, originalSize: file.size, outputSize: size, mode: .image,
                                 detail: lossless ? "\(width) × \(height) · Decoded pixels, transparency, and color profile preserved. PNG output; some metadata may change." : "\(width) × \(height) · JPEG re-encoding with loss. Dimensions and orientation preserved; some metadata may change.",
                                 verification: lossless ? "Decoded pixels SHA-256 verified" : "Image decoding, dimensions, and orientation checked")
    }

    private func pixelDigest(_ image: CGImage) throws -> SHA256.Digest {
        let count = image.width * image.height * 4
        var data = Data(count: count)
        let success = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { throw CompressionError.verification("The image could not be prepared for pixel verification.") }
        return SHA256.hash(data: data)
    }
}
