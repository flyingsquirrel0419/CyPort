// Set up CyPort without a Mac: the app built by GitHub Actions (build.sh NO_GAME=1) has the shim and the starter but no
// game program. This signs in to Steam (StoresCore.swift), downloads the Mac game program (Cyberpunk2077.app, arm64)
// from the account that owns the game, makes it loadable on iOS here on the phone (MachORetarget.swift = what
// tools/ios_retarget.py --game-folder does on a Mac) and writes a new IPA: this app + Games/<version>/.
// iOS only runs code that is signed into an installed app, so that IPA is then installed over this app with SideStore,
// LiveContainer, AltStore or TrollStore (they sign it). Same bundle ID: Documents (game data, saves) and sign-ins stay.
// No UIKit here (InstallerUI.swift has the screen).
import Foundation
import zlib

final class GameInstaller: @unchecked Sendable {
    /// work folder (download, Games/<version>/ being built); removed when the IPA is written
    let work: URL
    /// where the IPA goes (Documents: visible in Files -> On My iPhone -> CyPort)
    let outDir: URL

    init(documents: URL) {
        work = documents.appendingPathComponent("CyPort Setup", isDirectory: true)
        outDir = documents
    }

    struct Prepared {
        let plan: DLPlan                 /// only Cyberpunk2077.app
        let links: [String: String]
        let buildName: String            /// "Steam build 12345678"
        let redscriptsSize: Int64, tweakdbSize: Int64
    }
    struct Result { let ipa: URL; let version: String; let size: Int64; let log: [String] }

    // MARK: 1. what to download

    func prepare(progress: @escaping (String) -> Void) async throws -> Prepared {
        // the whole Mac game's file list (for the sizes of the version files the starter picks the game by), then
        // only the program is downloaded (a few hundred MB; the data comes later through the normal download screen)
        let all = try await SteamStore.shared.plan(scope: .all, progress: progress)
        let app = GameFiles.appBundle + "/"
        var p = all
        p.files = all.files.filter { $0.path.lowercased().hasPrefix(app) }
        p.links = all.links.filter { $0.key.lowercased().hasPrefix(app) }
        p.version = all.version + "-program"
        func size(_ rel: String) -> Int64 { all.files.first { $0.path.lowercased() == rel }?.size ?? 0 }
        storeLog("installer: \(all.versionName): program \(p.files.count) files, \(p.totalBytes / 1_000_000) MB")
        return Prepared(plan: p, links: p.links, buildName: all.versionName,
                        redscriptsSize: size("r6/cache/final.redscripts"), tweakdbSize: size("r6/cache/tweakdb.bin"))
    }

    // MARK: 2. download

    var downloadDir: URL { work.appendingPathComponent("steam", isDirectory: true) }
    func downloader(_ p: Prepared) -> Downloader { Downloader(plan: p.plan, dest: downloadDir) }

    // MARK: 3. Games/<version>/ + 4. the IPA

    func build(_ p: Prepared, progress: @escaping (String) -> Void) throws -> Result {
        let fm = FileManager.default
        let app = downloadDir.appendingPathComponent(p.plan.files.first.map { String($0.path.prefix(GameFiles.appBundle.count)) } ?? "Cyberpunk2077.app")
        let exe = app.appendingPathComponent("Contents/MacOS/Cyberpunk2077")
        guard fm.fileExists(atPath: exe.path) else { throw StoreError("The download has no Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077.") }
        let info = (try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let bundleVersion = info["CFBundleVersion"] as? String ?? short
        let version = Self.versionName(short)
        let digits = Game.versionDigits(version)
        let number = digits.isEmpty ? 0 : Double(digits.prefix(1) + "." + digits.dropFirst()) ?? 0

        progress("Checking the game program…")
        let md5 = Hash.md5(try Data(contentsOf: exe, options: .alwaysMapped)).hex
        let games = work.appendingPathComponent("Games", isDirectory: true)
        let g = games.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: games)
        try fm.createDirectory(at: g.appendingPathComponent("Frameworks"), withIntermediateDirectories: true)
        var log: [String] = []
        progress("Converting the game program for iOS…")
        log += try MachORetarget.retarget(src: exe, dst: g.appendingPathComponent("CyberpunkGame.dylib"))
        let libs = (try? fm.contentsOfDirectory(at: app.appendingPathComponent("Contents/Frameworks"), includingPropertiesForKeys: nil)) ?? []
        for l in libs where l.pathExtension == "dylib" {
            progress("Converting \(l.lastPathComponent)…")
            log += try MachORetarget.retarget(src: l, dst: g.appendingPathComponent("Frameworks/\(l.lastPathComponent)")).map { "\(l.lastPathComponent): \($0)" }
        }
        for l in log { storeLog("retarget: \(l)") }
        let plist: [String: Any] = ["version": version, "number": number, "CyPortGameExe": md5, "shortVersion": short, "bundleVersion": bundleVersion,
                                    "redscriptsSize": p.redscriptsSize, "tweakdbSize": p.tweakdbSize, "source": p.buildName]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: g.appendingPathComponent("game.plist"))
        storeLog("installer: Games/\(version): \(short) (\(p.buildName)), md5 \(md5)")

