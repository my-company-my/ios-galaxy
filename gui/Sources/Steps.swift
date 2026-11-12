import AppKit
import SwiftUI

// MARK: shared pieces

enum PhoneMode { case twrp, download }

/// Orange box with the keys to press when the phone is not in `mode`.
struct ModeHint: View {
    let mode: PhoneMode
    @EnvironmentObject var phone: PhoneMonitor

    static func ok(_ mode: PhoneMode, _ phone: PhoneMonitor) -> Bool {
        mode == .twrp ? phone.adb == .recovery : phone.download
    }

    var body: some View {
        if !ModeHint.ok(mode, phone) {
            Banner(text: text, symbol: "exclamationmark.triangle.fill", color: .orange)
        }
    }

    var text: String {
        switch mode {
        case .twrp:
            return "Esto necesita el teléfono en TWRP con adb (ahora: \(phone.adb.label)). Con el teléfono apagado, mantén Vol+ + Home + Power hasta ver TWRP y conéctalo al Mac por USB."
        case .download:
            return "Esto necesita el teléfono en Download mode. Apágalo, mantén Vol− + Home + Power y, en la pantalla de advertencia, pulsa Vol+. Conéctalo al Mac por USB."
        }
    }
}

struct Banner: View {
    let text: String
    var symbol = "info.circle.fill"
    var color = Color.accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundColor(color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .cornerRadius(8)
    }
}

struct NeedsRepo: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        if !state.repoExists {
            Banner(text: "Primero clona el repositorio (paso 1): los scripts están ahí.", symbol: "exclamationmark.triangle.fill", color: .orange)
        }
    }
}

/// Exists? size and date of a file; refreshed after every command.
struct FileStatus: View {
    let label: String
    let url: URL
    @EnvironmentObject var state: AppState

    var body: some View {
        let _ = state.fileTick
        if let i = fileInfo(url) {
            Label("\(label): \(humanSize(i.size)), \(shortDate(i.date))", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .help(url.path)
        } else {
            Label("\(label): no existe todavía", systemImage: "circle.dashed")
                .foregroundColor(.secondary)
                .help(url.path)
        }
    }
}

/// A button that runs an async action; disabled while a command runs.
struct Act: View {
    let title: String
    let symbol: String
    var enabled = true
    var prominent = false
    let action: @MainActor () async -> Void
    @EnvironmentObject var runner: Runner

    var body: some View {
        let b = Button {
            Task { await action() }
        } label: {
            Label(title, systemImage: symbol)
        }
        .disabled(runner.running || !enabled)
        if prominent {
            b.buttonStyle(.borderedProminent)
        } else {
            b.buttonStyle(.bordered)
        }
    }
}

struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
        } label: {
            Text(title).font(.headline)
        }
    }
}

func showInFinder(_ url: URL) {
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
}

/// What shim/out/shim-boot.img holds now (shim test or full image).
struct BootImageInfo: View {
    @AppStorage("bootKind") var bootKind = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FileStatus(label: "shim/out/shim-boot.img", url: Config.bootImage)
            if !bootKind.isEmpty && fileInfo(Config.bootImage) != nil {
                Text("Contiene: \(bootKind)").font(.callout).foregroundColor(.secondary)
            }
        }
    }
}

// MARK: 0 tools

