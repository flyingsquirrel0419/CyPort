// sign-swift IN OUT: retarget like the app (shim/MachORetarget.swift), then ad-hoc sign (shim/MachOSign.swift)
import Foundation
let a = CommandLine.arguments
guard a.count == 3 else { FileHandle.standardError.write(Data("usage: sign-swift IN OUT\n".utf8)); exit(2) }
do {
    let out = URL(fileURLWithPath: a[2])
    _ = try MachORetarget.retarget(src: URL(fileURLWithPath: a[1]), dst: out)
    try MachOSign.sign(file: out, identifier: "CyberpunkGame")
    try MachOSign.sign(file: out, identifier: "CyberpunkGame")          // again: replaces its own signature
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
