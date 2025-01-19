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
import "core:unicode/utf8"
import sa "core:container/small_array"
import "base:runtime"

Mode :: enum {
    echo,
    canonical,
}
Modes :: bit_set[Mode]

mode_map := map[posix.CLocal_Flag_Bits]Mode {
    .ECHO = .echo,
    .ICANON = .canonical,
}

State :: struct {
    // Writing to this will send data to the slave
    // reading will receive data from the slave
    pt_fd: FD,
    primary: Screen,
    alternate: Screen,
    focus_on: enum{primary, alternate},
    modes: Modes,
}

enable_raw_mode :: proc() {
    raw : posix.termios
    posix.tcgetattr(posix.STDIN_FILENO, &raw);
    raw.c_lflag -= {posix.CLocal_Flag_Bits.ECHO}
    posix.tcsetattr(posix.STDIN_FILENO, posix.TC_Optional_Action.TCSAFLUSH, &raw);
}

set_termios :: proc(state: ^State) {
    raw : posix.termios
    posix.tcgetattr(posix.FD(state.pt_fd), &raw);
    modes : Modes
    for flag in raw.c_lflag {
        modes += {mode_map[flag]}
    }
    state.modes = modes
}

main :: proc() {

    context.logger = log.create_console_logger(lowest = log.Level.Info)

    // str := "\x1B[1;3m hello there"
    // commands := "\x1B[5B\x1B[1;31mRed Hello"

    track : mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer tracking_allocator_report(track)

    state : State
    state.modes = {.echo, .canonical}

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
        _, err := linux.setsid()
        if err != linux.Errno.NONE do panic("setsid failed")
        linux.dup2(slave_fd, 0)
        linux.dup2(slave_fd, 1)
        linux.dup2(slave_fd, 2)
        if slave_fd > 2 do linux.close(slave_fd)
        start_program(sa.slice(&argv))
    case: // parent
        linux.close(slave_fd) // not needed in the master
        start_ui(&state)
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

start_ui :: proc(state: ^State) {
    rl.SetConfigFlags({.WINDOW_RESIZABLE})
    rl.InitWindow(1000, 1000, "TestWindow")
    rl.SetExitKey(.KEY_NULL)
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    buffered_input := strings.builder_make();
    defer strings.builder_destroy(&buffered_input)

    // arena : mem.Dynamic_Arena
    // mem.dynamic_arena_init(&arena)
    // defer mem.dynamic_arena_destroy(&arena)
    // arena_allocator := mem.dynamic_arena_allocator(&arena)
    // context_alloctor := context.allocator

    {
        font_size := 15
        cell_width := int(rl.MeasureText("M", c.int(font_size)))
        width := int(rl.GetScreenWidth())
        height := int(rl.GetScreenHeight())
        screen, error := screen_init(width, height, font_size, cell_width)
        state.primary = screen

        screen, error = screen_init(width, height, font_size, cell_width)
        state.alternate = screen
    }

    defer {
        screen_destroy(&state.primary)
        screen_destroy(&state.alternate)
    }

    for ! rl.WindowShouldClose() {
        set_termios(state)
        if rl.IsWindowResized() {
            new_rows := int(rl.GetScreenHeight()) / state.primary.font_size
            new_cols := int(rl.GetScreenWidth()) / state.primary.cell_width
            // screen_resize(&state.primary, new_rows, new_cols)
            // screen_resize(&state.alternate, new_rows, new_cols)
        }

        handle_input(state, &buffered_input)

        update_screen(state)
        // context.allocator = arena_allocator
        screen : ^Screen
        switch state.focus_on {
        case .primary: screen = &state.primary
        case .alternate: screen = &state.alternate
        }
        render_screen(state^, screen, strings.to_string(buffered_input))
        // context.allocator = context_alloctor

        free_all(context.temp_allocator)
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
        size, error = io.read(stream, buf)
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
    }

    if len(track.allocation_map) > 0 {
        for _, entry in track.allocation_map {
            fmt.eprintf("- %v bytes @ %v %v\n", entry.size, entry.location, entry.location.procedure)
        }
    }

    if len(track.bad_free_array) > 0 {
        fmt.eprintf("=== %v incorrect frees: ===\n", len(track.bad_free_array))
        for entry in track.bad_free_array {
            fmt.eprintf("- %p @ %v %v\n", entry.memory, entry.location, entry.location.procedure)
        }
    }
}
