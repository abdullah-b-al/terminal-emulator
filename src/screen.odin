package main

import "core:strings"
import "core:fmt"
import "core:mem"
import "core:unicode/utf8"
import "core:log"
import sa "core:container/small_array"

rgba_table := [Color_Kind]Color {
    .black = {0x00, 0x00, 0x00, 0xFF},
    .red = {0xFF, 0x00, 0x00, 0xFF},
    .green = {0x00, 0xFF, 0x00, 0xFF},
    .yellow = {0xFF, 0xFF, 0x00, 0xFF},
    .blue = {0x00, 0x00, 0xFF, 0xFF},
    .magenta = {0xFF, 0x00, 0xFF, 0xFF},
    .cyan = {0x00, 0xFF, 0xFF, 0xFF},
    .white = {0xFF, 0xFF, 0xFF, 0xFF},
    .default = {0xFF, 0x00, 0x00, 0xFF},
    .reset = {0xFF, 0x00, 0x00, 0xFF},
}

Screen_Pos :: int
Color :: [4]u8
Color_Kind :: enum {
    reset,
    black,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    default,
}

Graphics_Kind :: enum{
    reset,
    bold,
    italic,
    dim,
    underline,
    blinking,
    strike_through,
    line_wrapping,
}

Graphics_Set :: bit_set[Graphics_Kind]
Grapheme_Handle :: distinct int

Cell :: struct {
    // TODO: Use a grapheme datatype instead of a string
    grapheme : strings.Builder,
    graphics: Graphics_Set,
    bg_color: Color,
    fg_color: Color,
}

Screen :: struct {
    cells: [][]Cell,

    cursor_visible: bool,
    cursor_row, cursor_col: int,

    font_size: int,
    cell_width: int,

    // State of rendering. Used to determine values for the current cell.
    graphics: Graphics_Set,
    fg_color: Color,
    bg_color: Color,
}

screen_init :: proc(width, height, font_size, cell_width: int) -> (screen: Screen, error: mem.Allocator_Error) {
    rows_count := int(height / font_size)
    cols_count := int(width / cell_width)

    rows := make([][]Cell, rows_count) or_return
    for _, i in rows {
        rows[i] = make([]Cell, cols_count) or_return
        for &cell in rows[i] {
            cell = cell_init()
        }
    }

    return Screen{
        cells = rows,
        cursor_visible = true,
        font_size = font_size,
        cell_width = cell_width,
        cursor_row = 1,
        cursor_col = 1,
        fg_color = rgba_table[.white],
        bg_color = rgba_table[.black],
        graphics = {.line_wrapping}
    }, nil
}

screen_destroy :: proc(screen: ^Screen) {
    for &row in screen.cells {
        for &cell in row do cell_destroy(&cell)
        delete(row)
    }
    delete(screen.cells)
}

screen_rows :: proc(screen: Screen) -> int {
    return len(screen.cells)
}

screen_cols :: proc(screen: Screen) -> int {
    assert(len(screen.cells) > 0) // there must always be at least one row and col 
    return len(screen.cells[0])
}

cell_init :: proc(loc := #caller_location) -> Cell {
    builder : strings.Builder
    strings.builder_init_none(&builder, context.allocator, loc)
    return Cell{ grapheme = builder }
}

cell_destroy :: proc(cell: ^Cell) {
    strings.builder_destroy(&cell.grapheme)
}

screen_set_cell :: proc(screen: ^Screen, bytes: []byte) -> (runes_size: int) {
    assert(len(bytes) > 0)

    if screen.cursor_row > screen_rows(screen^) {
        diff := diff(screen.cursor_row, screen_rows(screen^))
        screen_scroll(screen, diff)
        screen.cursor_row = screen_rows(screen^)
    }

    { // setting the cell
        ch : rune
        ch, runes_size = utf8.decode_rune(bytes)

        row := screen.cells[screen.cursor_row - 1] // turn to 0-based
        cell := &row[screen.cursor_col - 1] // turn to 0-based
        strings.builder_reset(&cell.grapheme)

        strings.write_rune(&cell.grapheme, ch)
        cell.fg_color = screen.fg_color
        cell.bg_color = screen.bg_color
        cell.graphics = screen.graphics
    }

    if bytes[0] == '\n' {
        // screen.cursor_row = min(screen.cursor_row + 1, screen_rows(screen^))
        screen.cursor_row += 1
    } else if bytes[0] == '\r' {
        screen.cursor_col = 1
    } else if .line_wrapping in screen.graphics {
        if screen.cursor_col == screen_cols(screen^) {
            screen.cursor_row += 1
            screen.cursor_col = 1
        } else {
            screen.cursor_col += 1
        }
    } else if .line_wrapping not_in screen.graphics {
        if screen.cursor_col <= screen_cols(screen^) {
            screen.cursor_col += 1
        }
    }

    return
}

