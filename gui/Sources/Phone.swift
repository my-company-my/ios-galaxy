import Foundation

/// What `adb devices` reports for the first phone.
enum AdbState: Equatable {
    case noTool, none, recovery, android, sideload, unauthorized, offline, other(String)

    var label: String {
        switch self {
        case .noTool: return "adb no instalado"
        case .none: return "sin teléfono (adb)"
        case .recovery: return "TWRP (adb recovery)"
        case .android: return "Android encendido"
        case .sideload: return "TWRP en modo sideload"
        case .unauthorized: return "adb sin autorizar"
        case .offline: return "adb offline"
        case .other(let s): return "adb: \(s)"
        }
    }

    /// Parse `adb devices` output: "List of devices attached" then
    /// "SERIAL<TAB>STATE" lines.
    static func parse(_ output: String) -> AdbState {
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices") || line.hasPrefix("*") { continue }
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard f.count >= 2 else { continue }
            switch f[1] {
            case "recovery": return .recovery
            case "device": return .android
            case "sideload": return .sideload
            case "unauthorized": return .unauthorized
            case "offline": return .offline
            default: return .other(f[1...].joined(separator: " "))
            }
        }
        return .none
    }
}

/// Polls the phone every 2 s. Heimdall (Download mode) is only polled when
/// a step asks for it and nothing else runs (it only lists USB devices).
final class PhoneMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var adb: AdbState = .none
    @Published private(set) var download = false
    @Published private(set) var heimdallInstalled = false
    @Published var watchDownload = false
    weak var runner: Runner?

    private var timer: Timer?
    private var busy = false
    private var serverStarted = false

    func start() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func poll() {
        if busy { return }
        busy = true
        let watch = watchDownload && !(runner?.running ?? false)
        let startServer = !serverStarted
        Task {
            var state = AdbState.noTool
            let (has, _) = await Shell.capture("command -v adb", timeout: 5)
            if has == 0 {
                if startServer {
                    // output to /dev/null: the server must not inherit our pipe
                    _ = await Shell.capture("adb start-server >/dev/null 2>&1", timeout: 20)
                }
                let (_, out) = await Shell.capture("adb devices", timeout: 8)
                state = AdbState.parse(out)
            }
            let (hasH, _) = await Shell.capture("command -v heimdall", timeout: 5)
            var dl = false
            if hasH == 0 && watch {
                let (rc, _) = await Shell.capture("heimdall detect", timeout: 8)
                dl = rc == 0
            }
            let started = has == 0
            onMain {
                if self.adb != state { self.adb = state }
                if self.heimdallInstalled != (hasH == 0) { self.heimdallInstalled = hasH == 0 }
                // keep the last value while a command (e.g. heimdall flash) runs
                if watch, self.download != dl { self.download = dl }
                if !self.watchDownload, self.download { self.download = false }
                if started { self.serverStarted = true }
                self.busy = false
            }
        }
    }
}
