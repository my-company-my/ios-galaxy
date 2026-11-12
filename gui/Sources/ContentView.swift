import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var runner: Runner
    @EnvironmentObject var phone: PhoneMonitor

    var body: some View {
        VStack(spacing: 0) {
            StepBar()
            Divider()
            VSplitView {
                StepPage()
                    .frame(minHeight: 300)
                OutputPanel()
                    .frame(minHeight: 140, idealHeight: 220)
            }
            Divider()
            Footer()
        }
        .frame(minWidth: 900, minHeight: 640)
        .sheet(item: $state.confirm) { req in
            ConfirmSheet(request: req)
        }
        .onAppear {
            phone.start()
            state.checkDeps()
            state.checkRepo()
        }
    }
}

/// Numbered steps; click any of them (free navigation), done ones show ✓.
struct StepBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var phone: PhoneMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(steps.indices, id: \.self) { i in
                    Button {
                        state.step = i
                    } label: {
                        VStack(spacing: 3) {
                            ZStack {
                                Circle()
                                    .fill(i == state.step ? Color.accentColor : (state.isDone(i) ? Color.green.opacity(0.85) : Color.secondary.opacity(0.25)))
                                    .frame(width: 26, height: 26)
                                if state.isDone(i) && i != state.step {
                                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                } else {
                                    Text("\(i)").font(.system(size: 12, weight: .semibold)).foregroundColor(i == state.step ? .white : .primary)
                                }
                            }
                            Text(steps[i].title)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .foregroundColor(i == state.step ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(i). \(steps[i].title): \(steps[i].summary)")
                }
            }
            HStack(spacing: 10) {
                PhoneBadge()
                Divider().frame(height: 16)
                RestartBar()
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct PhoneBadge: View {
    @EnvironmentObject var phone: PhoneMonitor

    var body: some View {
        HStack(spacing: 10) {
            Label {
                Text(phone.download ? "Teléfono: Download mode" : "Teléfono: \(phone.adb.label)")
            } icon: {
                Circle().fill(phone.download ? Color.green : color).frame(width: 9, height: 9)
            }
            .help(help)
        }
        .font(.callout)
    }

    var help: String {
        switch phone.adb {
        case .unauthorized:
            return "En el teléfono, acepta \"Permitir depuración USB\" para este Mac."
        case .none:
            return phone.heimdallInstalled ? "adb no ve el teléfono y no está en Download mode." : "adb no ve el teléfono. (Download mode se detecta con Heimdall: paso 0.)"
        default:
            return phone.adb.label
        }
    }

    var color: Color {
        switch phone.adb {
        case .recovery: return .green
        case .android, .sideload: return .yellow
        case .unauthorized, .offline, .other: return .orange
        case .none, .noTool: return Color.secondary.opacity(0.5)
        }
    }
}

struct StepPage: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: steps[state.step].symbol).font(.title2).foregroundColor(.accentColor)
                    Text("\(state.step). \(steps[state.step].title)").font(.title2.bold())
                    if state.isDone(state.step) {
                        Label("hecho", systemImage: "checkmark.circle.fill").foregroundColor(.green).font(.callout)
                    }
                }
                Text(steps[state.step].summary).foregroundColor(.secondary)
                Divider()
                stepView
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder var stepView: some View {
        switch state.step {
        case 0: ToolsStep()
        case 1: RepoStep()
        case 2: TWRPStep()
        case 3: BackupStep()
        case 4: ShimTestStep()
        case 5: KernelStep()
        case 6: IOSStep()
        case 7: RootStep()
        case 8: FullBootStep()
        default: LogsStep()
        }
    }
}

