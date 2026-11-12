import Foundation

/// Fixed places and names. Everything the app writes outside the repo goes
/// to ~/Documents/iOS Galaxy (backups hold EFS = IMEI: never in git).
enum Config {
    static let repoURL = "https://github.com/my-company-my/ios-galaxy.git"
    static let branch = "claude/exciting-ritchie-47zds5"
    /// The CI publishes the kernel and the app in one release, tag "latest".
    static let releasePage = "https://github.com/my-company-my/ios-galaxy/releases/tag/latest"
    static let releaseDownload = "https://github.com/my-company-my/ios-galaxy/releases/download/latest"
    static let releaseAPI = "https://api.github.com/repos/my-company-my/ios-galaxy/releases/tags/latest"

    static let home = FileManager.default.homeDirectoryForCurrentUser

    /// ~/ios-galaxy, or IOSGALAXY_REPO (CI snapshots use the checkout).
    static var repo: URL {
        if let r = ProcessInfo.processInfo.environment["IOSGALAXY_REPO"], !r.isEmpty {
            return URL(fileURLWithPath: r)
        }
        return home.appendingPathComponent("ios-galaxy")
    }
    static var documents: URL { home.appendingPathComponent("Documents/iOS Galaxy") }
    static var backups: URL { documents.appendingPathComponent("backups") }
    static var logs: URL { documents.appendingPathComponent("logs") }
    /// Heimdall (built by tools/heimdall-build.sh) lives here.
    static var support: URL { home.appendingPathComponent("Library/Application Support/iOS Galaxy") }
    /// The app's own Python (venv with numpy), first in PATH: the repo's
    /// python3 scripts run with it, and nothing else on the Mac changes.
    static var venv: URL { support.appendingPathComponent("venv") }

    static var kernel: URL { repo.appendingPathComponent("xnu/out/kernel.development.sweet") }
    static var stockBoot: URL { repo.appendingPathComponent("dtb/stock-boot.img") }
    static var bootImage: URL { repo.appendingPathComponent("shim/out/shim-boot.img") }
    static var ipswDir: URL { repo.appendingPathComponent("research/ipsw-8") }
    static var adt: URL { ipswDir.appendingPathComponent("d201ap.adt") }

    static func buildDir(_ build: String) -> URL { ipswDir.appendingPathComponent(build) }
    static func rootImage(_ build: String) -> URL { buildDir(build).appendingPathComponent("ios16-root.img") }

    /// A Finder-launched app gets a minimal PATH: add Homebrew (Apple
    /// Silicon and Intel), keg-only LLVM and the app's own bin (Heimdall).
    static var path: String {
        [venv.appendingPathComponent("bin").path,
         support.appendingPathComponent("bin").path,
         "/opt/homebrew/bin", "/opt/homebrew/sbin", "/opt/homebrew/opt/llvm/bin",
         "/usr/local/bin", "/usr/local/sbin", "/usr/local/opt/llvm/bin",
         "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    static var environment: [String: String] {
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = path
        e["PYTHONUNBUFFERED"] = "1"       // progress lines appear as they happen
        e["HOMEBREW_NO_ENV_HINTS"] = "1"
        e["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"   // installs never remove other things (user's choice)
        e["LANG"] = e["LANG"] ?? "en_US.UTF-8"
        return e
    }
}

/// Single-quote a string for bash.
func sq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func stamp(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    return f.string(from: date)
}

func humanSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func fileInfo(_ url: URL) -> (size: Int64, date: Date)? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
    return (size.int64Value, date)
}

func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "es")
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: d)
}

/// Run on the main thread (all @Published state changes go through here).
func onMain(_ f: @escaping () -> Void) {
    if Thread.isMainThread { f() } else { DispatchQueue.main.async(execute: f) }
}
