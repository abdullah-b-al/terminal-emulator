package main

import "core:sys/posix"
import "core:sys/linux"
import "core:fmt"

FD :: linux.Fd

open_pt :: proc() -> (FD, bool) {
    master_fd := posix.posix_openpt({.RDWR})
    if master_fd == -1 {
        return FD(master_fd), false
    }
    ok := posix.grantpt(master_fd)
    if int(ok) != 0 do return FD(-1), false
    ok = posix.unlockpt(master_fd)
    if int(ok) != 0 do return FD(-1), false

    return FD(master_fd), true
}

get_slave :: proc(master: FD) -> (FD, linux.Errno) {
    slave_path := posix.ptsname(posix.FD(master))
    slave, fd_err := linux.open(slave_path, {.RDWR}, {})
    return FD(slave), fd_err
}

open_pt_master_and_slave :: proc() -> (master : FD = -1, slave : FD = -1, ok : bool = false) {
    master = open_pt() or_return
    if slave, err := get_slave(master); err == linux.Errno.NONE {
        return master, slave, true
    }

    return
}