        progress("Writing the app with the game (IPA)…")
        let ipa = outDir.appendingPathComponent("CyPort-\(version).ipa")
        try writeIPA(to: ipa, games: games, short: short, bundleVersion: bundleVersion)
        let size = (try? fm.attributesOfItem(atPath: ipa.path)[.size] as? NSNumber)?.int64Value ?? 0
        try? fm.removeItem(at: work)
        storeLog("installer: \(ipa.lastPathComponent) written (\(size / 1_000_000) MB)")
        return Result(ipa: ipa, version: version, size: size, log: log)
    }

    /// "2.5", "2.5.0" -> "2.5"; "2.3.1" -> "2.31" (CD PROJEKT's numbering, as the GOG builds name it)
    static func versionName(_ short: String) -> String {
        var parts = short.split(separator: ".").map(String.init)
        while parts.count > 2, parts.last == "0" { parts.removeLast() }
        if parts.count > 2 { return parts[0] + "." + parts.dropFirst().joined() }
        return parts.isEmpty ? "unknown" : parts.joined(separator: ".")
    }

    /// Payload/<this app>.app = this app's bundle (without its signature) + Games/<version>/ + the game's version in Info.plist
    func writeIPA(to ipa: URL, games: URL, short: String, bundleVersion: String) throws {
        let fm = FileManager.default
        let bundle = Bundle.main.bundleURL
        let root = "Payload/\(bundle.lastPathComponent)/"
        let tmp = ipa.appendingPathExtension("part")
        let z = try ZipWriter(tmp)
        try z.addDirectory("Payload/"); try z.addDirectory(root)
        let newGames = Set(((try? fm.contentsOfDirectory(atPath: games.path)) ?? []).map { "Games/\($0)" })
        let skip = ["_CodeSignature", "embedded.mobileprovision", "SC_Info"]
        func walk(_ dir: URL, _ rel: String, skipping: (String) -> Bool) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() {
                let r = rel.isEmpty ? name : rel + "/" + name
                if skipping(r) { continue }
                let u = dir.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue { try z.addDirectory(root + r + "/"); try walk(u, r, skipping: skipping) }
                else if r == "Info.plist" { try z.addData(root + r, try infoPlist(u, short: short, bundleVersion: bundleVersion), mode: 0o644) }
                else { try z.addFile(root + r, from: u) }
            }
        }
        try walk(bundle, "") { r in skip.contains(r) || newGames.contains(r) || newGames.contains { r.hasPrefix($0 + "/") } }
        if !fm.fileExists(atPath: bundle.appendingPathComponent("Games").path) { try z.addDirectory(root + "Games/") }
        try walk(games, "Games") { _ in false }
        try z.finish()
        try? fm.removeItem(at: ipa)
        try fm.moveItem(at: tmp, to: ipa)
    }
    private func infoPlist(_ u: URL, short: String, bundleVersion: String) throws -> Data {
        guard var p = try PropertyListSerialization.propertyList(from: Data(contentsOf: u), format: nil) as? [String: Any] else {
            throw StoreError("couldn't read this app's Info.plist")
        }
        p["CFBundleShortVersionString"] = short; p["CFBundleVersion"] = bundleVersion
        return try PropertyListSerialization.data(fromPropertyList: p, format: .binary, options: 0)
    }
}

