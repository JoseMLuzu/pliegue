import AppKit
#if SWIFT_PACKAGE
import PliegueCore
#endif
import SwiftUI

@main
struct PliegueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = CompressionModel()

    var body: some Scene {
        Window("Pliegue", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 840, minHeight: 520)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1000, height: 640)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { model.chooseFiles() }.keyboardShortcut("o").disabled(model.isBusy)
                Button("Add Folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.isBusy)
            }
            CommandMenu("Compression") {
                Button("Compress") { model.start() }.keyboardShortcut(.return, modifiers: .command).disabled(!model.canStart)
                Button("Cancel") { model.cancel() }.keyboardShortcut(".", modifiers: .command).disabled(!model.isBusy)
                Divider()
                Button("Save Result…") { model.save() }.keyboardShortcut("s").disabled(model.result == nil || model.result?.originalRetained == true || model.isBusy)
            }
            CommandGroup(replacing: .help) {
                Button("About Compression Quality") { model.showHelp = true }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: CompressionModel?
    private var isTerminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task { @MainActor in
            await model?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
