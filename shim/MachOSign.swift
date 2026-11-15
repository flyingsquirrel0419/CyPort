// MachOSign.swift - an ad-hoc code signature for a thin arm64 Mach-O, like `codesign -f -s -` (what build.sh does on a
// Mac after tools/ios_retarget.py). The retargeted game program still carries the Mac's signature, which no longer
// matches (dyld: "code signature invalid") and is sized for 16 KB pages; this replaces it with a fresh one (4 KB page
// hashes, SHA-256) that sideloaders (SideStore, LiveContainer, AltStore, TrollStore) then re-sign with their certificate.
import Foundation
import CommonCrypto

enum MachOSign {
    struct SignError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ m: String) { message = m } }
    static let LC_CODE_SIGNATURE: UInt32 = 0x1d, LC_SEGMENT_64: UInt32 = 0x19
    static let pageShift = 12, pageSize = 1 << 12

    static func sign(file: URL, identifier: String) throws {
        var d = [UInt8](try Data(contentsOf: file, options: .alwaysMapped))
        try sign(&d, identifier: identifier)
        try Data(d).write(to: file)
    }

    static func sign(_ d: inout [UInt8], identifier: String) throws {
        guard d.count >= 32, le32(d, 0) == 0xfeedfacf else { throw SignError("not a thin 64-bit Mach-O") }
        let ncmds = Int(le32(d, 16)), szcmds = Int(le32(d, 20)), ftype = le32(d, 12)
        var off = 32, sigCmd: Int?, linkedit: Int?, text: Int?, firstSection = d.count
        for _ in 0..<ncmds {
            let c = le32(d, off), sz = Int(le32(d, off + 4))
            if c == LC_CODE_SIGNATURE { sigCmd = off }
            if c == LC_SEGMENT_64 {
                let name = String(decoding: d[(off + 8)..<(off + 24)].prefix { $0 != 0 }, as: UTF8.self)
                if name == "__LINKEDIT" { linkedit = off }
                if name == "__TEXT" { text = off }
                for i in 0..<Int(le32(d, off + 64)) {
                    let fo = Int(le32(d, off + 72 + 80 * i + 48)); if fo != 0 { firstSection = min(firstSection, fo) }
                }
            }
            off += sz
        }
        guard let le = linkedit, let tx = text else { throw SignError("no __TEXT / __LINKEDIT segment") }

        // where the signature goes: the old one's place (end of __LINKEDIT), else a new load command + the file's end
        let dataoff: Int
        if let sc = sigCmd {
            dataoff = Int(le32(d, sc + 8))
            guard dataoff <= d.count else { throw SignError("code signature offset past the end of the file") }
        } else {
            let end = 32 + szcmds
            guard end + 16 <= firstSection, d[end..<(end + 16)].allSatisfy({ $0 == 0 }) else { throw SignError("no room for a code signature load command") }
            put32(&d, end, LC_CODE_SIGNATURE); put32(&d, end + 4, 16)
            put32(&d, 16, UInt32(ncmds + 1)); put32(&d, 20, UInt32(szcmds + 16))
            sigCmd = end
            dataoff = (d.count + 15) & ~15
        }
        d.removeSubrange(min(dataoff, d.count)..<d.count)
        if d.count < dataoff { d += [UInt8](repeating: 0, count: dataoff - d.count) }

        // the blobs (sizes first: they go into the header, which is hashed)
        let ident = Array(identifier.utf8) + [0]
        let nCode = (dataoff + pageSize - 1) / pageSize, nSpecial = 2               // -1 Info.plist (none), -2 requirements
        let cdHeader = 88
        let hashOffset = cdHeader + ident.count + nSpecial * 32
        let cdLength = hashOffset + nCode * 32
        let requirements: [UInt8] = be(0xfade0c01) + be(12) + be(0)              // empty requirement set
        let cms: [UInt8] = be(0xfade0b01) + be(8)                                // empty CMS wrapper (ad-hoc)
        let nBlobs = 3, sbHeader = 12 + 8 * nBlobs
        let total = sbHeader + cdLength + requirements.count + cms.count
        let sigSize = (total + 15) & ~15

        // header: signature size, __LINKEDIT reaching the signature's end
        put32(&d, sigCmd! + 8, UInt32(dataoff)); put32(&d, sigCmd! + 12, UInt32(sigSize))
        let leFileoff = Int(le64(d, le + 40))
        let leFilesize = UInt64(dataoff + sigSize - leFileoff)
        put64(&d, le + 48, leFilesize)
        let vm = (leFilesize + 0x3fff) & ~UInt64(0x3fff)
        if le64(d, le + 32) < vm { put64(&d, le + 32, vm) }

        // CodeDirectory (version 0x20400, with the executable segment)
        var cd = [UInt8]()
        cd += be(0xfade0c02) + be(UInt32(cdLength)) + be(0x20400) + be(0x2)                   // flags: adhoc
        cd += be(UInt32(hashOffset)) + be(UInt32(cdHeader)) + be(UInt32(nSpecial)) + be(UInt32(nCode))
        cd += be(UInt32(dataoff))                                                              // codeLimit
        cd += [32, 2, 0, UInt8(pageShift)]                                                     // SHA-256, 4 KB pages
        cd += be(0) + be(0) + be(0) + be(0)                                                    // spare2, scatter, team, spare3
        cd += be64(0)                                                                          // codeLimit64
        cd += be64(le64(d, tx + 40)) + be64(le64(d, tx + 48))                                  // execSeg base / limit
        cd += be64(ftype == 2 ? 1 : 0)                                                         // main binary
        precondition(cd.count == cdHeader)
        cd += ident
        cd += [UInt8](repeating: 0, count: 32)                                                 // slot -2 goes first (lower address)
        cd += [UInt8](repeating: 0, count: 32)                                                 // slot -1: no Info.plist
        let reqHash = sha256(requirements[...])
        for k in 0..<32 { cd[cdHeader + ident.count + k] = reqHash[k] }
        d.withUnsafeBytes { p in
            for i in 0..<nCode {
                let a = i * pageSize, b = min(dataoff, a + pageSize)
                cd += sha256(UnsafeRawBufferPointer(rebasing: p[a..<b]))
            }
        }
        precondition(cd.count == cdLength)

        var sb = [UInt8]()
        sb += be(0xfade0cc0) + be(UInt32(total)) + be(UInt32(nBlobs))
        sb += be(0) + be(UInt32(sbHeader))                                                     // CodeDirectory
        sb += be(2) + be(UInt32(sbHeader + cdLength))                                          // requirements
        sb += be(0x10000) + be(UInt32(sbHeader + cdLength + requirements.count))               // CMS
        sb += cd + requirements + cms
        sb += [UInt8](repeating: 0, count: sigSize - sb.count)
        d += sb
    }

    // MARK: bytes

    static func le32(_ d: [UInt8], _ o: Int) -> UInt32 { UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24 }
    static func le64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(le32(d, o)) | UInt64(le32(d, o + 4)) << 32 }
    static func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) { for k in 0..<4 { d[o + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(k))) } }
    static func put64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) { put32(&d, o, UInt32(truncatingIfNeeded: v)); put32(&d, o + 4, UInt32(truncatingIfNeeded: v >> 32)) }
    static func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)] }
    static func be64(_ v: UInt64) -> [UInt8] { be(UInt32(v >> 32)) + be(UInt32(truncatingIfNeeded: v)) }
    static func sha256(_ s: ArraySlice<UInt8>) -> [UInt8] { s.withUnsafeBytes { sha256($0) } }
    static func sha256(_ p: UnsafeRawBufferPointer) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: 32)
        _ = CC_SHA256(p.baseAddress, CC_LONG(p.count), &h)
        return h
    }
}
