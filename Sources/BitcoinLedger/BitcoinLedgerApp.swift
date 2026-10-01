import SwiftUI
import AppKit
import LedgerCore

@main
struct BitcoinLedgerApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Bitcoin Ledger", id: "main") {
            ContentView().environmentObject(store)
                .frame(minWidth: 600, minHeight: 420)
                .task {
                    await store.refreshPrice()
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(300))
                        guard !Task.isCancelled else { break }
                        await store.refreshPrice()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await store.refreshPrice() }
                }
        }
        .defaultSize(width: 1100, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导出完整备份…") { store.exportJSON() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!store.canEdit || store.isPresentingPanel)
                Button("导出交易历史 CSV…") { store.exportCSV() }.disabled(!store.canEdit || store.isPresentingPanel)
                Button("从 JSON 备份恢复…") { store.importJSON() }.disabled(store.isPresentingPanel)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
