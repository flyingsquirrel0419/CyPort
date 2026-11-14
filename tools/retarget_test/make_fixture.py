#!/usr/bin/env python3
"""Make a test executable for tools/test_retarget.sh out of any arm64 macOS executable (CI uses ripgrep's):
plants what ios_retarget.py looks for in the game, so every patch path runs, not just the "not found" ones:
  - two dylib load commands renamed to /usr/lib/libcurl.4.dylib (-> both the shim: import rerouting + duplicate removal)
  - the engine's two pool reservations (bl mmap; cmn x0,#1; b.eq; add x1,x0,x19), the three pool-size constants,
    the watchdog message + its tbnz/adrp/add, and the allocator's Free prologue at 0x100012cac (if it is inside __text)
The result is not meant to run - only to be retargeted.

  make_fixture.py IN OUT
"""
import struct, sys

sys.path.insert(0, __file__.rsplit("/", 3)[0] + "/tools")
import ios_retarget as R  # noqa: E402


def main(src, dst):
    d = bytearray(R.thin_arm64(open(src, "rb").read())); m = R.parse(d)
    if m["ftype"] != 2: raise SystemExit("needs an executable")
    # 1. two libraries -> the shim's libcurl stand-in
    n = 0
    for cmd, off, sz in m["cmds"]:
        if cmd not in R.DYLIB_CMDS or n == 2: continue
        no, name = R.name_of(d, off, sz)
        if "libSystem" in name: continue
        nb = b"/usr/lib/libcurl.4.dylib\0"
        if no + len(nb) > sz: continue
        d[off + no:off + sz] = nb + b"\0" * (sz - no - len(nb)); n += 1
    if n < 2: raise SystemExit("needs two non-libSystem dylib load commands with room")
    secs = {}
    for cmd, off, sz in m["cmds"]:
        if cmd != R.LC_SEGMENT_64: continue
        for i in range(struct.unpack_from("<I", d, off + 64)[0]):
            so = off + 72 + 80 * i; name = R.cstr(d[so:so + 16])
            if name == "__const" and R.cstr(d[off + 8:off + 24]) == "__TEXT" and "__cstring" not in secs:
                d[so:so + 16] = b"__cstring".ljust(16, b"\0"); name = "__cstring"     # Rust binaries have no __cstring
            secs[name] = struct.unpack_from("<QQI", d, so + 32)
    addr, size, foff = secs["__text"]
    at = foff + (size // 2 & ~3)                         # plant in the middle of __text
    pc = lambda o: addr + o - foff
    w = lambda o, v: struct.pack_into("<I", d, o, v)
    # 2. pool reservations: two sites calling the same function
    target = addr
    for k in range(2):
        o = at + 64 * k
        w(o, 0x94000000 | (((target - pc(o)) >> 2) & 0x3ffffff))   # bl target
        w(o + 4, R.ARM_CMN_X0_1); w(o + 8, 0x54000040)                # cmn x0,#1 ; b.eq +8
        w(o + 12, R.ARM_ADD_X1_X0_X19)
    # 3. pool sizes
    o = at + 256
    for mov, nxt in ((0xd2c00088, 0xf90023e8), (0xd2c00209, 0xa90227e8), (0xd2c00109, 0xa900a7e8)):
        w(o, mov); w(o + 4, nxt); o += 16
    # 4. watchdog: message in __cstring, tbnz w0,#0,out ; adrp x1 ; add x1,x1 pointing at it
    caddr, csize, cfoff = secs["__cstring"]
    msg = b"!!! EngineWatchdog timeout!\n\0"; d[cfoff + 16:cfoff + 16 + len(msg)] = msg
    s = caddr + 16; o = at + 512
    w(o, 0x37000000 | (5 << 5))                                       # tbnz w0,#0,+20
    imm = ((s & ~0xfff) - (pc(o + 4) & ~0xfff)) >> 12
    w(o + 4, 0x90000001 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5))
    w(o + 8, 0x91000021 | ((s & 0xfff) << 10))
    # 5. Free prologue
    if addr <= R.FREE_ENTRY < addr + size - 24:
        for k, v in enumerate(R.FREE_PROLOGUE): w(foff + R.FREE_ENTRY - addr + 4 * k, v)
    open(dst, "wb").write(d)
    print("fixture: %s" % dst)


if __name__ == "__main__":
    if len(sys.argv) != 3: raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