struct ToolsStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("La app usa estas herramientas del Mac. Lo que falta se instala con Homebrew; Heimdall se compila desde su código.")
            Panel(title: "Herramientas") {
                ForEach(dependencies) { d in
                    HStack(spacing: 10) {
                        icon(state.depStatus[d.id])
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).bold()
                            Text(d.detail).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        extra(d)
                    }
                }
            }
            HStack {
                Button {
                    state.checkDeps()
                } label: {
                    Label("Revisar de nuevo", systemImage: "arrow.clockwise")
                }
                .disabled(state.checkingDeps)
                Act(title: "Instalar lo que falta", symbol: "shippingbox",
                    enabled: !state.missingDeps.isEmpty && state.depStatus["brew"] == true, prominent: true) {
                    await state.installMissing()
                }
                if state.checkingDeps { ProgressView().controlSize(.small) }
            }
            if state.depStatus["brew"] == false {
                Banner(text: "Homebrew se instala en una ventana de Terminal (pide tu contraseña). Antes instala las Command Line Tools.", color: .orange)
            }
            if state.depStatus["heimdall"] == false && !state.repoExists {
                Banner(text: "Heimdall se compila con tools/heimdall-build.sh del repositorio: haz primero el paso 1 y vuelve aquí.")
            }
        }
        .onAppear { state.checkDeps() }
    }

    @ViewBuilder func icon(_ ok: Bool?) -> some View {
        if let ok = ok {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? .green : .red)
        } else {
            Image(systemName: "questionmark.circle").foregroundColor(.secondary)
        }
    }

    @ViewBuilder func extra(_ d: Dependency) -> some View {
        if state.depStatus[d.id] == false {
            switch d.id {
            case "clt":
                Button("Instalar") { state.installCLT() }.disabled(runner.running)
            case "brew":
                Button("Instalar en Terminal") { state.installHomebrew() }
            case "heimdall":
                Act(title: "Compilar", symbol: "hammer", enabled: state.repoExists && state.depStatus["brew"] == true) {
                    await state.buildHeimdall()
                }
            default:
                EmptyView()
            }
        }
    }
}

// MARK: 1 repo

struct RepoStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel(title: "ios-galaxy") {
                Text(state.repoStatus).textSelection(.enabled)
                Text("Origen: \(Config.repoURL) (rama \(Config.branch))").font(.caption).foregroundColor(.secondary)
                HStack {
                    Act(title: state.repoExists ? "Actualizar (git pull)" : "Clonar en \(Config.repo.path)",
                        symbol: state.repoExists ? "arrow.triangle.2.circlepath" : "arrow.down.circle",
                        enabled: state.depStatus["clt"] != false, prominent: true) {
                        await state.cloneOrPull()
                    }
                    Button("Mostrar en Finder") { showInFinder(Config.repo) }.disabled(!state.repoExists)
                }
            }
            if state.depStatus["clt"] == false {
                Banner(text: "git viene con las Command Line Tools (paso 0).", color: .orange)
            }
        }
        .onAppear { state.checkRepo() }
    }
}

// MARK: 2 TWRP

