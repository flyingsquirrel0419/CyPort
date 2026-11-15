// retarget-swift IN OUT: shim/MachORetarget.swift as a command line tool, for tools/test_retarget.sh
import Foundation
let a = CommandLine.arguments
guard a.count == 3 else { FileHandle.standardError.write(Data("usage: retarget-swift IN OUT\n".utf8)); exit(2) }
do {
    for l in try MachORetarget.retarget(src: URL(fileURLWithPath: a[1]), dst: URL(fileURLWithPath: a[2]),
                                        poolGB: Int(ProcessInfo.processInfo.environment["POOL_GB"] ?? "8") ?? 8) { print("  " + l) }
} catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
