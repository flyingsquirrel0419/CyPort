// cyport-steam: sign in to Steam and download Cyberpunk 2077 for Mac (Apple Silicon / arm64) from the account that
// owns it, so build.sh can make the iPhone/iPad app without a GOG copy on the Mac.
//
//   tools/steam_download.sh --user <steam account> [--out <folder>] [--all]
//
// Uses the same Steam client as the app (shim/StoresCore.swift): sign-in with Steam Guard (email code, Steam app code
// or approval in the Steam app), the Mac depots of app 1091500, chunk download + decryption + checks, resume.
// By default only Cyberpunk2077.app is downloaded (what build.sh needs, a few hundred MB); --all also downloads the
// game data (archive, engine, r6: ~65 GB) to copy to the device yourself. Files are kept exactly as Steam ships them.
// Messages go to stderr; the one line on stdout is the path of the downloaded Cyberpunk2077.app.
import Foundation

func say(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
func fail(_ s: String) -> Never { say("error: " + s); exit(1) }

struct Options {
    var user: String?
    var out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("steam-game")
    var scope: GameFiles.Scope = .program
    var signOut = false
    var credentials = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cyport/steam-credentials.json")

    static let usage = """
    usage: cyport-steam --user <steam account> [--out <folder>] [--all] [--credentials <file>]
           cyport-steam --sign-out
      --user         Steam account name (the one that owns Cyberpunk 2077). Not needed again once signed in.
      --out          download folder (default ./steam-game); Cyberpunk2077.app ends up in it. Re-running resumes.
      --all          also download the game data (archive, engine, r6, ~65 GB), not only Cyberpunk2077.app
      --credentials  where the Steam sign-in token is kept (default ~/.cyport/steam-credentials.json, mode 0600)
      --sign-out     forget the saved Steam sign-in
    Environment: STEAM_PASSWORD (else asked for), STEAM_GUARD_CODE (else asked for when Steam wants one),
                 CYPORT_VERBOSE=1 (the store log).
    """

    static func parse(_ a: [String]) -> Options {
        var o = Options(), i = 0
        func value() -> String { i += 1; guard i < a.count else { fail("\(a[i - 1]) needs a value\n" + usage) }; return a[i] }
        while i < a.count {
            switch a[i] {
            case "--user", "-u": o.user = value()
            case "--out", "-o": o.out = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
            case "--all": o.scope = .all
            case "--credentials": o.credentials = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
            case "--sign-out": o.signOut = true
            case "-h", "--help": print(usage); exit(0)
            default: fail("unknown option \(a[i])\n" + usage)
            }
            i += 1
        }
        return o
    }
}

func ask(_ prompt: String) -> String {
    FileHandle.standardError.write(Data(prompt.utf8))
    guard let l = readLine() else { fail("no input (run it in a terminal, or set STEAM_PASSWORD / STEAM_GUARD_CODE)") }
    return l.trimmingCharacters(in: .whitespacesAndNewlines)
}
func askSecret(_ prompt: String) -> String {
    guard let p = getpass(prompt) else { fail("couldn't read the password") }
    return String(cString: p)
}

// MARK: - sign-in

func signIn(_ steam: SteamStore, user: String) async throws {
    let password = ProcessInfo.processInfo.environment["STEAM_PASSWORD"] ?? askSecret("Steam password for \(user): ")
    guard !password.isEmpty else { fail("no password") }
    let p = try await steam.beginLogin(account: user, password: password)
    var envCode = ProcessInfo.processInfo.environment["STEAM_GUARD_CODE"]
    var email: String?, deviceCode = false, deviceConfirm = false
    for g in p.guards {
        switch g {
        case .emailCode(let a): email = a
        case .deviceCode: deviceCode = true
        case .deviceConfirmation: deviceConfirm = true
        case .none: break
        }
    }
    // a code, when Steam wants one (wrong codes: ask again, a few times)
    if email != nil || deviceCode {
        for attempt in 0..<3 {
            let code: String
            if let c = envCode, attempt == 0 { code = c; envCode = nil }
            else if let e = email { code = ask("Steam Guard code (sent to \(e)): ") }
            else if deviceConfirm { code = ask("Steam Guard code from the Steam app (or approve the sign-in in the app, then press Return): ") }
            else { code = ask("Steam Guard code from the Steam app: ") }
            if code.isEmpty && deviceConfirm && email == nil { break }
            do { try await steam.submitCode(p, code: code, email: email != nil); break }
            catch let e as SteamResult where [63, 65, 88].contains(e.code) && attempt < 2 { say(e.localizedDescription) }
        }
    } else if deviceConfirm {
        say("Approve this sign-in in the Steam app on your phone…")
    }
    let deadline = Date().addingTimeInterval(300)
    while Date() < deadline {
        if try await steam.poll(p) { say("Signed in to Steam as \(steam.account ?? user)."); return }
        try await Task.sleep(nanoseconds: UInt64(max(1, p.interval) * 1e9))
    }
    fail("Steam sign-in wasn't confirmed within 5 minutes")
}

// MARK: - after the download: links, permissions, arm64

func machoKind(_ u: URL) -> UInt32? {
    guard let h = try? FileHandle(forReadingFrom: u) else { return nil }
    defer { try? h.close() }
    guard let d = try? h.read(upToCount: 4), d.count == 4 else { return nil }
    let m = d.u32(0)
    return [0xFEEDFACF, 0xFEEDFACE, 0xBEBAFECA, 0xBFBAFECA].contains(m) ? m : nil   // 64/32-bit, fat (as read LE)
}
/// the CPU types in a Mach-O (thin or fat)
func cpuTypes(_ u: URL) -> [UInt32] {
    guard let d = try? Data(contentsOf: u, options: .alwaysMapped), d.count >= 8 else { return [] }
    let m = d.u32(0)
    if m == 0xFEEDFACF || m == 0xFEEDFACE { return [d.u32(4)] }
    guard m == 0xBEBAFECA || m == 0xBFBAFECA else { return [] }               // CAFEBABE / CAFEBABF, big-endian
    func be(_ at: Int) -> UInt32 { UInt32(bigEndian: d.u32(at)) }
    let n = Int(be(4)), step = m == 0xBFBAFECA ? 32 : 20
    return (0..<n).compactMap { i in 8 + i * step + 4 <= d.count ? be(8 + i * step) : nil }
}
let cpuARM64: UInt32 = 0x0100000C

func finish(app: URL, links: [String: String], dest: URL) throws {
    let fm = FileManager.default
    // symbolic links (framework bundles): only ones that stay inside the download
    for (rel, target) in links.sorted(by: { $0.key < $1.key }) {
        let at = dest.appendingPathComponent(rel)
        let resolved = at.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
        guard resolved.hasPrefix(dest.standardizedFileURL.path + "/") else { say("  skipped link \(rel) -> \(target) (points outside)"); continue }
        try fm.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: at)
        try fm.createSymbolicLink(atPath: at.path, withDestinationPath: target)
    }
    // the store doesn't carry the executable bit: every Mach-O in the bundle gets 0755
    var machos: [URL] = []
    if let e = fm.enumerator(at: app, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
        for case let u as URL in e {
            let v = try? u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard v?.isRegularFile == true, v?.isSymbolicLink != true, machoKind(u) != nil else { continue }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path); machos.append(u)
        }
    }
    // Apple Silicon: the game must have an arm64 slice. Files stay exactly as Steam ships them: the shim recognises
    // the game program by its md5 (kMSGames in shim/MacShim.m), and ios_retarget.py takes the arm64 slice of a
    // universal file itself.
    let exe = app.appendingPathComponent("Contents/MacOS/Cyberpunk2077")
    guard cpuTypes(exe).contains(cpuARM64) else { throw StoreError("The Steam download's Cyberpunk2077 has no arm64 (Apple Silicon) code.") }
    for u in machos where !cpuTypes(u).contains(cpuARM64) { say("  note: \(u.lastPathComponent) has no arm64 code") }
    say("  Cyberpunk2077: arm64 Mach-O, \(machos.count) executables/libraries in the bundle")
}

