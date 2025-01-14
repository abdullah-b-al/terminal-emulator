package main

import rl "vendor:raylib"
import "core:fmt"
import "core:sys/posix"
import "core:sys/linux"
import "core:strings"
import "core:mem"
import "core:os"
import "core:time"
import "core:io"
import "core:c"
import "core:log"
import sa "core:container/small_array"
import "core:unicode/utf8"
import "base:runtime"

State :: struct {
    // Writing to this will send data to the slave
    // reading will receive data from the slave
    pt_fd : FD,
}

enable_raw_mode :: proc() {
    raw : posix.termios
    posix.tcgetattr(posix.STDIN_FILENO, &raw);
    raw.c_lflag -= {posix.CLocal_Flag_Bits.ECHO}
    posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw);
}

main :: proc() {

    context.logger = log.create_console_logger()

    // str := "\x1B[1;3m hello there"
    // commands := "\x1B[5B\x1B[1;31mRed Hello"

    track : mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer tracking_allocator_report(track)

    state : State

    // program := transmute(string)program_buf[:program_buf_size]
    argv : sa.Small_Array(256, string)

    // program : sa.Small_Array(256, string)
    if len(os.args) >= 2 {
        for arg in os.args[1:] {
            sa.append(&argv, arg)
        }
    } else {
        shell := os.get_env("SHELL")
        defer delete(shell)
        str := shell if len(shell) > 0 else "/bin/sh"
        sa.set(&argv, 0, str)
    }

    m, slave_fd, ok := open_pt_master_and_slave()
    if !ok {
        fmt.eprintln("open_pt failed")
        return
    }

    state.pt_fd = m


    pid := posix.fork()
    switch pid {
    case -1: // fail
        fmt.println("Opps forking failed.")
        os.exit(1)
    case 0: // child
        linux.close(state.pt_fd) // not needed in the child
        linux.setsid()
        linux.dup2(slave_fd, 0)
        linux.dup2(slave_fd, 1)
        linux.dup2(slave_fd, 2)
        if slave_fd > 2 do linux.close(slave_fd)
        start_program(sa.slice(&argv))
    case: // parent
        linux.close(slave_fd) // not needed in the master
        start_ui(state)
        linux.close(state.pt_fd)
    }
}

start_program :: proc (argv: []string) -> mem.Allocator_Error {
    envp := posix.environ
    args := clone_strings_to_cstring(argv)
    defer {
        for s in args do delete(s)
        delete(args)
    }

    err := linux.execve(args[0], &args[0], &envp[0])
    if i32(err) == -1 {
        fmt.println("opps")
    }
    fmt.println(err, posix.get_errno())

    fmt.println("nil")
    return nil
}

start_ui :: proc(state: State) {
    rl.InitWindow(1000, 1000, "Hello there!")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    input := strings.builder_make();
    defer strings.builder_destroy(&input)

    // arena : mem.Dynamic_Arena
    // mem.dynamic_arena_init(&arena)
    // defer mem.dynamic_arena_destroy(&arena)
    // arena_allocator := mem.dynamic_arena_allocator(&arena)
    // context_alloctor := context.allocator

    screen, error := screen_init(50, 100)
    defer screen_destroy(&screen)

    for ! rl.WindowShouldClose() {

        defer strings.builder_reset(&input)
        for ch := rl.GetCharPressed(); ch > 0; ch = rl.GetCharPressed() {
            _, err := strings.write_rune(&input, ch)
            if err != nil {
                fmt.eprintln("input err: ", err)
                break
            }
        }

        if rl.IsKeyPressed(.ENTER) {
            strings.write_rune(&input, rune('\n'))
        }

        if _, err := os.write(os.Handle(state.pt_fd), input.buf[:]); err != nil {
            fmt.eprintln("writing to master err: ", err)
        }

        update_screen(state, &screen)

        // context.allocator = arena_allocator
        render_screen(state, &screen)
        // context.allocator = context_alloctor
    }
}

clone_strings_to_cstring :: proc(strs: []string) -> []cstring {
    result := make([]cstring, len(strs) + 1)
    for str, i in strs do result[i] = strings.clone_to_cstring(str)
    result[len(strs)] = nil
    return result
}

read_from_fd :: proc(fd : FD, buf: []byte) -> (size: int, error: io.Error) {
    pollfd := [1]linux.Poll_Fd{
        {fd = fd, events = {.IN}}
    }
    for {
        n : i32 = -1
        errno := linux.Errno.NONE
        for n, errno = linux.poll(pollfd[:], 10); true; {
            if n == 0 do return // poll timed out
            else if n > 0 do break // event detected
            else if errno == linux.Errno.EAGAIN || errno == linux.Errno.EINTR {
                continue
            }
        }

        stream := os.stream_from_handle(os.Handle(fd))
        size, error = io.read_at_least(stream, buf, len(buf))
        return
    }

}

print_from_fd :: proc(fd: FD) {
    buf :[256]byte
    str, _ := read_from_fd(fd, buf[:])
    fmt.print(str)
}

tracking_allocator_report :: proc(track: mem.Tracking_Allocator) {
    if len(track.allocation_map) > 0 {
        fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
        for _, entry in track.allocation_map {
            fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
        }
    }
    if len(track.bad_free_array) > 0 {
        fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
        for entry in track.bad_free_array {
            fmt.eprintf("- %p @ %v\n", entry.memory, entry.location)
        }
    }
}
