import AppKit
import Foundation

/// A lock-protected value shared with Process/FileHandle callbacks, which
/// run on other threads (@Sendable closures cannot change captured vars).
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func with<R>(_ f: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return f(&value)
    }
}

/// Lines of command output, split on \n and \r (progress updates).
struct LineSplitter {
    private(set) var partial = ""

    mutating func feed(_ chunk: String) -> [String] {
        let s = (partial + chunk).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var parts = s.components(separatedBy: "\n")
        partial = parts.removeLast()
        return parts
    }

    mutating func flush() -> [String] {
        defer { partial = "" }
        return partial.isEmpty ? [] : [partial]
    }
}

/// Read what is left in a pipe without blocking: a daemon started by the
/// command (e.g. the adb server) may keep the write end open forever.
func drainNonBlocking(_ handle: FileHandle) -> Data {
    let fd = handle.fileDescriptor
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n > 0 { out.append(buf, count: n) } else { break }
    }
    return out
}

enum Shell {
    /// Run a bash command quietly and return (status, output). For status
    /// checks (adb devices, git log, dependency checks); never for writes.
    static func capture(_ command: String, cwd: URL? = nil, timeout: TimeInterval = 30) async -> (Int32, String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            p.environment = Config.environment
            p.currentDirectoryURL = existingDir(cwd)
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let state = Box((data: Data(), finished: false))
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                state.with { $0.data.append(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = drainNonBlocking(pipe.fileHandleForReading)
                let (done, out): (Bool, String) = state.with { st in
                    st.data.append(rest)
                    let was = st.finished
                    st.finished = true
                    return (was, String(decoding: st.data, as: UTF8.self))
                }
                if !done { cont.resume(returning: (proc.terminationStatus, out)) }
            }
            do {
                try p.run()
            } catch {
                state.with { $0.finished = true }
                cont.resume(returning: (-1, "\(error)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if p.isRunning { p.terminate() }
            }
        }
    }

    static func existingDir(_ url: URL?) -> URL {
        var isDir: ObjCBool = false
        if let u = url, FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
            return u
        }
        if FileManager.default.fileExists(atPath: Config.repo.path, isDirectory: &isDir), isDir.boolValue {
            return Config.repo
        }
        return Config.home
    }

    /// Open a Terminal window running a script (interactive installs).
    static func openInTerminal(_ name: String, _ script: String) {
        let dir = Config.support
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".command")
        let body = "#!/bin/bash\nexport PATH=\(sq(Config.path))\n\(script)\necho\nread -r -p 'Listo. Pulsa Enter para cerrar.' _\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }
}

/// Runs one command at a time and shows its output in the app's panel.
final class Runner: ObservableObject, @unchecked Sendable {
    enum Kind { case out, cmd, info, ok, error }
    struct Line: Identifiable {
        let id: Int
        let text: String
        let kind: Kind
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var running = false
    @Published private(set) var title = ""
    /// false while an administrator command runs (root process: no stop).
    @Published private(set) var canStop = false

    private var nextID = 0
    private var process: Process?
    private var splitter = LineSplitter()
    private let maxLines = 5000

    func log(_ text: String, _ kind: Kind = .info) {
        onMain {
            for t in text.components(separatedBy: "\n") {
                self.lines.append(Line(id: self.nextID, text: t, kind: kind))
                self.nextID += 1
            }
            if self.lines.count > self.maxLines { self.lines.removeFirst(self.lines.count - self.maxLines) }
        }
    }

    func clear() { onMain { self.lines.removeAll() } }

    var text: String { lines.map(\.text).joined(separator: "\n") }

    private func ingest(_ chunk: String) {
        let parts = splitter.feed(chunk)
        if !parts.isEmpty { log(parts.joined(separator: "\n"), .out) }
    }

    private func finishLines() {
        let rest = splitter.flush()
        if !rest.isEmpty { log(rest.joined(separator: "\n"), .out) }
    }