screen_scroll :: proc(screen: ^Screen, rows: int) {
    assert(rows > 0)
    rows := min(rows, screen_rows(screen^))

    // delete the rows to scroll out of the screen
    // but as an optimization reuse the "deleted" rows

    offset := rows
    end := screen_rows(screen^) - offset
    for i in 0..<end {
        tmp := screen.cells[i]
        screen.cells[i] = screen.cells[i + offset]
        screen.cells[i + offset] = tmp
    }

    // reset reused rows
    for row in screen.cells[end:] {
        for &cell in row {
            strings.builder_reset(&cell.grapheme)
        }
    }
    // destroyed := rows
    // for row in 0..<destroyed {
    //     for &cell in screen.cells[row] do cell_destroy(&cell)
    //     delete(screen.cells[row])
    // }

    // copied := 0
    // for row in screen.cells[destroyed:] {
    //     screen.cells[copied] = row
    //     copied += 1
    // }

    // for &row, i in screen.cells[copied:] {
    //     row = make([]Cell, screen_cols(screen^))
    //     for &cell in row {
    //         cell = cell_init()
    //     }
    // }
}

update_screen :: proc(state: ^State) {
    buf: [512]byte
    buf_size, err := read_from_fd(state.pt_fd, buf[:])

    row, col : int
    i : int
    for i < buf_size {
        screen : ^Screen
        switch state.focus_on {
        case .primary: screen = &state.primary
        case .alternate: screen = &state.alternate
        }

        for i < buf_size && buf[i] != ESCAPE {
            i += screen_set_cell(screen, buf[i:])
        }

        loop: for i < buf_size {
            parser := parser_init(buf[i:buf_size])
            cmd, seq_len, err := parser_parse(&parser)
            switch e in err {
            case nil:
                apply_command(state, screen, cmd)
                i += seq_len
                break loop
            case ParseError: switch e {
                case .Incomplete_Sequence:

                    safe_log_sequence(buf[i:buf_size], "Incomplete sequence", .info)
                    buf_size = copy(buf[:], buf[i:buf_size])
                    read, err := read_from_fd(state.pt_fd, buf[buf_size:])
                    buf_size += read
                    i = 0
                    continue loop

                case .Invalid_Sequence, .Unknown_Sequence:
                    // display the sequence on the screen
                    i += screen_set_cell(screen, buf[i:])
                    break loop
                case .Unsupported_Sequence:
                    i += seq_len
                    break loop
                case .EOF:
                    break loop
                }

            case mem.Allocator_Error:
                log.error("Allocator_Error:", e)
            }
        }
    }
}

@(private)
apply_command :: proc(state: ^State, screen: ^Screen, cmd: Command) {
    switch &data in cmd {
    case Command_Clear_Screen: log.error("Unimplemented command 'clear'")
    case Command_Move_Row_Col:
        screen.cursor_row = data.row
        screen.cursor_col = data.col
        screen.cursor_row = bound(screen.cursor_row, 1, screen_rows(screen^))
        screen.cursor_col = bound(screen.cursor_col, 1, screen_cols(screen^))
    case Command_Move:
        switch data.wise {
        case .row:
            screen.cursor_row = data.pos
            screen.cursor_row = bound(screen.cursor_row, 1, screen_rows(screen^))
        case .col:
            screen.cursor_col = data.pos
            screen.cursor_col = bound(screen.cursor_col, 1, screen_cols(screen^))
        }
    case Command_Move_Offset:
        switch data.wise {
        case .row:
            screen.cursor_row += data.offset
            // TOOO: check if I'm meant to bounds the value or scroll
            screen.cursor_row = bound(screen.cursor_row, 1, screen_rows(screen^))
        case .col:
            screen.cursor_col += data.offset
            // TOOO: check if I'm meant to bounds the value or scroll
            screen.cursor_col = bound(screen.cursor_col, 1, screen_cols(screen^))
        }

        if data.scroll {
            log.error("Unimplemented in command 'Command_Move_Offset.scroll'")
        }

        if data.begining_of_line {
            screen.cursor_col = 1
        }

    case Command_Set_Alternate_Screen:
        state.focus_on = .alternate if data else .primary
        log.debug("Set", state.focus_on, "screen")
    case Command_Set_Cursor_Visible:
        screen.cursor_visible = bool(data)
    case Command_Colors_Graphics:
        set_colors(screen, &data.colors)
    case Command_Color_Array:
        set_colors(screen, &data)
    case Command_Graphics:
        defer log.debug("Current Graphics: ", screen.graphics)
        if data.set {
            for g in sa.slice(&data.graphics) {
                if g == .reset {
                    screen.graphics = {}
                } else {
                    screen.graphics += {g}
                }
            }
        } else {
            for g in sa.slice(&data.graphics) {
                if g == .reset {
                    screen.graphics = {}
                } else {
                    screen.graphics -= {g}
                }
            }
        }
    }
}

@(private)
set_colors :: proc(screen: ^Screen, colors: ^Command_Color_Array) {
    for entry in sa.slice(colors) {
        color := rgba_table[entry.kind]
        if !entry.bright {
            color.a = 0x7F
        }
        switch entry.layer {
        case .fg: screen.fg_color = color
        case .bg: screen.bg_color = color
        }
    }
}

@(private)
diff :: proc(a: int, b: int) -> int {
    return a - b if a >= b else b - a
}

@(private)
bound ::proc(a, low, high: int) -> int {
    a := max(a, low)
    a = min(a, high)
    return a
}
