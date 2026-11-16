// On-device retargeting: tools/ios_retarget.py --game-folder, ported to Swift so the app can turn the Mac game program
// it downloaded from Steam into Games/<version>/CyberpunkGame.dylib (+ its Frameworks) without a Mac.
// Same steps, same checks, same output bytes as the Python tool (tools/test_retarget.sh compares them):
//   build version macOS -> iOS, macOS-only frameworks -> the shim, rpaths, imports rerouted to the shim, duplicate dylib
//   commands removed, the executable's byte patches (pool end, watchdog, pool sizes, free hook), executable -> loadable
//   library (MH_DYLIB) and the game-folder rpaths. Comments on the why are in ios_retarget.py.
// No UIKit here: it also builds for the Linux/Mac test (tools/test_retarget.sh).
import Foundation

struct RetargetError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum MachORetarget {
    static let LC_SEGMENT_64: UInt32 = 0x19, LC_LOAD_DYLIB: UInt32 = 0x0c, LC_ID_DYLIB: UInt32 = 0x0d
    static let LC_LOAD_WEAK_DYLIB: UInt32 = 0x80000018, LC_REEXPORT_DYLIB: UInt32 = 0x8000001f, LC_LOAD_UPWARD: UInt32 = 0x80000023
    static let LC_RPATH: UInt32 = 0x8000001c, LC_BUILD_VERSION: UInt32 = 0x32, LC_VERSION_MIN_MACOSX: UInt32 = 0x24
    static let LC_DYLD_CHAINED_FIXUPS: UInt32 = 0x80000034, LC_SYMTAB: UInt32 = 0x2, LC_DYLD_INFO: UInt32 = 0x22, LC_DYLD_INFO_ONLY: UInt32 = 0x80000022
    static let dylibCmds: Set<UInt32> = [LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD]
    static let reroute: Set<String> = [
        "__NSGetExecutablePath", "_sysctlbyname", "_mmap", "_munmap", "_madvise", "_mprotect",
        "_opendir", "_realpath$DARWIN_EXTSN", "_stat", "_access", "_fopen", "_open", "_rename", "_mkdir",
        "_read", "_close", "_lseek", "_AUGraphStart", "_AUGraphSetNodeInputCallback", "_sysconf", "_sysctl", "_dlopen",
        "_BinkOpenWithOptions", "_BinkStartAsyncThread", "_BinkDoFrameAsyncMulti", "_BinkDoFrameAsyncWait",
        "_BinkRegisterFrameBuffers", "_BinkGetFrameBuffersInfo", "_pthread_set_qos_class_self_np",
        "_pthread_setschedparam", "_pthread_attr_setschedpolicy", "_sched_yield", "_dispatch_semaphore_wait", "_os_sync_wait_on_address"]
    static let shim = "@rpath/libMacShim.dylib"
    static let shimFrameworks: Set<String> = ["AppKit", "Cocoa", "IOKit", "Carbon", "AudioUnit", "CoreAudio", "CoreGraphics", "Security", "Metal"]
    static let shimDylibs: Set<String> = ["/usr/lib/libcurl.4.dylib"]
    static let ARM_NOP: UInt32 = 0xd503201f, ARM_CMN_X0_1: UInt32 = 0xb100041f, ARM_ADD_X1_X0_X19: UInt32 = 0x8b130001
    static let freeEntry: UInt64 = 0x100012cac
    static let freePrologue: [UInt32] = [0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd, 0xaa0103f3, 0xaa0003f4]

    struct Cmd { let cmd: UInt32; let off: Int; let size: Int }
    struct Header { let ftype: UInt32; let sub: UInt32; let cmds: [Cmd] }

    /// retarget `src` into `dst` for a game folder (Games/<version>/): the executable becomes CyberpunkGame.dylib,
    /// a library keeps its name. Returns the log lines (what ios_retarget.py prints).
    @discardableResult
    static func retarget(src: URL, dst: URL, minos: String = "18.0", sdk: String = "18.0", poolGB: Int = 8) throws -> [String] {
        var d = try thinARM64([UInt8](try Data(contentsOf: src, options: .alwaysMapped)))
        let log = try retarget(&d, minos: minos, sdk: sdk, poolGB: poolGB)
        try Data(d).write(to: dst)
        return log
    }

