import AppKit
import Foundation

struct Step {
    let title: String
    let summary: String
    let symbol: String
}

let steps: [Step] = [
    Step(title: "Herramientas", summary: "Revisa e instala lo que el Mac necesita.", symbol: "wrench.and.screwdriver"),
    Step(title: "Repositorio", summary: "Descarga ios-galaxy en ~/ios-galaxy o actualízalo.", symbol: "arrow.down.circle"),
    Step(title: "TWRP", summary: "Escribe TWRP en RECOVERY con Heimdall (Download mode).", symbol: "wrench.adjustable"),
    Step(title: "Respaldo", summary: "Copia las particiones del teléfono antes de cambiar nada.", symbol: "externaldrive.badge.checkmark"),
    Step(title: "Prueba del shim", summary: "Arranca solo el cargador, sin kernel, y mira la pantalla.", symbol: "testtube.2"),
    Step(title: "Kernel", summary: "Descarga el kernel que compiló la CI (release \"latest\").", symbol: "cpu"),
    Step(title: "iOS", summary: "Descarga solo los archivos del iPhone 8 que se usan.", symbol: "iphone"),
    Step(title: "Imagen raíz", summary: "Crea el disco de iOS y escríbelo en USERDATA.", symbol: "internaldrive"),
    Step(title: "Arranque completo", summary: "Crea la imagen boot con el kernel y escríbela en BOOT.", symbol: "power"),
    Step(title: "Logs", summary: "Lee el log del kernel desde TWRP o en vivo por USB.", symbol: "doc.text.magnifyingglass"),
]

/// The word typed to confirm a write (decided with the user: partition name).
enum WriteTarget: String {
    case recovery = "RECOVERY", boot = "BOOT", userdata = "ERASE"
}

struct ConfirmRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let word: String
    let action: @MainActor () async -> Void
}

struct Dependency: Identifiable {
    let id: String
    let name: String
    let detail: String
    /// bash; status 0 = installed
    let check: String
    let formulas: [String]
    let casks: [String]
}

let dependencies: [Dependency] = [
    Dependency(id: "clt", name: "Command Line Tools", detail: "git, clang, make (Apple)",
               check: "xcode-select -p >/dev/null 2>&1", formulas: [], casks: []),
    Dependency(id: "brew", name: "Homebrew", detail: "instala lo demás",
               check: "command -v brew >/dev/null", formulas: [], casks: []),
    Dependency(id: "python", name: "Python 3 (Homebrew)", detail: "scripts de tools/",
               check: "p=$(command -v python3) && case \"$p\" in /opt/homebrew/*|/usr/local/*) true;; *) false;; esac",
               formulas: ["python"], casks: []),
    Dependency(id: "numpy", name: "numpy", detail: "revisión de instrucciones ARMv8.0",
               check: "python3 -c 'import numpy' 2>/dev/null", formulas: ["numpy"], casks: []),
    Dependency(id: "adb", name: "adb", detail: "TWRP: respaldo, escritura, logs",
               check: "command -v adb >/dev/null", formulas: [], casks: ["android-platform-tools"]),
    Dependency(id: "llvm", name: "LLVM + lld", detail: "compila el shim",
               check: "[ -x \"$(brew --prefix llvm 2>/dev/null)/bin/clang\" ] && [ -x \"$(brew --prefix lld 2>/dev/null)/bin/ld.lld\" ]",
               formulas: ["llvm", "lld"], casks: []),
    Dependency(id: "lzfse", name: "lzfse", detail: "DeviceTree del iPhone 8",
               check: "command -v lzfse >/dev/null", formulas: ["lzfse"], casks: []),
    Dependency(id: "rsync", name: "rsync 3", detail: "imagen raíz (enlaces duros, dueños)",
               check: "rsync --version 2>/dev/null | head -1 | grep -q 'version 3'", formulas: ["rsync"], casks: []),
    Dependency(id: "heimdall", name: "Heimdall", detail: "escribe TWRP (se compila: tools/heimdall-build.sh)",
               check: "command -v heimdall >/dev/null", formulas: [], casks: []),
]

struct Firmware: Decodable, Identifiable, Hashable {
    let version: String
    let buildid: String
    let signed: Bool
    let filesize: Int64
    let url: String
    let releasedate: String?
    var id: String { buildid }
}

struct Parts: Decodable {
    let version: String
    let build: String
    let devicetree: String?
    let adt: String?
    let os: String?
    let systemos: String?
    let appos: String?
    var hasImages: Bool { os != nil && systemos != nil && appos != nil }
}

struct Release: Decodable {
    struct Asset: Decodable { let name: String; let size: Int64; let browser_download_url: String }
    let name: String?
    let published_at: String?
    let body: String?
    let assets: [Asset]
}

final class AppState: ObservableObject, @unchecked Sendable {
    @Published var step: Int {
        didSet { UserDefaults.standard.set(step, forKey: "step") }
    }
    @Published private(set) var done: Set<Int>
    @Published var confirm: ConfirmRequest?

    @Published private(set) var depStatus: [String: Bool] = [:]
    @Published private(set) var checkingDeps = false
    @Published private(set) var repoStatus = "…"
    @Published private(set) var repoExists = false
    @Published private(set) var release: Release?
    @Published private(set) var releaseError = ""
    @Published private(set) var firmwares: [Firmware] = []
    @Published private(set) var firmwareError = ""
    /// bumped after any command so file-based status views refresh
    @Published private(set) var fileTick = 0

