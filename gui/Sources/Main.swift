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
        .defaultSize(width: 1100, height: 900)
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
            try? await Task.sleep(nanoseconds: 4_000_000_000)   // first status checks
            // something in the output panel (harmless, read-only)
            await state.runner.run("Prueba de la salida (captura de la CI)", "echo 'salida de prueba'; git log -1 --oneline")
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
            say("snapshots done")
            try? await Task.sleep(nanoseconds: 1_000_000_000)   // let the sheet close
            NSApp.terminate(nil)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            exit(0)   // terminate can be refused while a window is busy
        }
    }

    /// stderr is unbuffered: the CI sees these lines even if the app is killed
    static func say(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    @MainActor static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && !$0.isSheet }
    }

    @MainActor static func capture(_ window: NSWindow?, to url: URL) {
        guard let v = window?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else {
            say("snapshot \(url.lastPathComponent): no window")
            return
        }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            say("snapshot \(url.lastPathComponent): \(Int(v.bounds.width))x\(Int(v.bounds.height))")
        }
    }
}
