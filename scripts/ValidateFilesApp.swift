import SwiftUI

// Diagnostic host only. It runs the real core with public fixtures inside an app sandbox.
@main
struct ValidateFilesApp: App {
    var body: some Scene {
        Window("Pliegue Validation", id: "validation") {
            ValidationView().frame(minWidth: 650, minHeight: 440)
        }.defaultSize(width: 760, height: 560)
    }
}

private struct ValidationView: View {
    @State private var report: ValidateFiles.Report?
    @State private var error: String?
    @State private var outputPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Real File Validation").font(.title2).fontWeight(.semibold)
            if let report {
                let failures = report.results.filter { $0.status == "error" }.count
                Label("\(report.results.count) cases completed · \(failures) failed", systemImage: failures == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .foregroundStyle(failures == 0 ? Color.green : Color.orange)
                List(report.results, id: \.name) { result in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.name).fontWeight(.medium)
                            Text(result.error ?? result.verification ?? result.status).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(result.status)
                            if let input = result.originalBytes, let output = result.outputBytes {
                                Text("\(input) → \(output) bytes").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Reports: \(outputPath)").font(.caption).textSelection(.enabled)
            } else if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Testing the native compression engines…") }
                Spacer()
            }
        }.padding(20).task {
            guard let manifest = Bundle.main.url(forResource: "manifest", withExtension: "json") else {
                error = "The validation manifest is missing."; return
            }
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Pliegue-RealFile-Report", isDirectory: true)
            outputPath = destination.path
            do { report = try await ValidateFiles.run(manifest: manifest, destination: destination) }
            catch { self.error = String(describing: error) }
        }
    }
}