    let runner = Runner()
    let phone = PhoneMonitor()

    init() {
        step = min(max(UserDefaults.standard.integer(forKey: "step"), 0), steps.count - 1)
        let d = UserDefaults.standard.array(forKey: "done") as? [Int] ?? []
        done = Set(d)
        phone.runner = runner
    }

    func isDone(_ i: Int) -> Bool { done.contains(i) }

    func setDone(_ i: Int, _ value: Bool = true) {
        onMain {
            if value { self.done.insert(i) } else { self.done.remove(i) }
            UserDefaults.standard.set(Array(self.done).sorted(), forKey: "done")
        }
    }

    func refreshFiles() { onMain { self.fileTick += 1 } }

    /// Ask for the typed word, then run the action.
    func requestWrite(_ write: WriteTarget, title: String, message: String, action: @escaping @MainActor () async -> Void) {
        onMain {
            self.confirm = ConfirmRequest(title: title, message: message, word: write.rawValue, action: action)
        }
    }

    // MARK: tools

    var missingDeps: [Dependency] { dependencies.filter { depStatus[$0.id] == false } }

    func checkDeps() {
        onMain { self.checkingDeps = true }
        Task {
            var r: [String: Bool] = [:]
            for d in dependencies {
                let (rc, _) = await Shell.capture(d.check, timeout: 20)
                r[d.id] = rc == 0
            }
            onMain {
                self.depStatus = r
                self.checkingDeps = false
                if dependencies.allSatisfy({ r[$0.id] == true }) { self.setDone(0) }
            }
        }
    }

    /// One `brew install` for every missing formula and cask; Heimdall is
    /// built afterwards when the repo is there (its build script is in it).
    func installMissing() async {
        let missing = missingDeps
        let formulas = missing.flatMap(\.formulas)
        let casks = missing.flatMap(\.casks)
        var cmds: [String] = []
        if !formulas.isEmpty { cmds.append("brew install " + formulas.map(sq).joined(separator: " ")) }
        if !casks.isEmpty { cmds.append("brew install --cask " + casks.map(sq).joined(separator: " ")) }
        if !cmds.isEmpty {
            await runner.run("Instalar con Homebrew", cmds.joined(separator: " && "))
        }
        if missing.contains(where: { $0.id == "heimdall" }) && repoExists {
            await buildHeimdall()
        }
        checkDeps()
    }

    func buildHeimdall() async {
        await runner.run("Compilar Heimdall", "bash tools/heimdall-build.sh \(sq(Config.support.path))", cwd: Config.repo)
        checkDeps()
    }

    func installHomebrew() {
        Shell.openInTerminal("instalar-homebrew",
            "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"")
    }

    func installCLT() {
        Task { await runner.run("Instalar Command Line Tools", "xcode-select --install || true") }
    }

    // MARK: repo

    func checkRepo() {
        Task {
            let exists = FileManager.default.fileExists(atPath: Config.repo.appendingPathComponent(".git").path)
            var status = "No está clonado en \(Config.repo.path)."
            if exists {
                let r = sq(Config.repo.path)
                let (_, branch) = await Shell.capture("git -C \(r) rev-parse --abbrev-ref HEAD")
                let (_, last) = await Shell.capture("git -C \(r) log -1 --format='%h %s (%cr)'")
                let (_, dirty) = await Shell.capture("git -C \(r) status --porcelain | wc -l")
                status = "Rama \(branch.trimmingCharacters(in: .whitespacesAndNewlines)) · último commit: \(last.trimmingCharacters(in: .whitespacesAndNewlines))"
                let n = Int(dirty.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                if n > 0 { status += " · \(n) archivo(s) con cambios locales" }
            }
            onMain {
                self.repoExists = exists
                self.repoStatus = status
                if exists { self.setDone(1) }
            }
        }
    }

    func cloneOrPull() async {
        if repoExists {
            await runner.run("Actualizar el repositorio", "git -C \(sq(Config.repo.path)) pull --ff-only", cwd: Config.home)
        } else {
            await runner.run("Clonar el repositorio",
                "git clone --branch \(sq(Config.branch)) --single-branch \(sq(Config.repoURL)) \(sq(Config.repo.path))",
                cwd: Config.home)
        }
        checkRepo()
    }

    // MARK: kernel release

    func loadRelease() {
        Task {
            guard let url = URL(string: Config.releaseAPI) else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    onMain { self.release = nil; self.releaseError = "GitHub respondió \(code) (¿aún no hay release \"latest\"?)" }
                    return
                }
                let r = try JSONDecoder().decode(Release.self, from: data)
                onMain { self.release = r; self.releaseError = "" }
            } catch {
                onMain { self.release = nil; self.releaseError = error.localizedDescription }
            }
        }
    }

    // MARK: iOS

    func loadFirmwares() async {
        let (rc, out) = await Shell.capture("python3 tools/ipsw-fetch.py list --json", cwd: Config.repo, timeout: 60)
        guard rc == 0, let data = out.data(using: .utf8),
              let list = try? JSONDecoder().decode([Firmware].self, from: data) else {
            onMain { self.firmwareError = out.trimmingCharacters(in: .whitespacesAndNewlines) }
            return
        }
        onMain { self.firmwares = list; self.firmwareError = "" }
    }

    func parts(_ build: String) -> Parts? {
        let url = Config.buildDir(build).appendingPathComponent("parts.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Parts.self, from: data)
    }
}