    /// Run a bash command; returns (success, all output). `input` is written
    /// to its stdin (e.g. "ERASE\n" for tools/j7-flash.sh root).
    @discardableResult
    func run(_ title: String, _ command: String, cwd: URL? = nil, input: String? = nil) async -> (ok: Bool, output: String) {
        let started: Bool = await withCheckedContinuation { cont in
            onMain {
                if self.running { cont.resume(returning: false); return }
                self.running = true
                self.canStop = true
                self.title = title
                cont.resume(returning: true)
            }
        }
        guard started else { return (false, "") }
        log("▶ \(title)", .info)
        log("$ \(command)", .cmd)

        let (status, output) = await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", command]
            p.environment = Config.environment
            p.currentDirectoryURL = Shell.existingDir(cwd)
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let inPipe = Pipe()
            p.standardInput = input == nil ? FileHandle.nullDevice : inPipe
            let all = Box(Data())
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                all.with { $0.append(d) }
                let s = String(decoding: d, as: UTF8.self)
                onMain { self.ingest(s) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = drainNonBlocking(pipe.fileHandleForReading)
                let out: String = all.with { a in
                    a.append(rest)
                    return String(decoding: a, as: UTF8.self)
                }
                let s = String(decoding: rest, as: UTF8.self)
                let st = proc.terminationStatus
                onMain {
                    self.ingest(s)
                    self.finishLines()
                    cont.resume(returning: (st, out))
                }
            }
            onMain { self.process = p }
            do {
                try p.run()
            } catch {
                onMain { self.process = nil }
                cont.resume(returning: (-1, "\(error)"))
                return
            }
            if let input = input {
                inPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
        }
        finish(title, status, output)
        return (status == 0, output)
    }

    /// Run a bash command as root through the standard macOS administrator
    /// password dialog. Its output is written to a file that is shown live.
    @discardableResult
    func runAdmin(_ title: String, _ command: String) async -> Bool {
        let started: Bool = await withCheckedContinuation { cont in
            onMain {
                if self.running { cont.resume(returning: false); return }
                self.running = true
                self.canStop = false
                self.title = title
                cont.resume(returning: true)
            }
        }
        guard started else { return false }
        log("▶ \(title) (administrador)", .info)
        log("$ \(command)", .cmd)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("iosgalaxy-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("run.sh")
        let logFile = tmp.appendingPathComponent("out.log")
        let rcFile = tmp.appendingPathComponent("rc")
        let body = """
        #!/bin/bash
        export PATH=\(sq(Config.path))
        export PYTHONUNBUFFERED=1
        cd \(sq(Shell.existingDir(nil).path))
        ( \(command) ) >> \(sq(logFile.path)) 2>&1
        echo $? > \(sq(rcFile.path))
        """
        try? body.write(to: script, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let prompt = "iOS Galaxy necesita permisos de administrador para: \(title)"
            .replacingOccurrences(of: "\"", with: "'")
        let apple = "do shell script \"/bin/bash \" & quoted form of \"\(script.path)\" with prompt \"\(prompt)\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch {
            log("error: \(error)", .error)
            finish(title, -1, "")
            return false
        }
        var offset: UInt64 = 0
        func pump() {
            guard let h = try? FileHandle(forReadingFrom: logFile) else { return }
            defer { try? h.close() }
            h.seek(toFileOffset: offset)
            let d = h.readDataToEndOfFile()
            offset += UInt64(d.count)
            if !d.isEmpty {
                let s = String(decoding: d, as: UTF8.self)
                onMain { self.ingest(s) }
            }
        }
        while p.isRunning {
            pump()
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        pump()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in onMain { self.finishLines(); c.resume() } }
        let rcText = (try? String(contentsOf: rcFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: tmp)
        guard let rc = rcText, let status = Int32(rc) else {
            log("Cancelado (no se dio la contraseña de administrador).", .error)
            finish(title, -2, "")
            return false
        }
        finish(title, status, "")
        return status == 0
    }

    private func finish(_ title: String, _ status: Int32, _ output: String) {
        if status == 0 {
            log("✔ \(title): listo", .ok)
        } else if status != -2 {
            log("✘ \(title): falló (código \(status))", .error)
        }
        onMain {
            self.running = false
            self.canStop = false
            self.process = nil
            self.title = ""
        }
    }

    /// Stop the running command and everything it started.
    func stop() {
        guard let p = process, p.isRunning else { return }
        let pid = p.processIdentifier
        log("■ Deteniendo…", .error)
        Task {
            // children first (pgrep -P, recursively), then the shell
            var pids: [Int32] = []
            var queue: [Int32] = [pid]
            while let cur = queue.popLast() {
                let (_, out) = await Shell.capture("pgrep -P \(cur) || true", timeout: 5)
                for l in out.split(separator: "\n") { if let c = Int32(l.trimmingCharacters(in: .whitespaces)) { pids.append(c); queue.append(c) } }
            }
            for c in pids.reversed() { kill(c, SIGTERM) }
            p.terminate()
        }
    }
}
