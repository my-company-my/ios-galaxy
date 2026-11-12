import AppKit
import SwiftUI

/// iOS Galaxy: a wizard over the ios-galaxy scripts (tools/, shim/).
///   "iOS Galaxy" --selftest        logic checks, no window (CI)
///   "iOS Galaxy" --snapshots DIR   PNG of every step, then quit (CI)
@main
struct Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        IOSGalaxyApp.main()
    }
}

struct IOSGalaxyApp: App {
    @StateObject var state = AppState()

    var body: some Scene {
        WindowGroup("iOS Galaxy") {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.runner)
                .environmentObject(state.phone)
                .onAppear { Snapshots.startIfRequested(state) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

enum Snapshots {
    static func startIfRequested(_ state: AppState) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Task { @MainActor in
            NSApp.windows.first { !$0.isSheet }?.setContentSize(NSSize(width: 1060, height: 820))
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // first status checks
            for s in 0..<steps.count {
                state.step = s
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                capture(mainWindow(), to: dir.appendingPathComponent(String(format: "paso-%d.png", s)))
            }
            state.step = 8
            state.requestWrite(.boot, title: "Escribir la partición BOOT",
                               message: "Ejemplo de la confirmación escrita (captura de la CI).") {}
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            capture(NSApp.windows.first { $0.isSheet && $0.isVisible }, to: dir.appendingPathComponent("confirmacion.png"))
            state.confirm = nil
            print("snapshots done")
            NSApp.terminate(nil)
        }
    }

    @MainActor static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet }
    }

    @MainActor static func capture(_ window: NSWindow?, to url: URL) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            print("snapshot \(url.lastPathComponent): no window")
            return
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("snapshot \(url.lastPathComponent): \(Int(v.bounds.width))x\(Int(v.bounds.height))")
        }
    }
}
