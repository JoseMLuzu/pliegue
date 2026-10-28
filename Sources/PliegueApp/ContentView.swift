import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import PliegueCore
#endif

struct ContentView: View {
    @ObservedObject var model: CompressionModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: Binding(get: { model.mode }, set: model.changeMode)) {
                ForEach(CompressionMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            List(model.files) { file in Text(file.name) }
            if let result = model.result { Text(result.detail).font(.caption) }
            HStack {
                Button("Add Files…") { model.chooseFiles() }.disabled(model.isBusy)
                Button("Add Folder…") { model.chooseFolder() }.disabled(model.isBusy)
                Spacer()
                if model.isBusy { Button("Cancel") { model.cancel() } }
                Button("Compress") { model.start() }.disabled(!model.canStart)
                Button("Save…") { model.save() }
                    .disabled(model.result == nil || model.result?.originalRetained == true || model.isBusy)
            }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
        }.padding()
        .fileImporter(isPresented: $model.showFileImporter,
                      allowedContentTypes: model.importingFolders ? [.folder] : [.item],
                      allowsMultipleSelection: true) { response in
            switch response {
            case .success(let urls): model.add(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $model.showHelp) {
            VStack(spacing: 12) {
                Text("Pliegue Help").font(.title2)
                Text(model.mode.explanation)
                Button("Done") { model.showHelp = false }
            }.padding().frame(width: 400)
        }
    }
}
