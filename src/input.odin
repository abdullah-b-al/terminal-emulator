package main

import rl "vendor:raylib"
import "core:unicode/utf8"
import "core:os"
import "core:fmt"
import "core:log"
import "core:strings"

handle_input :: proc(state: ^State, buffered_input: ^strings.Builder) {
    for ch := rl.GetCharPressed(); ch > 0; ch = rl.GetCharPressed() {
        if .canonical in state.modes {
            _, err := strings.write_rune(buffered_input, ch)
            if err != nil {
                log.error("input err: ", err)
                break
            }
        } else {
            bytes, len := utf8.encode_rune(ch)
            if _, err := os.write(os.Handle(state.pt_fd), bytes[:len]); err != nil {
                fmt.eprintln("writing to master err: ", err)
            }
        }
    }

    for key := rl.GetKeyPressed(); key != .KEY_NULL; key = rl.GetKeyPressed() {
        #partial switch key {
        case .BACKSPACE:
            if .canonical in state.modes {
                strings.pop_rune(buffered_input)
            } else {
                write_key(state, key)
            }

        case .ENTER:
            if .canonical in state.modes {
                strings.write_string(buffered_input, "\n")
                if _, err := os.write(os.Handle(state.pt_fd), buffered_input.buf[:]); err != nil {
                    fmt.eprintln("writing to master err: ", err)
                }
                strings.builder_reset(buffered_input)
            } else {
                write_key(state, key)
            }

        case:
            if .canonical not_in state.modes {
                write_key(state, key)
            }

        }
    }
}

key_table := map[rl.KeyboardKey]string{
.BACKSPACE = "\b",
.ENTER = "\r",
.TAB = "\t",

.F1 = "0;59",
.F2 = "0;60",
.F3 = "0;61",
.F4 = "0;62",
.F5 = "0;63",
.F6 = "0;64",
.F7 = "0;65",
.F8 = "0;66",
.F9 = "0;67",
.F10 ="0;68",
.F11 = "0;133",
.F12 = "0;134",

.ESCAPE = "\x1B",

.UP = "A",
.DOWN = "B",
.RIGHT = "C",
.LEFT = "D",
}

write_key :: proc(state: ^State, key: rl.KeyboardKey) {
    buf : [256]byte
    str, found := key_table[key]
    if !found do return

    key_sequence : string
    format := "\x1B[%s"
    if strings.contains(str, ";") {
        format = "\x1B[%sP"
    } else if strings.contains_any(str, "\r\b\t") {
        format = "%s"
    }

    key_sequence = fmt.bprintf(buf[:], format, str)
    // safe_log_sequence(transmute([]u8)key_sequence, level=.error)

    if _, err := os.write(os.Handle(state.pt_fd), transmute([]u8)(key_sequence)); err != nil {
        fmt.eprintln("writing to master err: ", err)
    }
}