    static func retarget(_ d: inout [UInt8], minos: String, sdk: String, poolGB: Int) throws -> [String] {
        let m = try parse(d); var log: [String] = []; var seen = false
        for c in m.cmds {
            if c.cmd == LC_VERSION_MIN_MACOSX { throw RetargetError("legacy LC_VERSION_MIN_MACOSX binary: unsupported") }
            if c.cmd == LC_BUILD_VERSION {
                seen = true
                if u32(d, c.off + 8) == 1 {
                    put32(&d, c.off + 8, 2); put32(&d, c.off + 12, ver(minos)); put32(&d, c.off + 16, ver(sdk))
                    log.append("build_version: macOS -> iOS (minos \(minos), sdk \(sdk))")
                }
            } else if dylibCmds.contains(c.cmd) || c.cmd == LC_RPATH || c.cmd == LC_ID_DYLIB {
                let (no, old) = nameOf(d, c)
                let new = c.cmd == LC_RPATH ? mapRpath(old) : mapDylib(old)
                if let new, new != old {
                    let nb = Array(new.utf8) + [0]
                    if no + nb.count > c.size { throw RetargetError("replacement too long: \(old) -> \(new)") }
                    for k in 0..<(c.size - no) { d[c.off + no + k] = k < nb.count ? nb[k] : 0 }
                    log.append("\(old) -> \(new)")
                }
            }
        }
        if !seen { throw RetargetError("no LC_BUILD_VERSION: not a modern macOS build") }
        log += rerouteImports(&d, m)
        if m.ftype == 2 {
            log += patchPoolEnd(&d, m); log += patchWatchdog(&d, m); log += patchPoolSizes(&d, gb: poolGB); log += patchFreeHook(&d, m)
            log += patchSavePathLimit(&d, m)
        } else { log += patchSteamSignIn(&d, m) }
        log += try dedupeDylibs(&d, m)
        if m.ftype == 2 { log += makeLoadable(&d, try parse(d)) }
        if m.ftype != 2 { log += try addRpath(&d, "@loader_path") }
        log += try addRpath(&d, "@executable_path/Frameworks")
        return log
    }

    // MARK: bytes

