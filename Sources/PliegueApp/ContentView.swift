import AppKit
#if SWIFT_PACKAGE
import PliegueCore
#endif
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: CompressionModel
    @State private var selectedFiles = Set<UUID>()
    @State private var showInspector = true
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 150, ideal: 175, max: 220)
        } detail: {
            workspace
                .navigationTitle("Pliegue")
                .navigationSubtitle(modeTitle)
                .inspector(isPresented: $showInspector) {
                    inspector
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 340)
                }
                .toolbar { workspaceToolbar }
        }
        .fileImporter(isPresented: $model.showFileImporter,
                      allowedContentTypes: model.importingFolders ? [.folder] : [.item],
                      allowsMultipleSelection: true) { response in
            switch response {
            case .success(let urls): model.add(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $model.showHelp) { helpSheet }
        .onChange(of: model.files.map(\.id)) { _, identifiers in
            selectedFiles.formIntersection(Set(identifiers))
        }
    }

    private var sidebar: some View {
        List(selection: Binding<CompressionMode?>(get: { model.mode }, set: { value in
            if let value { model.changeMode(value) }
        })) {
            Section("Compression") {
                ForEach(CompressionMode.allCases) { mode in
                    Label(mode == .archive ? "Files & Folders" : mode.title, systemImage: mode.symbol)
                        .tag(mode)
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isBusy)
        .safeAreaInset(edge: .bottom) {
            Label("Processed on this Mac", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            Group {
                if model.files.isEmpty { emptyState }
                else { fileTable }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.errorMessage { errorNotice(error) }
            if model.isBusy { progressArea }
            else if let result = model.result { resultArea(result) }
            statusBar
        }
        .frame(minWidth: 320)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.05)).padding(4).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted, perform: receiveFiles)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Files", systemImage: model.mode == .archive ? "tray" : model.mode.symbol)
        } description: {
            Text("Add files or drag them into this window.")
        } actions: {
            HStack {
                Button("Add Files…") { model.chooseFiles() }
                    .buttonStyle(.borderedProminent)
                Button("Add Folder…") { model.chooseFolder() }
            }
        }
    }

    private var fileTable: some View {
        Table(model.files, selection: $selectedFiles) {
            TableColumn("Name") { file in
                HStack(spacing: 7) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                        .resizable().scaledToFit().frame(width: 20, height: 20).accessibilityHidden(true)
                    Text(file.name).lineLimit(1).truncationMode(.middle).help(file.url.path)
                }.padding(.vertical, 3)
            }.width(min: 140, ideal: 260)
            TableColumn("Kind") { file in
                Text(file.isDirectory ? "Folder" : file.url.pathExtension.isEmpty ? "File" : file.url.pathExtension.uppercased())
                    .foregroundStyle(.secondary).lineLimit(1)
            }.width(65)
            TableColumn("Size") { file in
                Text(file.isDirectory ? "—" : FileUtilities.format(file.size))
                    .foregroundStyle(.secondary).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }.width(75)
        }
        .contextMenu {
            Button("Remove from List", systemImage: "minus") { removeSelectedFiles() }
                .disabled(selectedFiles.isEmpty || model.isBusy)
            Divider()
            Button("Clear List") { model.clear() }.disabled(model.isBusy)
        }
        .onDeleteCommand { removeSelectedFiles() }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Add Files…", systemImage: "doc.badge.plus") { model.chooseFiles() }
                Button("Add Folder…", systemImage: "folder.badge.plus") { model.chooseFolder() }
            } label: {
                Label("Add", systemImage: "plus")
            }.disabled(model.isBusy).help("Add files or folders")
            Button("Remove", systemImage: "minus") { removeSelectedFiles() }
                .disabled(selectedFiles.isEmpty || model.isBusy).help("Remove selected files from the list")
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isBusy {
                Button("Stop", systemImage: "stop.circle") { model.cancel() }
                    .help("Cancel the current operation (⌘.)")
            } else {
                Button("Compress", systemImage: "archivebox") { model.start() }
                    .labelStyle(.titleAndIcon).disabled(!model.canStart)
                    .help("\(model.mode.actionTitle) (⌘↩)")
            }
        }
        ToolbarItem(placement: .automatic) {
            Button("Save Result", systemImage: "square.and.arrow.down") { model.save() }
                .disabled(model.result == nil || model.result?.originalRetained == true || model.isBusy)
                .help("Save the compressed result (⌘S)")
        }
        ToolbarItem(placement: .automatic) {
            Button("Inspector", systemImage: "sidebar.right") { showInspector.toggle() }
                .help(showInspector ? "Hide compression options" : "Show compression options")
        }
    }

    private var inspector: some View {
        Form {
            Section {
                LabeledContent("Mode", value: modeTitle)
                if model.mode == .image || model.mode == .audio {
                    Picker("Fidelity", selection: Binding(get: { model.fidelity }, set: model.changeFidelity)) {
                        ForEach(MediaFidelity.allCases) { fidelity in
                            Text(fidelity.title).tag(fidelity)
                        }
                    }.disabled(model.isBusy)
                }
                if showsQualityControls {
                    Picker(model.mode == .archive || model.mode == .model ? "Effort" : "Quality",
                           selection: Binding(get: { model.quality }, set: model.changeQuality)) {
                        ForEach(CompressionQuality.allCases) { quality in
                            Text(quality.title(for: model.mode)).tag(quality)
                        }
                    }.disabled(model.isBusy)
                }
                LabeledContent("Output", value: outputLabel)
            } header: {
                Text("Compression")
            } footer: {
                Text(settingsExplanation).font(.caption).foregroundStyle(.secondary)
            }
            Section("Selection") {
                LabeledContent("Items", value: "\(model.files.count)")
                LabeledContent("Original size", value: model.hasFolders ? "Calculated during processing" : FileUtilities.format(model.totalSize))
                if !model.files.isEmpty && !model.canStart && !model.isBusy {
                    Label("Select one supported file for this mode, or choose Files & Folders for multiple files.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result = model.result, !model.isBusy { resultInspector(result) }
            Section("Supported Files") {
                Text(model.mode.dropHint).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .controlSize(.regular)
    }

    private func resultInspector(_ result: CompressionResult) -> some View {
        Section {
            LabeledContent("Original", value: FileUtilities.format(result.originalSize))
            LabeledContent(result.originalRetained ? "Retained" : "Result", value: FileUtilities.format(result.outputSize))
            if result.hasSavings {
                LabeledContent("Space saved") {
                    Text(result.savedPercent / 100, format: .percent.precision(.fractionLength(1))).foregroundStyle(.green)
                }
            }
            Label(result.verification, systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            Text(result.detail).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Result")
        }
    }

    private var progressArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(alignment: .center, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.progress.stage.rawValue).font(.callout).fontWeight(.medium)
                        Spacer()
                        Text(model.progress.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: model.progress.fraction).accessibilityLabel(model.progress.stage.rawValue)
                    if !model.progress.filename.isEmpty {
                        Text(model.progress.filename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button("Cancel") { model.cancel() }.controlSize(.small)
            }.padding(.horizontal, 16).padding(.bottom, 12).padding(.top, 4)
        }
    }

    private func resultArea(_ result: CompressionResult) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                Image(systemName: result.hasSavings ? "checkmark.circle.fill" : "info.circle")
                    .font(.title3).foregroundStyle(result.hasSavings ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.hasSavings ? "Compression Complete" : "No Size Reduction").font(.callout).fontWeight(.medium)
                    Text(result.hasSavings ? "\(FileUtilities.format(result.savedBytes)) saved · \(FileUtilities.format(result.outputSize)) result" : result.originalRetained ? "The original file has been retained." : "The ZIP is available to keep your files together.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                if result.originalRetained || model.savedURL != nil {
                    Button("Show in Finder") { model.reveal() }.controlSize(.small)
                }
                if !result.originalRetained {
                    Button(model.savedURL == nil ? "Save…" : "Save Copy…") { model.save() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }.padding(14)
        }
    }

    private func errorNotice(_ message: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss error")
            }.padding(12)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Text(model.files.isEmpty ? "No files selected" : "\(model.files.count) \(model.files.count == 1 ? "item" : "items")")
                if !model.files.isEmpty {
                    Text("·")
                    Text(model.hasFolders ? "Folder size calculated during processing" : FileUtilities.format(model.totalSize))
                }
                Spacer()
                Image(systemName: "lock").help("Files are processed locally. Originals are never overwritten.")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).frame(height: 28).background(.bar)
        }
    }

    private var modeTitle: String { model.mode == .archive ? "Files & Folders" : model.mode.title }

    private var showsQualityControls: Bool {
        if model.mode == .image || model.mode == .audio { return model.fidelity == .highQuality }
        if model.mode == .model, model.files.count == 1,
           !model.files[0].isDirectory, model.files[0].url.pathExtension.lowercased() == "glb" { return false }
        return true
    }

    private var outputLabel: String {
        switch model.mode {
        case .image: return model.fidelity == .lossless ? "PNG" : "JPEG / PNG"
        case .video: return "HEVC · MP4 / MOV"
        case .audio: return model.fidelity == .lossless ? "ALAC · M4A" : "AAC · M4A"
        case .model: return showsQualityControls ? "ZIP" : "GLB"
        case .archive: return "ZIP"
        }
    }

    private var settingsExplanation: String {
        switch model.mode {
        case .image:
            return model.fidelity == .lossless ? "Decoded pixels and color profile are verified. Metadata may change; some images may not get smaller." : "JPEG re-encoding has loss. Dimensions stay the same; transparency uses lossless PNG. Metadata may change."
        case .video: return "HEVC re-encoding has loss. Resolution and orientation stay the same; audio is copied unchanged. Savings vary."
        case .audio:
            return model.fidelity == .lossless ? "ALAC preserves decoded samples for supported integer audio. Sample rate and channels stay the same; metadata may change." : "AAC re-encoding has loss. Sample rate and channels stay the same; metadata may change."
        case .model:
            return showsQualityControls ? "ZIP preserves included assets and internal paths. Select a complete project folder to include linked textures." : "Removes GLB JSON whitespace. Geometry, animation, and textures stay unchanged. Compact models may not get smaller."
        case .archive: return "File contents are preserved and verified. Already compressed files may produce a larger ZIP."
        }
    }

    private var helpSheet: some View {
        VStack(spacing: 12) {
            Text("Pliegue Help").font(.title2)
            Text(model.mode.explanation)
            Button("Done") { model.showHelp = false }
        }.padding().frame(width: 400)
    }

    private func removeSelectedFiles() {
        guard !model.isBusy else { return }
        for file in model.files where selectedFiles.contains(file.id) { model.remove(file) }
        selectedFiles.removeAll()
    }

    private func receiveFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !model.isBusy else { return false }
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in model.add([url]) }
            }
        }
        return true
    }
}
