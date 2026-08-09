import AppKit
import SwiftUI

@main
struct MicrocamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            Label("Microcam", systemImage: model.monitor.displayState.symbolName)
        }
        .menuBarExtraStyle(.menu)

        Window("Microcam", id: "main") {
            RootView(model: model)
                .frame(minWidth: 880, minHeight: 580)
                .task { await model.start() }
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool { false }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var monitor: ActivityMonitor
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel) {
        self.model = model
        monitor = model.monitor
    }

    var body: some View {
        Text(monitor.displayState.title)
        Divider()
        Button("打开 Microcam") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Menu("暂停记录") {
            Button("15 分钟") { Task { await monitor.pause(for: 15 * 60) } }
            Button("1 小时") { Task { await monitor.pause(for: 60 * 60) } }
            Button("直到手动恢复") { Task { await monitor.pause(for: nil) } }
        }
        .disabled(!model.settings.recordingEnabled)
        if monitor.isPaused {
            Button("恢复记录") { Task { await monitor.resume() } }
        }
        Divider()
        Button("退出 Microcam") {
            Task {
                await model.shutdown()
                NSApp.terminate(nil)
            }
        }
    }
}
