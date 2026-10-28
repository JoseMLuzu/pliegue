import AppKit
import Combine
#if SWIFT_PACKAGE
import PliegueCore
#endif
import UniformTypeIdentifiers

@MainActor
final class CompressionModel: ObservableObject {
    @Published var files: [InputFile] = []
    @Published var mode: CompressionMode = .archive
    @Published var quality: CompressionQuality = .balanced
    @Published var fidelity: MediaFidelity = .lossless
    @Published var isBusy = false
    @Published var progress = CompressionProgress(.analyzing, fraction: 0)
    @Published var result: CompressionResult?
    @Published var errorMessage: String?
    @Published var savedURL: URL?
    @Published var showHelp = false
    @Published var showFileImporter = false
    @Published var importingFolders = false
    private var task: Task<Void, Never>?
    private var cancellation = CancellationToken()
    private var scopedURLs: [URL] = []
    private var runID = UUID()

    var totalSize: UInt64 { files.reduce(0) { $0 + $1.size } }
    var hasFolders: Bool { files.contains(where: \.isDirectory) }
    var canStart: Bool {
        guard !isBusy, !files.isEmpty else { return false }
        switch mode {
        case .archive: return true
        case .model: return files.contains { $0.isModel || $0.isDirectory }
        case .image: return files.count == 1 && !files[0].isDirectory && files[0].isImage
        case .video: return files.count == 1 && !files[0].isDirectory && files[0].isVideo
        case .audio: return files.count == 1 && !files[0].isDirectory && files[0].isAudio
        }
    }

    func chooseFiles() {
        guard !isBusy else { return }
        importingFolders = false
        showFileImporter = true
    }

    func chooseFolder() {
        guard !isBusy else { return }
        importingFolders = true
        showFileImporter = true
    }

    func add(_ urls: [URL]) {
        guard !isBusy else { return }
        guard files.count + urls.count <= 10_000 else { errorMessage = "Select up to 10,000 files per archive."; return }
        clearResult()
        errorMessage = nil
        var messages: [String] = []
        for url in urls {
            if files.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) { continue }
            let access = url.startAccessingSecurityScopedResource()
            do {
                let file = try InputFile(url: url)
                files.append(file)
                if access { scopedURLs.append(url) }
            } catch {
                if access { url.stopAccessingSecurityScopedResource() }
                messages.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        let nextMode = files.count == 1 ? files[0].suggestedMode : .archive
        if nextMode != mode { fidelity = .lossless }
        mode = nextMode
        if !messages.isEmpty { errorMessage = messages.joined(separator: "\n") }
    }

    func remove(_ file: InputFile) {
        guard !isBusy else { return }
        clearResult()
        files.removeAll { $0.id == file.id }
        if let index = scopedURLs.firstIndex(of: file.url) { scopedURLs.remove(at: index).stopAccessingSecurityScopedResource() }
    }

    func clear() {
        guard !isBusy else { return }
        clearResult()
        files.removeAll()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
        errorMessage = nil
    }

    func changeMode(_ value: CompressionMode) {
        guard !isBusy else { return }
        clearResult(); mode = value; fidelity = .lossless; errorMessage = nil
    }

    func changeQuality(_ value: CompressionQuality) {
        guard !isBusy else { return }
        clearResult(); quality = value
    }

    func changeFidelity(_ value: MediaFidelity) {
        guard !isBusy else { return }
        clearResult(); fidelity = value
    }

    func start() {
        guard canStart else { return }
        clearResult()
        errorMessage = nil
        isBusy = true
        cancellation = CancellationToken()
        let token = cancellation
        let selected = files, selectedMode = mode, selectedQuality = quality, selectedFidelity = fidelity
        let id = UUID(); runID = id
        progress = .init(.analyzing, fraction: 0)
        let report: ProgressHandler = { [self] value in
            Task { @MainActor in
                guard self.runID == id, self.isBusy else { return }
                self.progress = value
            }
        }
        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try await CompressionService.compress(files: selected, mode: selectedMode, quality: selectedQuality,
                                                          fidelity: selectedFidelity, cancellation: token, progress: report)
                }.value
                guard let self, self.runID == id else { result.discard(); return }
                if token.isCancelled { result.discard(); self.isBusy = false; self.task = nil; return }
                self.result = result; self.isBusy = false; self.task = nil
                if let window = NSApp.mainWindow {
                    NSAccessibility.post(element: window, notification: .announcementRequested,
                                         userInfo: [.announcement: result.hasSavings ? "Compression complete. Your file is ready to save." : "No size reduction. Your original is unchanged.", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
                }
            } catch {
                guard let self, self.runID == id else { return }
                self.isBusy = false; self.task = nil
                if !(error is CancellationError) && !token.isCancelled { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func cancel() { cancellation.cancel() }

    func save() {
        guard let result, !isBusy else { return }
        let panel = NSSavePanel()
        panel.title = "Save compressed file"
        panel.nameFieldStringValue = result.url.lastPathComponent
        panel.canCreateDirectories = true
        if let type = UTType(filenameExtension: result.url.pathExtension) { panel.allowedContentTypes = [type] }
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.saveResult(result, to: destination)
        }
    }

    private func saveResult(_ result: CompressionResult, to destination: URL) {
        guard !isBusy, self.result?.url == result.url else { return }
        let access = destination.startAccessingSecurityScopedResource()
        isBusy = true; errorMessage = nil
        cancellation = CancellationToken()
        let token = cancellation, inputURLs = files.map(\.url)
        let id = UUID(); runID = id
        progress = .init(.saving, fraction: 0)
        let report: ProgressHandler = { [self] value in
            Task { @MainActor in if self.runID == id, self.isBusy { self.progress = value } }
        }
        task = Task { [weak self] in
            defer { if access { destination.stopAccessingSecurityScopedResource() } }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try ResultSaver.save(result, to: destination, protecting: inputURLs, cancellation: token, progress: report)
                }.value
                self?.savedURL = destination
            } catch {
                if !(error is CancellationError) && !token.isCancelled { self?.errorMessage = error.localizedDescription }
            }
            self?.isBusy = false; self?.task = nil
        }
    }

    func reveal() {
        if let url = savedURL ?? (result?.originalRetained == true ? result?.url : nil) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func shutdown() async {
        cancellation.cancel()
        await task?.value
        result?.discard()
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }

    private func clearResult() { result?.discard(); result = nil; savedURL = nil }
}