    @inline(__always) static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24
    }
    @inline(__always) static func u16(_ d: [UInt8], _ o: Int) -> UInt16 { UInt16(d[o]) | UInt16(d[o + 1]) << 8 }
    @inline(__always) static func u64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32 }
    @inline(__always) static func be32(_ d: [UInt8], _ o: Int) -> UInt32 {
        UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
    @inline(__always) static func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) { for k in 0..<4 { d[o + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(k))) } }
    @inline(__always) static func put16(_ d: inout [UInt8], _ o: Int, _ v: UInt16) { d[o] = UInt8(v & 0xff); d[o + 1] = UInt8(v >> 8) }
    @inline(__always) static func put64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) { put32(&d, o, UInt32(truncatingIfNeeded: v)); put32(&d, o + 4, UInt32(truncatingIfNeeded: v >> 32)) }
    static func cstr(_ d: [UInt8], _ from: Int, _ to: Int) -> String {
        var e = from; while e < min(to, d.count) && d[e] != 0 { e += 1 }
        return String(decoding: d[from..<e], as: UTF8.self)
    }
    static func ver(_ s: String) -> UInt32 {
        let p = s.split(separator: ".").map { UInt32($0) ?? 0 } + [0, 0]
        return p[0] << 16 | p[1] << 8 | p[2]
    }
    static func find(_ d: [UInt8], _ key: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
        let end = min(to ?? d.count, d.count) - key.count
        guard end >= from, let first = key.first else { return nil }
        var i = from
        while i <= end {
            if d[i] == first {
                var k = 1; while k < key.count && d[i + k] == key[k] { k += 1 }
                if k == key.count { return i }
            }
            i += 1
        }
        return nil
    }

    // MARK: Mach-O

    static func thinARM64(_ d: [UInt8]) throws -> [UInt8] {
        guard d.count >= 8, be32(d, 0) == 0xcafebabe else { return d }
        let n = Int(be32(d, 4))
        for i in 0..<n {
            let e = 8 + 20 * i
            let cpu = be32(d, e), sub = be32(d, e + 4), off = Int(be32(d, e + 8)), size = Int(be32(d, e + 12))
            if cpu == 0x0100000c && sub & 0xffffff == 0 { return Array(d[off..<(off + size)]) }
        }
        throw RetargetError("universal file has no arm64 slice")
    }
    static func parse(_ d: [UInt8]) throws -> Header {
        guard d.count >= 32, u32(d, 0) == 0xfeedfacf else { throw RetargetError("not a 64-bit little-endian Mach-O") }
        let cpu = u32(d, 4)
        guard cpu == 0x0100000c else { throw RetargetError("not arm64 (cputype=\(String(cpu, radix: 16)))") }
        var cmds: [Cmd] = [], off = 32
        for _ in 0..<Int(u32(d, 16)) {
            let c = u32(d, off), sz = Int(u32(d, off + 4)); cmds.append(Cmd(cmd: c, off: off, size: sz)); off += sz
        }
        return Header(ftype: u32(d, 12), sub: u32(d, 8), cmds: cmds)
    }
    static func nameOf(_ d: [UInt8], _ c: Cmd) -> (Int, String) {
        let no = Int(u32(d, c.off + 8)); return (no, cstr(d, c.off + no, c.off + c.size))
    }
    static func mapDylib(_ p: String) -> String? {
        let fw = "/System/Library/Frameworks/"
        if p.hasPrefix(fw) {
            // /System/Library/Frameworks/X.framework/Versions/A/X
            let parts = p.dropFirst(fw.count).split(separator: "/", omittingEmptySubsequences: false)
            if parts.count == 4, parts[0].hasSuffix(".framework"), parts[1] == "Versions", parts[2].count == 1,
               parts[2].first!.isUppercase, parts[2].first!.isASCII {
                let name = String(parts[0].dropLast(".framework".count))
                if !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }), parts[3] == name {
                    return shimFrameworks.contains(name) ? shim : "/System/Library/Frameworks/\(name).framework/\(name)"
                }
            }
        }
        if shimDylibs.contains(p) { return shim }
        let exe = "@executable_path/../Frameworks/"
        if p.hasPrefix(exe) { return "@rpath/" + p.dropFirst(exe.count) }
        return nil
    }
    static func mapRpath(_ p: String) -> String? {
        ["@executable_path/../Frameworks": "@loader_path/Frameworks", "@loader_path/../Frameworks": "@loader_path"][p]
    }
    /// (addr, size, fileoff) of every section by name (the last one with that name wins, as in the Python dict)
    static func sections(_ d: [UInt8], _ m: Header) -> [String: (UInt64, UInt64, Int)] {
        var out: [String: (UInt64, UInt64, Int)] = [:]
        for c in m.cmds where c.cmd == LC_SEGMENT_64 {
            for i in 0..<Int(u32(d, c.off + 64)) {
                let so = c.off + 72 + 80 * i
                out[cstr(d, so, so + 16)] = (u64(d, so + 32), u64(d, so + 40), Int(u32(d, so + 48)))
            }
        }
        return out
    }

    /// libGameServicesSteam (Steam Mac build): with no Steam client SteamAPI_Init fails, Initialize answers -1 and SignIn
    /// calls back "not signed in" - and the game then lists no saves (its saves folder is read but every slot dropped;
    /// new saves always go to ManualSave-0). Like the GOG build's fake sign-in, SignIn now calls back "signed in" at
    /// once and Initialize answers ok. Every other function there checks Steam itself (its initialized flag / null
    /// interfaces), so nothing else reaches the missing Steam. Same as patch_steam_signin in ios_retarget.py.
    static func patchSteamSignIn(_ d: inout [UInt8], _ m: Header) -> [String] {
        var syms: [String: UInt64] = [:], steam = false, text: (UInt64, UInt64)?
        for c in m.cmds {
            if c.cmd == LC_SEGMENT_64 && cstr(d, c.off + 8, c.off + 24) == "__TEXT" { text = (u64(d, c.off + 24), u64(d, c.off + 40)) }
            if c.cmd == LC_SYMTAB {
                let symoff = Int(u32(d, c.off + 8)), nsyms = Int(u32(d, c.off + 12)), stroff = Int(u32(d, c.off + 16))
                for i in 0..<nsyms {
                    let e = symoff + 16 * i, strx = stroff + Int(u32(d, e)), typ = d[e + 4]
                    let name = cstr(d, strx, min(strx + 128, d.count))
                    if name.contains("GameServicesSteam6SignIn") { steam = true }
                    if typ & 0x0f == 0x0f && (name == "_SignIn" || name == "_Initialize") { syms[name] = u64(d, e + 8) }
                }
            }
        }
        guard steam else { return [] }
        guard let text, let si = syms["_SignIn"], let ii = syms["_Initialize"] else { return ["steam sign-in patch: symbols missing; NOT applied"] }
        let s = Int(text.1 + si - text.0), i = Int(text.1 + ii - text.0)
        guard s + 12 <= d.count, i + 0x1c <= d.count, u32(d, s) == 0xaa0103e2, u32(d, s + 4) == 0xaa0003e1, u32(d, i + 0x18) == 0x51000400 else {
            return ["steam sign-in patch: unexpected code; NOT applied"]
        }
        put32(&d, s, 0xaa0003e2); put32(&d, s + 4, 0x52800020); put32(&d, s + 8, 0xd61f0040)     // mov x2,x0 ; mov w0,#1 ; br x2
        put32(&d, i + 0x18, 0x52800000)                                                         // mov w0,#0
        return ["steam sign-in patch: SignIn answers signed in, Initialize answers ok (no Steam client on iOS)"]
    }

    static func addRpath(_ d: inout [UInt8], _ path: String) throws -> [String] {
        let m = try parse(d); let ncmds = u32(d, 16), szcmds = Int(u32(d, 20))
        for c in m.cmds where c.cmd == LC_RPATH && nameOf(d, c).1 == path { return [] }
        var first = d.count
        for c in m.cmds where c.cmd == LC_SEGMENT_64 {
            for i in 0..<Int(u32(d, c.off + 64)) {
                let sf = Int(u32(d, c.off + 72 + 80 * i + 48)); if sf != 0 { first = min(first, sf) }
            }
        }
        let nb = Array(path.utf8) + [0]; let size = (12 + nb.count + 7) & ~7; let end = 32 + szcmds
        if end + size > first || d[end..<(end + size)].contains(where: { $0 != 0 }) { return ["rpath \(path): no room after the load commands; NOT added"] }
        put32(&d, end, LC_RPATH); put32(&d, end + 4, UInt32(size)); put32(&d, end + 8, 12)
        for k in 0..<(size - 12) { d[end + 12 + k] = k < nb.count ? nb[k] : 0 }
        put32(&d, 16, ncmds + 1); put32(&d, 20, UInt32(szcmds + size))
        return ["rpath \(path) added"]
    }

    static func makeLoadable(_ d: inout [UInt8], _ m: Header) -> [String] {
        guard let pz = m.cmds.last(where: { $0.cmd == LC_SEGMENT_64 && cstr(d, $0.off + 8, $0.off + 24) == "__PAGEZERO" })?.off else {
            return ["game folder: no __PAGEZERO; NOT made loadable"]
        }
        let vmaddr = u64(d, pz + 24), vmsize = u64(d, pz + 32)
        put64(&d, pz + 24, vmaddr &+ vmsize &- 0x4000); put64(&d, pz + 32, 0x4000)
        let name = Array("@loader_path/CyberpunkGame.dylib".utf8) + [0]; let size = (24 + name.count + 7) & ~7
        let ncmds = u32(d, 16), szcmds = Int(u32(d, 20)), end = 32 + szcmds
        if d[end..<(end + size)].contains(where: { $0 != 0 }) { return ["game folder: no header room for LC_ID_DYLIB; NOT made loadable"] }
        for (k, v) in [LC_ID_DYLIB, UInt32(size), 24, 2, 0x10000, 0x10000].enumerated() { put32(&d, end + 4 * k, v) }
        for k in 0..<(size - 24) { d[end + 24 + k] = k < name.count ? name[k] : 0 }
        put32(&d, 16, ncmds + 1); put32(&d, 20, UInt32(szcmds + size))
        put32(&d, 12, 6)
        put32(&d, 24, u32(d, 24) & ~0x200000)
        return ["game folder: executable -> loadable library (__PAGEZERO one page, LC_ID_DYLIB added, LC_MAIN kept)"]
    }

    static func rerouteImports(_ d: inout [UInt8], _ m: Header) -> [String] {
        var ordinal: Int?, n = 0
        for c in m.cmds where dylibCmds.contains(c.cmd) {
            n += 1
            if ordinal == nil && nameOf(d, c).1 == shim { ordinal = n }
        }
        guard let fx = m.cmds.first(where: { $0.cmd == LC_DYLD_CHAINED_FIXUPS }), let ord = ordinal, ord <= 250 else { return [] }
        let dataoff = Int(u32(d, fx.off + 8))
        let impOff = Int(u32(d, dataoff + 8)), symOff = Int(u32(d, dataoff + 12)), count = Int(u32(d, dataoff + 16))
        let fmt = u32(d, dataoff + 20), symfmt = u32(d, dataoff + 24)
        guard [1, 2, 3].contains(fmt), symfmt == 0 else { return ["chained fixups format \(fmt) not handled; not rerouted"] }
        let size = [1: 4, 2: 8, 3: 16][Int(fmt)]!
        var done = Set<String>()
        for i in 0..<count {
            let p = dataoff + impOff + i * size
            let nameOff: Int
            if fmt == 3 { nameOff = Int(u64(d, p) >> 32) } else { nameOff = Int(u32(d, p) >> 9) }
            let s = dataoff + symOff + nameOff
            let name = cstr(d, s, s + 64)
            if reroute.contains(name) {
                if fmt == 3 { let v = u64(d, p); put64(&d, p, (v & ~0xffff) | UInt64(ord)) }
                else { let v = u32(d, p); put32(&d, p, (v & ~0xff) | UInt32(ord)) }
                done.insert(name)
            }
        }
        return done.isEmpty ? [] : ["rerouted to shim (ordinal \(ord)): " + done.sorted().joined(separator: ", ")]
    }

    static func dedupeDylibs(_ d: inout [UInt8], _ m: Header) throws -> [String] {
        let dylibs = m.cmds.filter { dylibCmds.contains($0.cmd) }
        var first: [String: Int] = [:], remap: [Int: Int] = [:], drop = Set<Int>()
        for (i0, c) in dylibs.enumerated() {
            let i = i0 + 1, path = nameOf(d, c).1
            if let j = first[path] {
                drop.insert(c.off)
                if c.cmd != LC_LOAD_WEAK_DYLIB && dylibs[j - 1].cmd == LC_LOAD_WEAK_DYLIB { put32(&d, dylibs[j - 1].off, LC_LOAD_DYLIB) }
                remap[i] = remap[j]
            } else { first[path] = i; remap[i] = first.count }
        }
        if drop.isEmpty { return [] }
        if (remap.keys.max() ?? 0) > 253 { throw RetargetError("too many dylibs to renumber") }
        for c in m.cmds where c.cmd == LC_DYLD_INFO || c.cmd == LC_DYLD_INFO_ONLY {
            let bo = Int(u32(d, c.off + 16)), bs = Int(u32(d, c.off + 20)), lo = Int(u32(d, c.off + 32)), ls = Int(u32(d, c.off + 36))
            remapBindOpcodes(&d, bo, bs, remap); remapBindOpcodes(&d, lo, ls, remap)
        }
        if let fx = m.cmds.first(where: { $0.cmd == LC_DYLD_CHAINED_FIXUPS }) {
            let dataoff = Int(u32(d, fx.off + 8))
            let impOff = Int(u32(d, dataoff + 8)), count = Int(u32(d, dataoff + 16)), fmt = Int(u32(d, dataoff + 20))
            guard let size = [1: 4, 2: 8, 3: 16][fmt] else { throw RetargetError("chained fixups format \(fmt)") }
            for i in 0..<count {
                let p = dataoff + impOff + i * size
                if fmt == 3 {
                    let v = u64(d, p); if let r = remap[Int(v & 0xffff)] { put64(&d, p, (v & ~0xffff) | UInt64(r)) }
                } else {
                    let v = u32(d, p); if let r = remap[Int(v & 0xff)] { put32(&d, p, (v & ~0xff) | UInt32(r)) }
                }
            }
        }
        for c in m.cmds where c.cmd == LC_SYMTAB {
            let symoff = Int(u32(d, c.off + 8)), nsyms = Int(u32(d, c.off + 12))
            for i in 0..<nsyms {
                let e = symoff + 16 * i, ntype = d[e + 4], desc = u16(d, e + 6)
                if ntype & 0xe0 != 0 || ntype & 0x0e != 0 { continue }
                if let r = remap[Int(desc >> 8)] { put16(&d, e + 6, (desc & 0xff) | UInt16(r) << 8) }
            }
        }
        let sizeofcmds = Int(u32(d, 20))
        var body: [UInt8] = []
        for c in m.cmds where !drop.contains(c.off) { body += d[c.off..<(c.off + c.size)] }
        for k in 0..<sizeofcmds { d[32 + k] = k < body.count ? body[k] : 0 }
        put32(&d, 16, u32(d, 16) - UInt32(drop.count)); put32(&d, 20, UInt32(body.count))
        return ["removed \(drop.count) duplicate dylib load command(s), import ordinals renumbered"]
    }

    static func remapBindOpcodes(_ d: inout [UInt8], _ start: Int, _ size: Int, _ remap: [Int: Int]) {
        func uleb(_ i0: Int) -> (Int, Int) {
            var v = 0, sh = 0, i = i0
            while true { let b = d[i]; i += 1; v |= Int(b & 0x7f) << sh; sh += 7; if b & 0x80 == 0 { return (v, i) } }
        }
        func skipStr(_ i0: Int) -> Int { var i = i0; while d[i] != 0 { i += 1 }; return i + 1 }
        var i = start; let end = start + size
        while i < end {
            let b = d[i], op = b & 0xf0, imm = Int(b & 0x0f); i += 1
            switch op {
            case 0x10: if let r = remap[imm] { d[i - 1] = 0x10 | UInt8(r) }
            case 0x20:
                let (v, j) = uleb(i)
                if let w = remap[v] { let n = j - i; for k in 0..<n { d[i + k] = UInt8((w >> (7 * k)) & 0x7f) | (k < n - 1 ? 0x80 : 0) } }
                i = j
            case 0x40: i = skipStr(i)
            case 0x60, 0x70, 0x80, 0xa0: i = uleb(i).1
            case 0xc0: i = uleb(uleb(i).1).1
            case 0xf0: if imm == 0 { i = uleb(i).1 }
            default: break
            }
        }
    }

    // MARK: the executable's byte patches

    static func patchPoolEnd(_ d: inout [UInt8], _ m: Header) -> [String] {
        var text: (UInt64, UInt64, Int)?
        for c in m.cmds where c.cmd == LC_SEGMENT_64 && cstr(d, c.off + 8, c.off + 24) == "__TEXT" {
            for i in 0..<Int(u32(d, c.off + 64)) {
                let so = c.off + 72 + 80 * i
                if cstr(d, so, so + 16) == "__text" { text = (u64(d, so + 32), u64(d, so + 40), Int(u32(d, so + 48))) }
            }
        }
        guard let (addr, size, foff) = text else { return ["pool-end patch: no __text section; not applied"] }
        var sites: [Int] = [], targets = Set<Int64>()
        var i = foff + 4
        while i < foff + Int(size) - 8 {
            if u32(d, i) == ARM_CMN_X0_1 {
                let bl = u32(d, i - 4), beq = u32(d, i + 4), add = u32(d, i + 8)
                if bl >> 26 == 0b100101 && beq & 0xff00001f == 0x54000000 && (add == ARM_ADD_X1_X0_X19 || add == ARM_NOP) {
                    var imm = Int64(bl & 0x3ffffff); if imm & (1 << 25) != 0 { imm -= 1 << 26 }
                    targets.insert(Int64(addr) + Int64(i - 4 - foff) + imm * 4); sites.append(i + 8)
                }
            }
            i += 4
        }
        if sites.count != 2 || targets.count != 1 {
            return ["pool-end patch: expected 2 sites, found \(sites.count); NOT applied (shim keeps the old address-space layout)"]
        }
        for s in sites { put32(&d, s, ARM_NOP) }
        return ["pool-end patch: add x1,x0,x19 -> nop at " + sites.map { "0x" + String(addr + UInt64($0 - foff), radix: 16) }.joined(separator: ", ")]
    }

    static func patchPoolSizes(_ d: inout [UInt8], gb: Int) -> [String] {
        func new(_ reg: UInt32) -> UInt32 { 0xd2c00000 | (UInt32((gb << 30) >> 32) << 5) | reg }
        func le(_ a: UInt32, _ b: UInt32) -> [UInt8] { var o = [UInt8](repeating: 0, count: 8); put32(&o, 0, a); put32(&o, 4, b); return o }
        let pats: [(UInt32, UInt32, UInt32, String)] = [(0xd2c00088, 0xf90023e8, 8, "16 GB"), (0xd2c00209, 0xa90227e8, 9, "64 GB"), (0xd2c00109, 0xa900a7e8, 9, "32 GB")]
        var out: [String] = []
        for (mov, nxt, reg, name) in pats {
            let key = le(mov, nxt)
            guard let j = find(d, key), find(d, key, from: j + 1) == nil else {
                out.append("pool-size patch: \(name) " + (find(d, le(new(reg), nxt)) != nil ? "already patched" : "NOT found; not applied")); continue
            }
            put32(&d, j, new(reg)); out.append("pool-size patch: \(name) pool -> \(gb) GB")
        }
        return out
    }

    static func patchWatchdog(_ d: inout [UInt8], _ m: Header) -> [String] {
        let secs = sections(d, m)
        guard let text = secs["__text"], let cs = secs["__cstring"] else { return ["watchdog patch: sections missing; not applied"] }
        let (caddr, csize, cfoff) = cs
        guard let j = find(d, Array("!!! EngineWatchdog timeout!\n".utf8) + [0], from: cfoff, to: cfoff + Int(csize)) else {
            return ["watchdog patch: message not found; NOT applied"]
        }
        let target = Int64(caddr) + Int64(j - cfoff)
        let (addr, size, foff) = text
        var sites: [(Int, Int64)] = []
        var i = foff + 4
        while i < foff + Int(size) - 8 {
            defer { i += 4 }
            let adrp = u32(d, i)
            if adrp & 0x9f00001f != 0x90000001 { continue }
            let add = u32(d, i + 4)
            if add & 0xffc003ff != 0x91000021 { continue }
            let pc = Int64(addr) + Int64(i - foff)
            var imm = Int64((adrp >> 29) & 3) | Int64((adrp >> 5) & 0x7ffff) << 2; if imm & (1 << 20) != 0 { imm -= 1 << 21 }
            if (pc & ~0xfff) + (imm << 12) + Int64((add >> 10) & 0xfff) != target { continue }
            let tb = u32(d, i - 4)
            if tb & 0xff00001f != 0x37000000 { continue }
            var o = Int64((tb >> 5) & 0x3fff); if o & (1 << 13) != 0 { o -= 1 << 14 }
            sites.append((i, o - 1))
        }
        guard sites.count == 1 else { return ["watchdog patch: expected 1 site, found \(sites.count); NOT applied"] }
        let (at, rel) = sites[0]
        put32(&d, at, 0x14000000 | (UInt32(truncatingIfNeeded: rel) & 0x3ffffff))
        return ["watchdog patch: engine watchdog timeout skipped at 0x" + String(addr + UInt64(at - foff), radix: 16)]
    }

    /// The game lists its saves folder and drops every slot whose folder path is over 200 characters before reading
    /// it:   bl <length> ; cmp w0,#200 ; b.hi <next slot>   (a few instructions before it looks for "metadata.*.json").
    /// On a Mac the path is ~100 characters; inside LiveContainer it is ~220 (the game's data folder sits inside the
    /// host app's), so the Load menu stayed empty and every new save went to ManualSave-0. The b.hi becomes a nop.
    /// Same as patch_save_path_limit in ios_retarget.py.
    static func patchSavePathLimit(_ d: inout [UInt8], _ m: Header) -> [String] {
        let secs = sections(d, m)
        guard let text = secs["__text"], let cs = secs["__cstring"] else { return ["save path patch: sections missing; not applied"] }
        let (caddr, csize, cfoff) = cs
        guard let j = find(d, Array("metadata.*.json".utf8) + [0], from: cfoff, to: cfoff + Int(csize)) else {
            return ["save path patch: save scan not found; not applied"]
        }
        let target = Int64(caddr) + Int64(j - cfoff)
        let (addr, size, foff) = text
        var sites: Set<Int> = []
        var i = foff
        while i < foff + Int(size) - 8 {
            defer { i += 4 }
            let adrp = u32(d, i)
            if adrp & 0x9f000000 != 0x90000000 { continue }
            let add = u32(d, i + 4)
            if add & 0xffc00000 != 0x91000000 || (add >> 5) & 31 != adrp & 31 { continue }
            let pc = Int64(addr) + Int64(i - foff)
            var imm = Int64((adrp >> 29) & 3) | Int64((adrp >> 5) & 0x7ffff) << 2; if imm & (1 << 20) != 0 { imm -= 1 << 21 }
            if (pc & ~0xfff) + (imm << 12) + Int64((add >> 10) & 0xfff) != target { continue }
            var k = i - 4
            while k > max(foff, i - 0x400) {
                if u32(d, k) == 0x7103201f && u32(d, k + 4) & 0xff00001f == 0x54000008 { sites.insert(k + 4); break }   // cmp w0,#200 ; b.hi
                k -= 4
            }
        }
        guard sites.count == 1, let at = sites.first else { return ["save path patch: expected 1 site, found \(sites.count); NOT applied"] }
        put32(&d, at, 0xd503201f)
        return ["save path patch: saves in folders with paths over 200 characters are listed (b.hi -> nop at 0x" + String(addr + UInt64(at - foff), radix: 16) + ")"]
    }

    static func patchFreeHook(_ d: inout [UInt8], _ m: Header) -> [String] {
        var segs: [String: (UInt64, UInt64)] = [:], text: (UInt64, UInt64, Int)?, lastEnd: UInt64 = 0
        for c in m.cmds where c.cmd == LC_SEGMENT_64 {
            let name = cstr(d, c.off + 8, c.off + 24)
            segs[name] = (u64(d, c.off + 24), u64(d, c.off + 32))
            for i in 0..<Int(u32(d, c.off + 64)) {
                let so = c.off + 72 + 80 * i; let sa = u64(d, so + 32), ss = u64(d, so + 40), sf = Int(u32(d, so + 48))
                if cstr(d, so, so + 16) == "__text" { text = (sa, ss, sf) }
                if name == "__DATA" { lastEnd = max(lastEnd, sa + ss) }
            }
        }
        guard let (addr, size, foff) = text, let data = segs["__DATA"] else { return ["free hook: segments missing; NOT applied"] }
        let slot = data.0 + data.1 - 0x100
        if slot < lastEnd { return ["free hook: no padding after the last __DATA section; NOT applied"] }
        guard addr <= freeEntry && freeEntry < addr + size else { return ["free hook: entry outside __text; NOT applied"] }
        let fo = foff + Int(freeEntry - addr)
        let cur = (0..<6).map { u32(d, fo + 4 * $0) }
        if Array(cur[3...]) != Array(freePrologue[3...]) || (Array(cur[..<3]) != Array(freePrologue[..<3]) && cur[0] & 0x9f00001f != 0x90000010) {
            return ["free hook: unexpected code at 0x\(String(freeEntry, radix: 16)); NOT applied"]
        }
        let imm = (Int64(slot & ~0xfff) - Int64(freeEntry & ~0xfff)) >> 12
        let adrp = 0x90000010 | (UInt32(truncatingIfNeeded: imm & 3) << 29) | (UInt32(truncatingIfNeeded: (imm >> 2) & 0x7ffff) << 5)
        let ldr = 0xf9400210 | (UInt32((slot & 0xfff) / 8) << 10)
        put32(&d, fo, adrp); put32(&d, fo + 4, ldr); put32(&d, fo + 8, 0xd61f0200)
        return ["free hook: engine Free 0x\(String(freeEntry, radix: 16)) -> through slot 0x\(String(slot, radix: 16)) (shim quarantine)"]
    }
}