struct TWRPStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner
    @AppStorage("twrpPath") var twrpPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Panel(title: "1. Prepara el teléfono") {
                Text("• En Android: Ajustes › Opciones de desarrollador › Desbloqueo OEM activado.")
                Text("• Apaga el teléfono. Mantén Vol− + Home + Power; en la advertencia pulsa Vol+ (Download mode). En Download mode debe decir \"OEM LOCK: OFF\".")
                Text("• Conéctalo al Mac por USB. Arriba aparece \"Download mode detectado\".")
            }
            Panel(title: "2. Imagen de TWRP") {
                HStack {
                    Text(twrpPath.isEmpty ? "Ninguna elegida" : twrpPath)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundColor(twrpPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Elegir…") { pick() }
                }
                Text("No hay TWRP oficial para el J7 Neo (j7velte) en twrp.me: usa una imagen hecha para el SM-J701 (.img, o .tar / .tar.md5 con recovery.img dentro).")
                    .font(.caption).foregroundColor(.secondary)
            }
            if !phone.heimdallInstalled {
                Banner(text: "Falta Heimdall: compílalo en el paso 0.", symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            ModeHint(mode: .download)
            Act(title: "Escribir TWRP en RECOVERY", symbol: "square.and.arrow.down.on.square",
                enabled: phone.heimdallInstalled && phone.download && FileManager.default.fileExists(atPath: twrpPath),
                prominent: true) {
                state.requestWrite(.recovery, title: "Escribir la partición RECOVERY",
                    message: "Heimdall reemplaza la recuperación del teléfono por \((twrpPath as NSString).lastPathComponent). Android y tus datos no se tocan.") {
                    await flash()
                }
            }
            Panel(title: "3. Después") {
                Text("Heimdall no reinicia el teléfono. Mantén Vol− + Power hasta que se apague la pantalla y en ese momento cambia a Vol+ + Home + Power: así entra a TWRP. Si Android arranca antes, puede volver a poner la recuperación original y hay que repetir.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { phone.watchDownload = true; phone.poll() }
        .onDisappear { phone.watchDownload = false }
    }

    func pick() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.canChooseDirectories = false
        p.message = "Elige la imagen de TWRP (.img, .tar o .tar.md5)"
        if p.runModal() == .OK, let u = p.url { twrpPath = u.path }
    }

    func flash() async {
        let f = twrpPath
        let cmd: String
        if f.lowercased().hasSuffix(".img") {
            cmd = "heimdall flash --RECOVERY \(sq(f)) --no-reboot"
        } else {
            cmd = """
            t=$(mktemp -d) && tar -xOf \(sq(f)) recovery.img > "$t/recovery.img" 2>/dev/null; \
            if [ ! -s "$t/recovery.img" ]; then echo no hay recovery.img dentro de \(sq(f)); rm -rf "$t"; exit 1; fi; \
            heimdall flash --RECOVERY "$t/recovery.img" --no-reboot; rc=$?; rm -rf "$t"; exit $rc
            """
        }
        let r = await runner.run("Escribir TWRP en RECOVERY", cmd)
        if r.ok { state.setDone(2) }
    }
}

// MARK: 3 backup

struct BackupStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner

    var body: some View {
        let inTWRP = phone.adb == .recovery
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            Text("Copia BOOT, RECOVERY, EFS (IMEI), PARAM, RADIO… a \(Config.backups.path)/<fecha>. Guarda esa carpeta: es la única forma de volver atrás. Su BOOT.img se copia como dtb/stock-boot.img, que el shim necesita.")
                .fixedSize(horizontal: false, vertical: true)
            ModeHint(mode: .twrp)
            HStack {
                Act(title: "Respaldar ahora", symbol: "externaldrive.badge.plus", enabled: inTWRP && state.repoExists, prominent: true) {
                    await backup()
                }
                Act(title: "Ver particiones", symbol: "list.bullet.rectangle", enabled: inTWRP && state.repoExists) {
                    await runner.run("Particiones", "sh tools/j7-flash.sh info")
                }
            }
            FileStatus(label: "dtb/stock-boot.img", url: Config.stockBoot)
            Panel(title: "Respaldos") {
                let list = backups()
                if list.isEmpty {
                    Text("Ninguno todavía.").foregroundColor(.secondary)
                }
                ForEach(list, id: \.self) { dir in
                    HStack {
                        Image(systemName: "folder")
                        Text(dir.lastPathComponent).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button("Finder") { showInFinder(dir) }
                        Act(title: "Usar su BOOT.img como stock", symbol: "doc.on.doc",
                            enabled: state.repoExists && FileManager.default.fileExists(atPath: dir.appendingPathComponent("BOOT.img").path)) {
                            await runner.run("Copiar BOOT.img a dtb/stock-boot.img",
                                "mkdir -p dtb && cp \(sq(dir.appendingPathComponent("BOOT.img").path)) dtb/stock-boot.img")
                        }
                    }
                }
            }
        }
    }

    func backups() -> [URL] {
        let _ = state.fileTick
        let items = (try? FileManager.default.contentsOfDirectory(at: Config.backups, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func backup() async {
        let dir = Config.backups.appendingPathComponent(stamp())
        let boot = dir.appendingPathComponent("BOOT.img")
        let r = await runner.run("Respaldar el teléfono",
            "mkdir -p \(sq(dir.path)) && sh tools/j7-flash.sh backup \(sq(dir.path)) && mkdir -p dtb && cp \(sq(boot.path)) dtb/stock-boot.img && echo 'dtb/stock-boot.img <- BOOT.img'")
        if r.ok { state.setDone(3) }
    }
}

// MARK: 4 shim test

struct ShimTestStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner
    @AppStorage("bootKind") var bootKind = ""

    var body: some View {
        let hasStock = fileInfo(Config.stockBoot) != nil
        let hasImage = fileInfo(Config.bootImage) != nil
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            Text("Primero solo el shim, con un ramdisk vacío: no usa el kernel. Comprueba que S-BOOT arranca el shim y que el shim ve la CPU y el ramdisk.")
                .fixedSize(horizontal: false, vertical: true)
            if !hasStock {
                Banner(text: "Falta dtb/stock-boot.img: haz el respaldo (paso 3).", symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            Act(title: "Construir imagen de prueba", symbol: "hammer", enabled: hasStock && state.repoExists, prominent: true) {
                let r = await runner.run("Construir el shim (ramdisk vacío)", "bash shim/build.sh")
                if r.ok { bootKind = "prueba del shim, ramdisk vacío (\(shortDate(Date())))" }
            }
            BootImageInfo()
            ModeHint(mode: .twrp)
            HStack {
                Act(title: "Escribir en BOOT", symbol: "square.and.arrow.down.on.square",
                    enabled: hasImage && phone.adb == .recovery, prominent: true) {
                    state.requestWrite(.boot, title: "Escribir la partición BOOT",
                        message: "Se reemplaza el arranque de Android por la imagen de prueba del shim. Android no arranca hasta que escribas de nuevo tu BOOT.img del respaldo.") {
                        await runner.run("Escribir BOOT", "sh tools/j7-flash.sh boot shim/out/shim-boot.img")
                    }
                }
                Act(title: "Reiniciar el teléfono", symbol: "arrow.clockwise.circle", enabled: phone.adb == .recovery) {
                    await runner.run("Reiniciar", "adb reboot")
                }
            }
            Panel(title: "Qué mirar en la pantalla") {
                Text("• La línea de CPU: debe decir Cortex-A53 y el nivel de excepción (EL).")
                Text("• La línea INITRD. Si dice \"INITRD none in /chosen\", S-BOOT no pasó el ramdisk: en el paso 8 activa \"payload dentro del kernel\".")
                Text("• Para volver a TWRP: mantén Vol− + Power hasta que se apague y cambia a Vol+ + Home + Power.")
                Text("Cuando lo hayas visto, marca \"Paso hecho\" abajo.").foregroundColor(.secondary)
            }
        }
    }
}

// MARK: 5 kernel

struct KernelStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            Panel(title: "Release \"latest\" en GitHub") {
                if let r = state.release {
                    Text(r.name ?? "latest").bold()
                    if let p = r.published_at { Text("Publicada: \(p)").font(.callout) }
                    if let b = r.body, !b.isEmpty {
                        Text(b).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
                    }
                    ForEach(r.assets, id: \.name) { a in
                        Text("• \(a.name) (\(humanSize(a.size)))").font(.system(.callout, design: .monospaced))
                    }
                } else if !state.releaseError.isEmpty {
                    Text(state.releaseError).foregroundColor(.red)
                } else {
                    ProgressView().controlSize(.small)
                }
                HStack {
                    Button("Recargar") { state.loadRelease() }
                    Link("Abrir en el navegador", destination: URL(string: Config.releasePage)!)
                }
            }
            HStack {
                Act(title: "Descargar kernel", symbol: "arrow.down.circle",
                    enabled: state.repoExists && state.release != nil, prominent: true) {
                    let r = await runner.run("Descargar el kernel", download)
                    if r.ok { state.setDone(5) }
                }
                Act(title: "Revisar ARMv8.0", symbol: "checkmark.shield",
                    enabled: state.repoExists && fileInfo(Config.kernel) != nil) {
                    await runner.run("Revisar instrucciones del kernel",
                        "python3 tools/check-armv80.py --strict --min-code-kib 4096 --ignore-symbol K256 xnu/out/kernel.development.sweet")
                }
            }
            FileStatus(label: "xnu/out/kernel.development.sweet", url: Config.kernel)
        }
        .onAppear { state.loadRelease() }
    }

    /// curl, then check the SHA-256 against the release's SHA256SUMS.
    var download: String {
        let base = Config.releaseDownload
        return """
        set -e; mkdir -p xnu/out; cd xnu/out
        curl -fsSL --retry 3 -o kernel.development.sweet.part \(sq(base + "/kernel.development.sweet"))
        curl -fsSL --retry 3 -o SHA256SUMS.release \(sq(base + "/SHA256SUMS"))
        want=$(awk '$2 ~ /kernel\\.development\\.sweet$/ {print $1}' SHA256SUMS.release)
        got=$(shasum -a 256 kernel.development.sweet.part | awk '{print $1}')
        if [ -z "$want" ] || [ "$want" != "$got" ]; then echo "SHA-256 no coincide: $got (esperado: ${want:-ninguno})"; rm -f kernel.development.sweet.part; exit 1; fi
        mv kernel.development.sweet.part kernel.development.sweet
        echo "kernel.development.sweet: $(wc -c < kernel.development.sweet | tr -d ' ') bytes, SHA-256 $got (coincide con la release)"
        """
    }
}

