package main

import "core:log"
import "core:fmt"
import sa "core:container/small_array"

ESCAPE :: 0x1B

@(private)
is_command :: proc(r: rune) -> bool {
    // letters only
    command_byte_cursor_control :: "HfABCDEFGnMsu"
    command_byte_colors :: "m"
    command_bytes :: command_byte_cursor_control + command_byte_colors + "lh"

    for byte in command_bytes {
        if r == byte do return true
    }
    return false
}
COMMAND_ARRAY_SIZE :: 64
Command_Color_Array :: sa.Small_Array(COMMAND_ARRAY_SIZE, Command_Color)
Command_Graphics_Array :: sa.Small_Array(COMMAND_ARRAY_SIZE, Graphics_Kind)

Command_Color :: struct {
    kind: Color_Kind,
    layer: enum{fg, bg},
    bright: bool,
}

Command_Move_Row_Col :: struct {
    row, col : Screen_Pos,
}

Command_Move :: struct {
    pos : Screen_Pos,
    wise: enum{row, col},
}

Command_Move_Offset :: struct {
    offset: Screen_Pos,
    wise: enum {row, col},
    begining_of_line: bool,
    scroll: bool,
}

Command_Erase_Dir :: enum {
    after,
    before,
    all,
}
Command_Erase :: struct {
    wise : enum{row, col},
    dir: Command_Erase_Dir,
}

Command_Insert_Blank_Lines :: distinct int

Command_Set_Scrolling_Region :: [2]int

Command_Colors_Graphics :: struct{
    colors: Command_Color_Array,
    graphics: Command_Graphics_Array,
}

Command_Graphics :: struct {
    graphics: Command_Graphics_Array,
    set: bool,
}

Command_Clear_Screen :: struct {}
Command_Set_Cursor_Visible :: distinct bool
Command_Set_Alternate_Screen :: distinct bool

Command :: union {
    Command_Clear_Screen,
    Command_Move_Row_Col,
    Command_Move,
    Command_Move_Offset,
    Command_Colors_Graphics,
    Command_Graphics,
    Command_Color_Array,
    Command_Set_Cursor_Visible,
    Command_Set_Alternate_Screen,
    Command_Erase,
    Command_Insert_Blank_Lines,
    Command_Set_Scrolling_Region,
}

safe_log_sequence :: proc(buf: []byte, prefix := "Unknown sequence", level: enum{error, info} = .error,location := #caller_location) {
    length := min(len(buf), 64)
    sequence : [512]byte
    seq_len := 0

    escape_count := 0
    loop: for b in buf[:length] {
        switch b {
        case ESCAPE:
            if escape_count > 0 do break loop
            seq_len += len(fmt.bprint(sequence[seq_len:], " ESC"))
            escape_count = 1
        case ' ', '\t', '\r', '\n':
            break loop
        case:
            seq_len += len(fmt.bprintf(sequence[seq_len:], "%c", b))
        }

        if seq_len >= len(sequence) do break
    }
    switch level {
    case .error: log.errorf("%s:%s", prefix, sequence[:seq_len], location = location)
    case .info: log.infof("%s:%s", prefix, sequence[:seq_len], location = location)
    }
    
}

@(private)
get_from_table :: proc(buf: []byte, table: []$T) -> (Command, bool) {
    for item in table {
        if item.key == transmute(string)buf do return item.value, true
    }

    return {}, false
}