// MARK: - zip (stored, no compression: the IPA is installed once and deleted)

final class ZipWriter {
    private let h: FileHandle
    private var offset: UInt64 = 0
    private var central = Data()
    private var count = 0
    private var buf = Data()

    init(_ url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        h = try FileHandle(forWritingTo: url); try h.truncate(atOffset: 0)
    }
    private func write(_ d: Data) throws {
        buf.append(d); offset += UInt64(d.count)
        if buf.count >= 4 << 20 { try h.write(contentsOf: buf); buf.removeAll(keepingCapacity: true) }
    }
    private func header(_ name: String, crc: UInt32, size: UInt64, mode: UInt16) throws {
        guard offset < 0xFFFF_FFFF, size < 0xFFFF_FFFF, count < 0xFFFF else { throw StoreError("the IPA would be over 4 GB") }
        let n = Data(name.utf8)
        var l = Data()
        l.appendLE(UInt32(0x04034b50)); l.appendLE(UInt16(10)); l.appendLE(UInt16(0x0800)); l.appendLE(UInt16(0))
        l.appendLE(UInt16(0)); l.appendLE(UInt16(0x21))                                   // 1980-01-01 00:00
        l.appendLE(crc); l.appendLE(UInt32(size)); l.appendLE(UInt32(size)); l.appendLE(UInt16(n.count)); l.appendLE(UInt16(0))
        var c = Data()
        c.appendLE(UInt32(0x02014b50)); c.appendLE(UInt16(0x031e)); c.appendLE(UInt16(10)); c.appendLE(UInt16(0x0800)); c.appendLE(UInt16(0))
        c.appendLE(UInt16(0)); c.appendLE(UInt16(0x21))
        c.appendLE(crc); c.appendLE(UInt32(size)); c.appendLE(UInt32(size)); c.appendLE(UInt16(n.count))
        c.appendLE(UInt16(0)); c.appendLE(UInt16(0)); c.appendLE(UInt16(0)); c.appendLE(UInt16(0))
        let dir = name.hasSuffix("/")
        c.appendLE(UInt32(mode | (dir ? 0o040000 : 0o100000)) << 16 | (dir ? 0x10 : 0)); c.appendLE(UInt32(offset))
        central.append(c); central.append(n); count += 1
        try write(l); try write(n)
    }
    func addDirectory(_ name: String) throws { try header(name, crc: 0, size: 0, mode: 0o755) }
    func addData(_ name: String, _ d: Data, mode: UInt16) throws {
        let crc = d.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(d.count))) }
        try header(name, crc: crc, size: UInt64(d.count), mode: mode); try write(d)
    }
    /// a file from disk, streamed twice (checksum first: the local header carries it); Mach-O files get 0755
    func addFile(_ name: String, from u: URL) throws {
        let r = try FileHandle(forReadingFrom: u); defer { try? r.close() }
        var crc: uLong = 0, size: UInt64 = 0, first = Data()
        while let d = try r.read(upToCount: 4 << 20), !d.isEmpty {
            if first.isEmpty { first = d.prefix(4) }
            crc = d.withUnsafeBytes { zlib.crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt(d.count)) }; size += UInt64(d.count)
        }
        let magic = first.count == 4 ? first.u32(0) : 0
        let exec = [0xFEEDFACF, 0xFEEDFACE, 0xBEBAFECA].contains(magic)
        try header(name, crc: UInt32(crc), size: size, mode: exec ? 0o755 : 0o644)
        try r.seek(toOffset: 0)
        while let d = try r.read(upToCount: 4 << 20), !d.isEmpty { try write(d) }
    }
    func finish() throws {
        let at = offset
        guard at < 0xFFFF_FFFF else { throw StoreError("the IPA would be over 4 GB") }
        try write(central)
        var e = Data()
        e.appendLE(UInt32(0x06054b50)); e.appendLE(UInt16(0)); e.appendLE(UInt16(0)); e.appendLE(UInt16(count)); e.appendLE(UInt16(count))
        e.appendLE(UInt32(central.count)); e.appendLE(UInt32(at)); e.appendLE(UInt16(0))
        try write(e)
        try h.write(contentsOf: buf); buf.removeAll()
        try h.synchronize(); try h.close()
    }
}