// MARK: 6 iOS

struct IOSStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: Runner
    @AppStorage("build") var build = ""

    var body: some View {
        let parts = { () -> Parts? in let _ = state.fileTick; return build.isEmpty ? nil : state.parts(build) }()
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            Panel(title: "Versión de iOS (iPhone 8, iPhone10,4)") {
                if state.firmwares.isEmpty {
                    if state.firmwareError.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Cargando la lista de ipsw.me…") }
                    } else {
                        Text(state.firmwareError).foregroundColor(.red).textSelection(.enabled)
                    }
                } else {
                    Picker("Versión", selection: $build) {
                        ForEach(state.firmwares) { f in
                            Text("iOS \(f.version) (\(f.buildid))\(f.signed ? " · firmada por Apple" : "")").tag(f.buildid)
                        }
                    }
                    .frame(maxWidth: 420)
                }
                Button("Recargar lista") { Task { await state.loadFirmwares() } }.disabled(!state.repoExists)
                Text("Se descargan solo OS, SystemOS y AppOS (unos 7,4 GB) y el DeviceTree, no el IPSW entero. Si se corta, vuelve a pulsar: continúa donde quedó.")
                    .font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Act(title: "Descargar archivos", symbol: "arrow.down.circle", enabled: !build.isEmpty && state.repoExists, prominent: true) {
                    let r = await runner.run("Descargar iOS \(build)", "python3 tools/ipsw-fetch.py fetch \(sq(build))")
                    if r.ok { state.setDone(6) }
                }
                Act(title: "Solo DeviceTree", symbol: "doc.badge.arrow.up", enabled: !build.isEmpty && state.repoExists) {
                    await runner.run("Descargar el DeviceTree de \(build)", "python3 tools/ipsw-fetch.py fetch \(sq(build)) --devicetree-only")
                }
                Act(title: "Revisar instrucciones del userland", symbol: "checkmark.shield",
                    enabled: parts?.systemos != nil && state.repoExists) {
                    await runner.run("Revisar el shared cache de \(build)", "python3 tools/ipsw-fetch.py check \(sq(build))")
                }
            }
            Panel(title: "Archivos de \(build.isEmpty ? "—" : build)") {
                if let p = parts {
                    if let dt = p.devicetree { FileStatus(label: "DeviceTree D201AP", url: URL(fileURLWithPath: dt)) }
                    if let os = p.os { FileStatus(label: "OS", url: URL(fileURLWithPath: os)) }
                    if let s = p.systemos { FileStatus(label: "Cryptex1,SystemOS", url: URL(fileURLWithPath: s)) }
                    if let a = p.appos { FileStatus(label: "Cryptex1,AppOS", url: URL(fileURLWithPath: a)) }
                    if !p.hasImages { Text("Solo el DeviceTree: faltan las imágenes de disco.").foregroundColor(.secondary) }
                } else {
                    Text("Nada descargado de esta versión.").foregroundColor(.secondary)
                }
                Button("Mostrar en Finder") { showInFinder(Config.buildDir(build)) }.disabled(build.isEmpty)
            }
            FileStatus(label: "research/ipsw-8/d201ap.adt (lo usa la imagen boot; es el último DeviceTree descargado)", url: Config.adt)
            Text("\"Revisar instrucciones\" busca en el código de iOS instrucciones que el Cortex-A53 no tiene: lse y ldapr las emula el kernel; las marcadas NOT EMULATED fallarán si se ejecutan.")
                .font(.caption).foregroundColor(.secondary)
        }
        .onAppear {
            if state.firmwares.isEmpty && state.repoExists { Task { await state.loadFirmwares() } }
        }
        .onChange(of: state.firmwares.count) { _ in
            if build.isEmpty, let first = state.firmwares.first { build = first.buildid }
        }
    }
}

