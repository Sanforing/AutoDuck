import AppKit
import SwiftUI

@main
struct AutoDuckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
                .environmentObject(model.settings)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    var body: some View {
        switch model.menuBarIcon {
        case .duck(let style):
            Image(nsImage: DuckIcon.image(style))
        case .symbol(let name):
            Image(systemName: name)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if DocsRenderer.isActive {
            DocsRenderer.run()
            exit(0)
        }
        if Probe.isActive {
            Probe.run { exit(0) }
            return
        }
        if Probe.isActive2 {
            Probe.run2 { exit(0) }
            return
        }
        if Probe.isActive3 {
            Probe.run3 { exit(0) }
            return
        }
        if Probe.isActive4 {
            Probe.run4 { exit(0) }
            return
        }
        // Restore the user's volume if we get killed from the terminal while ducked.
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                AppModel.shared.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
