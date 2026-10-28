import Foundation

public enum CompressionMode: String, CaseIterable, Identifiable, Sendable {
    case image, video, audio, model, archive
    public var id: String { rawValue }
    public var title: String {
        switch self { case .image: return "Photos"; case .video: return "Video"; case .audio: return "Audio"; case .model: return "3D models"; case .archive: return "Any file · ZIP" }
    }
    public var symbol: String {
        switch self { case .image: return "photo"; case .video: return "video"; case .audio: return "waveform"; case .model: return "cube"; case .archive: return "archivebox" }
    }
    public var actionTitle: String {
        switch self { case .image: return "Compress photo"; case .video: return "Reduce video"; case .audio: return "Compress audio"; case .model: return "Optimize model"; case .archive: return "Create ZIP" }
    }
    public var dropHint: String {
        switch self {
        case .image: return "JPEG, PNG, HEIC, TIFF, BMP · one static image"
        case .video: return "MP4, MOV, M4V · one video at a time"
        case .audio: return "WAV, AIFF, FLAC, M4A, MP3, CAF · one audio file"
        case .model: return "GLB optimization · project folders saved as lossless ZIP"
        case .archive: return "Any file type or folder · up to 10,000 entries"
        }
    }
    public var explanation: String {
        switch self {
        case .image: return "Lossless checks decoded pixels; high quality re-encodes with loss. Dimensions and orientation stay the same. Some metadata may change."
        case .video: return "Video is re-encoded with loss. Resolution stays the same; quality and savings depend on the source. Your original is never replaced."
        case .audio: return "Lossless ALAC preserves decoded audio samples for supported sources. High quality AAC has loss. Sample rate and channels stay the same."
        case .model: return "GLB optimization removes JSON whitespace without changing geometry, animation, or textures. Other models and project folders use verified ZIP. Include all linked assets in the selected folder."
        case .archive: return "ZIP keeps original file contents and folder paths. Already compressed formats may barely shrink or produce a larger archive."
        }
    }
}

public enum MediaFidelity: String, CaseIterable, Identifiable, Sendable {
    case lossless, highQuality
    public var id: String { rawValue }
    public var title: String { self == .lossless ? "Lossless" : "High quality · lossy" }
}

public enum CompressionQuality: String, CaseIterable, Identifiable, Sendable {
    case smaller, balanced, detail
    public var id: String { rawValue }
    public func title(for mode: CompressionMode) -> String {
        switch (mode, self) {
        case (.video, .smaller): return "More savings"
        case (.video, .balanced): return "High quality"
        case (.video, .detail): return "More detail"
        case (.archive, .smaller): return "Fast"
        case (.archive, .balanced): return "Balanced"
        case (.archive, .detail): return "Smallest"
        case (.model, .smaller): return "Fast ZIP"
        case (.model, .balanced): return "Balanced"
        case (.model, .detail): return "Smallest ZIP"
        case (.image, .smaller), (.audio, .smaller): return "More savings"
        case (.image, .balanced), (.audio, .balanced): return "High quality"
        case (.image, .detail), (.audio, .detail): return "More detail"
        }
    }
    public var zipLevel: Int32 { self == .smaller ? 1 : self == .detail ? 9 : 6 }
    public var imageQuality: Double { self == .smaller ? 0.72 : self == .detail ? 0.95 : 0.87 }
    public func audioBitRate(channels: UInt32) -> Int { (self == .smaller ? 64_000 : self == .detail ? 128_000 : 96_000) * Int(channels) }
    public func videoBitRate(source: Double, width: Int, height: Int, frameRate: Double) -> Int {
        let density = self == .smaller ? 0.055 : self == .detail ? 0.14 : 0.095
        let sourceRatio = self == .smaller ? 0.5 : self == .detail ? 0.9 : 0.75
        let suggested = Double(width) * Double(height) * max(1, frameRate) * density
        let target = source > 0 ? min(source * sourceRatio, suggested) : suggested
        return max(32_000, Int(target))
    }
}

public enum CompressionStage: String, Sendable {
    case analyzing = "Checking your files"
    case compressing = "Making room"
    case verifying = "Checking the result"
    case saving = "Saving your file"
}

public struct CompressionProgress: Sendable {
    public var stage: CompressionStage
    public var fraction: Double
    public var filename: String
    public init(_ stage: CompressionStage, fraction: Double, filename: String = "") {
        self.stage = stage
        self.fraction = min(1, max(0, fraction))
        self.filename = filename
    }
}