struct OutputPanel: View {
    @EnvironmentObject var runner: Runner

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if runner.running {
                    ProgressView().controlSize(.small)
                    Text(runner.title).font(.callout).lineLimit(1)
                } else {
                    Text("Salida").font(.callout).foregroundColor(.secondary)
                }
                Spacer()
                if runner.running {
                    Button("Detener") { runner.stop() }
                        .disabled(!runner.canStop)
                        .help(runner.canStop ? "Detiene el comando" : "Un comando de administrador no se puede detener desde aquí")
                }
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(runner.text, forType: .string)
                }
                Button("Guardar…") { save() }
                Button("Limpiar") { runner.clear() }.disabled(runner.running)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(runner.lines) { line in
                            Text(verbatim: line.text.isEmpty ? " " : line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(8)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: runner.lines.last?.id) { last in
                    if let last = last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    func color(_ k: Runner.Kind) -> Color {
        switch k {
        case .out: return .primary
        case .cmd: return .secondary
        case .info: return .accentColor
        case .ok: return .green
        case .error: return .red
        }
    }

    func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "salida-\(stamp()).txt"
        panel.directoryURL = Config.logs
        try? FileManager.default.createDirectory(at: Config.logs, withIntermediateDirectories: true)
        if panel.runModal() == .OK, let url = panel.url {
            try? runner.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct Footer: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            Button {
                state.step -= 1
            } label: {
                Label("Atrás", systemImage: "chevron.left")
            }
            .disabled(state.step == 0)
            Spacer()
            Toggle("Paso hecho", isOn: Binding(get: { state.isDone(state.step) }, set: { state.setDone(state.step, $0) }))
                .toggleStyle(.checkbox)
            Spacer()
            Button {
                state.step += 1
            } label: {
                Label("Siguiente", systemImage: "chevron.right")
            }
            .disabled(state.step == steps.count - 1)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// Restarts that need no power button: adb (Android with USB debugging,
/// or TWRP) and, from Download mode, `heimdall print-pit` (only reads the
/// partition table, then Heimdall restarts the phone).
struct RestartBar: View {
    @EnvironmentObject var phone: PhoneMonitor
    @EnvironmentObject var runner: Runner

    var body: some View {
        let adb = phone.adb == .recovery || phone.adb == .android
        HStack(spacing: 6) {
            Text("Reiniciar en:").font(.callout).foregroundColor(.secondary)
            Act(title: "TWRP", symbol: "wrench.adjustable", enabled: adb) {
                await runner.run("Reiniciar en TWRP (adb)", "adb reboot recovery")
            }
            Act(title: "Download", symbol: "arrow.down.to.line", enabled: adb) {
                await runner.run("Reiniciar en Download mode (adb)", "adb reboot download")
            }
            Act(title: "Android", symbol: "iphone.and.arrow.forward", enabled: adb) {
                await runner.run("Reiniciar en Android (adb)", "adb reboot")
            }
            if phone.download {
                Act(title: "Salir de Download", symbol: "arrow.uturn.backward", enabled: true) {
                    await runner.run("Salir de Download mode (heimdall print-pit: solo lee, luego reinicia)",
                        "echo 'Para entrar a TWRP: mantén Vol+ y Home ahora, hasta ver TWRP.'; sleep 3; heimdall print-pit 2>&1 | tail -n 4")
                }
            }
        }
        .controlSize(.small)
        .help(adb ? "Reinicia con adb: no hace falta el botón de encendido." :
              "adb necesita el teléfono en Android con depuración USB (aceptada en el teléfono) o en TWRP.")
    }
}

/// Typed confirmation for every write to the phone (RECOVERY, BOOT, ERASE).
struct ConfirmSheet: View {
    @EnvironmentObject var state: AppState
    let request: ConfirmRequest
    @State var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.title, systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold())
                .foregroundColor(.orange)
            Text(request.message).fixedSize(horizontal: false, vertical: true)
            Text("Escribe **\(request.word)** para continuar:")
            TextField(request.word, text: $typed)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit { if typed == request.word { go() } }
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { state.confirm = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Escribir") { go() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(typed != request.word)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    func go() {
        let action = request.action
        state.confirm = nil
        Task { await action() }
    }
}