// MARK: - main

@main
struct CyPortSteam {
    static func main() async {
        let o = Options.parse(Array(CommandLine.arguments.dropFirst()))
        Keychain.fileURL = o.credentials
        let steam = SteamStore.shared
        if o.signOut { steam.signOut(); say("Steam sign-in removed (\(o.credentials.path))."); exit(0) }
        do {
            // sign in when there is no saved token, it belongs to another account, or Steam no longer takes it
            var needSignIn = !steam.signedIn
            if let u = o.user, let have = steam.account, u.caseInsensitiveCompare(have) != .orderedSame { needSignIn = true }
            if !needSignIn {
                do { try await steam.logOn(); say("Signed in to Steam as \(steam.account ?? "?") (saved sign-in).") }
                catch { say("Saved Steam sign-in didn't work (\(error.localizedDescription))."); needSignIn = true }
            }
            if needSignIn {
                guard let user = o.user ?? (steam.account) else { fail("not signed in to Steam: pass --user <steam account>") }
                try await signIn(steam, user: user)
            }

            say("Looking up Cyberpunk 2077 for Mac on Steam…")
            let plan = try await steam.plan(scope: o.scope) { say("  " + $0) }
            let dl = Downloader(plan: plan, dest: o.out)
            let left = dl.remainingBytes()
            if let free = try? o.out.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
               free > 0, free < left + 1_000_000_000 {
                fail(String(format: "not enough free space: %.1f GB needed, %.1f GB free", Double(left) / 1e9, Double(free) / 1e9))
            }
            say(String(format: "%@: %d files, %.2f GB (%.2f GB still to download) -> %@", plan.versionName, plan.files.count,
                       Double(plan.totalBytes) / 1e9, Double(left) / 1e9, o.out.path))
            let tty = isatty(2) != 0
            var lastLine = Date.distantPast
            try await dl.run { p in
                let pct = p.total > 0 ? Double(p.done) * 100 / Double(p.total) : 100
                let line = String(format: "  %5.1f%%  %.2f / %.2f GB  %.1f MB/s  %@", pct, Double(p.done) / 1e9, Double(p.total) / 1e9,
                                  p.bytesPerSecond / 1e6, p.secondsLeft > 0 ? "\(Int(p.secondsLeft) / 60) min left" : "")
                if tty { FileHandle.standardError.write(Data(("\r" + line + "   ").utf8)) }
                else if Date().timeIntervalSince(lastLine) > 10 { say(line); lastLine = Date() }
            }
            if tty { say("") }

            let appName = plan.files.first { $0.path.lowercased().hasPrefix(GameFiles.appBundle + "/") }.map { String($0.path.prefix(GameFiles.appBundle.count)) } ?? "Cyberpunk2077.app"
            let app = o.out.appendingPathComponent(appName)
            try finish(app: app, links: plan.links, dest: o.out)
            say("Done: \(app.path)")
            print(app.path)
        } catch {
            fail(error.localizedDescription)
        }
        exit(0)
    }
}