public typealias ProgressHandler = @Sendable (CompressionProgress) -> Void

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public func check() throws { if isCancelled || Task<Never, Never>.isCancelled { throw CancellationError() } }
}

public struct InputFile: Identifiable, Sendable {
    public let id: UUID
    public let url: URL
    public let size: UInt64
    public let modifiedAt: Date?
    public let isDirectory: Bool
    public var name: String { url.lastPathComponent }
    public var isVideo: Bool { ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) }
    public var isImage: Bool { ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "bmp"].contains(url.pathExtension.lowercased()) }
    public var isAudio: Bool { ["wav", "wave", "aif", "aiff", "flac", "m4a", "mp3", "aac", "caf"].contains(url.pathExtension.lowercased()) }
    public var isModel: Bool { ["glb", "gltf", "obj", "fbx", "stl", "blend", "ply", "dae", "usd", "usda", "usdc", "usdz", "3mf"].contains(url.pathExtension.lowercased()) }
    public var suggestedMode: CompressionMode {
        if isDirectory { return .archive }
        if isImage { return .image }; if isVideo { return .video }; if isAudio { return .audio }; if isModel { return .model }
        return .archive
    }
    public init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true || values.isDirectory == true, values.isSymbolicLink != true else {
            throw CompressionError.unsupportedFile("Select regular files or folders. Symbolic links are not followed.")
        }
        self.id = UUID()
        self.url = url
        self.isDirectory = values.isDirectory == true
        self.size = values.isDirectory == true ? 0 : UInt64(max(0, values.fileSize ?? 0))
        self.modifiedAt = values.contentModificationDate
    }
    public func checkUnchanged() throws {
        if isDirectory {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CompressionError.fileChanged(name) }
            return
        }
        let current = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard UInt64(max(0, current.fileSize ?? 0)) == size, current.contentModificationDate == modifiedAt else {
            throw CompressionError.fileChanged(name)
        }
    }
}

public struct CompressionResult: Sendable {
    public let url: URL
    public let workspace: URL?
    public let originalSize: UInt64
    public let outputSize: UInt64
    public let mode: CompressionMode
    public let originalRetained: Bool
    public let detail: String
    public let verification: String
    public var savedBytes: UInt64 { originalSize > outputSize ? originalSize - outputSize : 0 }
    public var savedPercent: Double { originalSize > 0 ? Double(savedBytes) / Double(originalSize) * 100 : 0 }
    public var hasSavings: Bool { savedBytes > 0 && !originalRetained }
    public init(url: URL, workspace: URL?, originalSize: UInt64, outputSize: UInt64,
                mode: CompressionMode, originalRetained: Bool = false, detail: String, verification: String) {
        self.url = url; self.workspace = workspace; self.originalSize = originalSize
        self.outputSize = outputSize; self.mode = mode; self.originalRetained = originalRetained
        self.detail = detail; self.verification = verification
    }
    public func discard() { if let workspace { try? FileManager.default.removeItem(at: workspace) } }
}

public enum CompressionError: LocalizedError {
    case unsupportedFile(String), fileChanged(String), archive(String), video(String), image(String), audio(String), model(String), verification(String), unsafeDestination
    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let message), .archive(let message), .video(let message), .image(let message), .audio(let message), .model(let message), .verification(let message): return message
        case .fileChanged(let name): return "\(name) changed while it was being processed. Select the file again."
        case .unsafeDestination: return "Choose a different location or filename. Pliegue never replaces an input file."
        }
    }
}

public enum FileUtilities {
    public static func size(of url: URL) throws -> UInt64 {
        UInt64(max(0, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
    }
    public static func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pliegue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    public static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    public static func uniqueArchiveName(_ input: String, used: inout Set<String>) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:\0<>\"|?*").union(.controlCharacters)
        var name = input.components(separatedBy: forbidden).joined(separator: "_").trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if name.isEmpty { name = "file" }
        let reserved = ["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
        if reserved.contains(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent.uppercased()) { name = "_" + name }
        let path = URL(fileURLWithPath: name)
        let ext = path.pathExtension
        let stem = path.deletingPathExtension().lastPathComponent
        var candidate = name
        var index = 2
        while used.contains(candidate.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))) {
            candidate = "\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)")
            index += 1
        }
        used.insert(candidate.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")))
        return candidate
    }
}