// MARK: 7 root image

struct RootStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner
    @AppStorage("build") var build = ""
    @AppStorage("rootExtra") var extra = "3g"

    var body: some View {
        let parts = { () -> Parts? in let _ = state.fileTick; return build.isEmpty ? nil : state.parts(build) }()
        let out = Config.rootImage(build.isEmpty ? "-" : build)
        let extraOK = extra.range(of: "^[0-9]+[mMgG]$", options: .regularExpression) != nil
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            if parts?.hasImages != true {
                Banner(text: "Faltan las imágenes de iOS \(build): descárgalas en el paso 6.", symbol: "exclamationmark.triangle.fill", color: .orange)
            }
            Panel(title: "1. Crear la imagen (HFS+, sensible a mayúsculas)") {
                HStack {
                    Text("Espacio libre extra:")
                    TextField("3g", text: $extra).frame(width: 80)
                    Text("(formato de hdiutil: 2500m, 3g, 4g)").font(.caption).foregroundColor(.secondary)
                }
                if !extraOK { Text("Usa un número seguido de m o g.").foregroundColor(.red).font(.caption) }
                Text("Monta las imágenes, copia todo como root (pide la contraseña de administrador) y aplica tools/sweet-root-tweaks.py. Tarda varios minutos.")
                    .font(.caption).foregroundColor(.secondary)
                Act(title: "Construir imagen raíz", symbol: "hammer", enabled: parts?.hasImages == true && extraOK && state.repoExists, prominent: true) {
                    guard let p = parts, let os = p.os, let sys = p.systemos, let app = p.appos else { return }
                    let cmd = "bash tools/mkiosroot.sh \(sq(os)) \(sq(sys)) \(sq(app)) \(sq(out.path)) \(sq(extra))"
                    _ = await runner.runAdmin("Construir la imagen raíz de iOS \(build)", cmd)
                }
                FileStatus(label: "Imagen raíz", url: out)
            }
            Panel(title: "2. Escribir en USERDATA") {
                ModeHint(mode: .twrp)
                Act(title: "Escribir en USERDATA", symbol: "square.and.arrow.down.on.square",
                    enabled: fileInfo(out) != nil && phone.adb == .recovery && state.repoExists, prominent: true) {
                    state.requestWrite(.userdata, title: "Borrar USERDATA y escribir iOS",
                        message: "Se borran todos los datos de Android del teléfono (fotos, apps, cuentas) y se escribe la imagen de iOS en USERDATA. Los últimos 8 MiB quedan para el log del kernel. Tarda varios minutos.") {
                        let r = await runner.run("Escribir USERDATA", "sh tools/j7-flash.sh root \(sq(out.path))", input: "ERASE\n")
                        if r.ok { state.setDone(7) }
                    }
                }
            }
        }
    }
}

