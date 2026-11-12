import Foundation

/// `"iOS Galaxy" --selftest`: checks the logic the UI depends on, without a
/// window (CI runs it on macOS). Exit status 0 = all passed.
enum SelfTest {
    static func run() -> Int32 {
        var fails = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok    " : "FAIL  ") + what)
            if !ok { fails += 1 }
        }

        // adb devices
        check(AdbState.parse("List of devices attached\n0123456789ABCDEF\trecovery\n\n") == .recovery, "adb: recovery")
        check(AdbState.parse("List of devices attached\nR58M123\tdevice\n") == .android, "adb: Android")
        check(AdbState.parse("* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList of devices attached\n\n") == .none,
              "adb: no phone (daemon start lines ignored)")
        check(AdbState.parse("List of devices attached\nX\tunauthorized\n") == .unauthorized, "adb: unauthorized")
        check(AdbState.parse("List of devices attached\nX\tno permissions (user in plugdev group)\n") == .other("no permissions (user in plugdev group)"),
              "adb: other state kept as text")

        // bash quoting: round trip through a real bash
        let weird = "a b'c\"d$e`f\\g!h *"
        check(sq("a'b") == "'a'\\''b'", "sq: single quote")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "printf %s " + sq(weird)]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        check(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) == weird, "sq: round trip through bash")

        // output lines
        var ls = LineSplitter()
        let a = ls.feed("one\ntw")
        let b = ls.feed("o\r50%\r100%\r\nend")
        let c = ls.flush()
        check(a == ["one"] && b == ["two", "50%", "100%"] && c == ["end"], "line splitter: \\n, \\r, partial line")

        // JSON from tools/ipsw-fetch.py, parts.json and the GitHub release API
        let fw = #"[{"version": "16.7.16", "buildid": "20H392", "signed": true, "filesize": 6035280776, "url": "https://x/y.ipsw", "releasedate": null}]"#
        let fws = try? JSONDecoder().decode([Firmware].self, from: Data(fw.utf8))
        check(fws?.first?.buildid == "20H392" && fws?.first?.signed == true, "ipsw-fetch.py list --json decodes")
        let parts = #"{"version": "16.7.16", "build": "20H392", "url": "u", "board": "d201ap", "devicetree": "/d", "adt": "/a", "os": "/o", "systemos": "/s", "appos": "/p"}"#
        check((try? JSONDecoder().decode(Parts.self, from: Data(parts.utf8)))?.hasImages == true, "parts.json decodes (all images)")
        let dtOnly = #"{"version": "16.7.16", "build": "20H392", "url": "u", "board": "d201ap", "devicetree": "/d", "adt": "/a"}"#
        check((try? JSONDecoder().decode(Parts.self, from: Data(dtOnly.utf8)))?.hasImages == false, "parts.json decodes (DeviceTree only)")
        let rel = #"{"name": "latest", "published_at": "2026-11-12T00:07:30Z", "body": "run 1", "assets": [{"name": "kernel.development.sweet", "size": 17072832, "browser_download_url": "https://x"}], "extra": 1}"#
        check((try? JSONDecoder().decode(Release.self, from: Data(rel.utf8)))?.assets.first?.size == 17072832, "release JSON decodes")

        // decisions
        check(steps.count == 10, "10 wizard steps")
        check(WriteTarget.recovery.rawValue == "RECOVERY" && WriteTarget.boot.rawValue == "BOOT" && WriteTarget.userdata.rawValue == "ERASE",
              "typed words: RECOVERY, BOOT, ERASE")
        check(Config.path.hasPrefix(Config.support.appendingPathComponent("bin").path) && Config.path.contains("/opt/homebrew/bin"),
              "PATH: app bin (Heimdall) and Homebrew")

        // Shell.capture: status, merged stderr, a background child that keeps
        // the pipe open (like the adb server), timeout
        func capture(_ cmd: String, timeout: TimeInterval = 30) -> (Int32, String) {
            let box = Box<(Int32, String)?>(nil)
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let r = await Shell.capture(cmd, timeout: timeout)
                box.with { $0 = r }
                sem.signal()
            }
            sem.wait()
            return box.with { $0 }!
        }
        let (rc1, o1) = capture("echo out; echo err >&2; exit 4")
        check(rc1 == 4 && o1.contains("out") && o1.contains("err"), "capture: exit status and stderr")
        var t0 = Date()
        let (rc2, o2) = capture("(sleep 20 &); echo started")
        check(rc2 == 0 && o2.contains("started") && Date().timeIntervalSince(t0) < 5, "capture: returns while a child keeps the pipe open")
        t0 = Date()
        let (_, _) = capture("sleep 20", timeout: 1)
        check(Date().timeIntervalSince(t0) < 5, "capture: timeout stops the command")

        // Runner: streams output, stdin (the ERASE answer), failure status, stop
        let runner = Runner()
        func runOnRunner(_ start: @escaping @Sendable () async -> (Bool, String), stopAfter: TimeInterval? = nil) -> (Bool, String) {
            let box = Box<(Bool, String)?>(nil)
            Task.detached {
                let r = await start()
                box.with { $0 = r }
            }
            let begin = Date()
            var stopped = false
            while box.with({ $0 }) == nil && Date().timeIntervalSince(begin) < 60 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                if let s = stopAfter, !stopped, Date().timeIntervalSince(begin) > s, runner.running {
                    runner.stop()
                    stopped = true
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            return box.with { $0 } ?? (false, "timeout")
        }
        let r1 = runOnRunner({ let r = await runner.run("stdin", "read -r a; echo \"got:$a\"; exit 3", input: "ERASE\n"); return (r.ok, r.output) })
        check(!r1.0 && r1.1.contains("got:ERASE"), "runner: stdin answer reaches the script, failure reported")
        check(runner.lines.contains { $0.text.contains("got:ERASE") } && runner.lines.contains { $0.kind == .error && $0.text.contains("código 3") },
              "runner: output and the failure line are in the panel")
        let r2 = runOnRunner({ let r = await runner.run("ok", "printf 'a\\rb\\n'; echo done"); return (r.ok, r.output) })
        check(r2.0 && runner.lines.contains { $0.text == "a" } && runner.lines.contains { $0.text == "b" }, "runner: success, \\r splits lines")
        t0 = Date()
        let r3 = runOnRunner({ let r = await runner.run("stop", "sleep 30; echo never"); return (r.ok, r.output) }, stopAfter: 1)
        check(!r3.0 && !r3.1.contains("never") && Date().timeIntervalSince(t0) < 10 && !runner.running, "runner: Detener stops the command")

        print(fails == 0 ? "PASS" : "\(fails) FAILED")
        return fails == 0 ? 0 : 1
    }
}