// MARK: 8 full boot

struct FullBootStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner
    @AppStorage("cpus") var cpus = 1
    @AppStorage("payloadInKernel") var payloadInKernel = false
    @AppStorage("extraArgs") var extraArgs = ""
    @AppStorage("bootKind") var bootKind = ""

    var body: some View {
        let _ = state.fileTick
        let hasKernel = fileInfo(Config.kernel) != nil
        let hasStock = fileInfo(Config.stockBoot) != nil
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            if !hasKernel { Banner(text: "Falta el kernel: descárgalo en el paso 5.", symbol: "exclamationmark.triangle.fill", color: .orange) }
            if !hasStock { Banner(text: "Falta dtb/stock-boot.img: haz el respaldo (paso 3).", symbol: "exclamationmark.triangle.fill", color: .orange) }
            if fileInfo(Config.adt) == nil {
                Banner(text: "Sin research/ipsw-8/d201ap.adt el ADT no tiene /product (identidad de iPhone 8): descarga al menos el DeviceTree en el paso 6.", color: .orange)
            }
            Panel(title: "Opciones") {
                Stepper("Núcleos: \(cpus) (cpus=\(cpus); empieza con 1)", value: $cpus, in: 1...8)
                Toggle("Payload dentro del kernel (si el shim dijo \"INITRD none in /chosen\")", isOn: $payloadInKernel)
                HStack {
                    Text("boot-args extra:")
                    TextField("por ejemplo: sweettouchpoll=1", text: $extraArgs)
                }
            }
            Act(title: "Construir imagen boot", symbol: "hammer", enabled: hasKernel && hasStock && state.repoExists, prominent: true) {
                var cmd = "bash tools/j7-make-boot.sh xnu/out/kernel.development.sweet --cpus \(cpus)"
                if payloadInKernel { cmd += " --payload-in-kernel" }
                let extra = extraArgs.trimmingCharacters(in: .whitespaces)
                if !extra.isEmpty { cmd += " --extra \(sq(extra))" }
                let r = await runner.run("Construir la imagen boot completa", cmd)
                if r.ok {
                    bootKind = "arranque completo, cpus=\(cpus)\(payloadInKernel ? ", payload en el kernel" : "")\(extra.isEmpty ? "" : ", extra: \(extra)") (\(shortDate(Date())))"
                }
            }
            BootImageInfo()
            ModeHint(mode: .twrp)
            HStack {
                Act(title: "Escribir en BOOT", symbol: "square.and.arrow.down.on.square",
                    enabled: fileInfo(Config.bootImage) != nil && phone.adb == .recovery && state.repoExists, prominent: true) {
                    state.requestWrite(.boot, title: "Escribir la partición BOOT",
                        message: "Se escribe en BOOT: \(bootKind.isEmpty ? "shim/out/shim-boot.img" : bootKind). Android no arranca hasta que escribas de nuevo tu BOOT.img del respaldo.") {
                        let r = await runner.run("Escribir BOOT", "sh tools/j7-flash.sh boot shim/out/shim-boot.img")
                        if r.ok && bootKind.hasPrefix("arranque completo") { state.setDone(8) }
                    }
                }
                Act(title: "Reiniciar el teléfono", symbol: "arrow.clockwise.circle", enabled: phone.adb == .recovery) {
                    await runner.run("Reiniciar", "adb reboot")
                }
            }
            Text("Después del arranque vuelve a TWRP (Vol− + Power, luego Vol+ + Home + Power) y lee el log en el paso 9, o míralo en vivo por USB.")
                .font(.callout).foregroundColor(.secondary)
        }
    }
}

// MARK: 9 logs

struct LogsStep: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NeedsRepo()
            Panel(title: "Log guardado en USERDATA (desde TWRP)") {
                Text("El kernel guarda su consola en los últimos 4 MiB de USERDATA. Se lee con el teléfono en TWRP.")
                ModeHint(mode: .twrp)
                HStack {
                    Act(title: "Leer el log", symbol: "doc.text", enabled: phone.adb == .recovery && state.repoExists, prominent: true) {
                        let out = Config.logs.appendingPathComponent("boot-\(stamp()).txt")
                        let r = await runner.run("Leer el log del kernel",
                            "mkdir -p \(sq(Config.logs.path)) && sh tools/sweet-log-pull.sh \(sq(out.path)) && echo && echo '--- últimas 200 líneas de \(out.lastPathComponent):' && tail -n 200 \(sq(out.path))")
                        if r.ok { state.setDone(9) }
                    }
                    Button("Abrir carpeta de logs") {
                        try? FileManager.default.createDirectory(at: Config.logs, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Config.logs)
                    }
                }
            }
            Panel(title: "Log en vivo por USB") {
                Text("Con el kernel de iOS corriendo y el cable conectado, el teléfono aparece como red USB (192.168.7.2). La app espera esa red, le da la dirección 192.168.7.1 (pide la contraseña de administrador) y muestra la consola. Para terminar pulsa Detener en la salida.")
                    .fixedSize(horizontal: false, vertical: true)
                Act(title: "Empezar el log en vivo", symbol: "dot.radiowaves.left.and.right", enabled: state.repoExists, prominent: true) {
                    await live()
                }
            }
        }
    }

    func live() async {
        let w = await runner.run("Esperar la red USB del teléfono", "sh tools/sweet-usbnet.sh --wait")
        guard w.ok else { return }
        let ifname = w.output.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty } ?? ""
        guard ifname.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            runner.log("Nombre de interfaz no válido: \(ifname)", .error)
            return
        }
        let ok = await runner.runAdmin("Dar la dirección 192.168.7.1 a \(ifname)",
            "ifconfig \(sq(ifname)) inet 192.168.7.1 netmask 255.255.255.0 up")
        guard ok else { return }
        let file = Config.logs.appendingPathComponent("live-\(stamp()).txt")
        await runner.run("Log en vivo (udp/5140) → \(file.lastPathComponent)",
            "mkdir -p \(sq(Config.logs.path)) && sh tools/sweet-usbnet.sh --listen \(sq(file.path))")
    }
}
