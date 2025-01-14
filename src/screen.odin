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
    cells: []Cell,
    rows, cols: Screen_Pos,

    cursor_visible: bool,
    cursor_row, cursor_col: int,

    // State of rendering. Used to determine values for the current cell.
    graphics: Graphics_Set,
    fg_color: Color,
    bg_color: Color,
}

screen_init :: proc(rows, cols: Screen_Pos) -> (screen: Screen, error: mem.Allocator_Error) {
    cells := make([]Cell, rows * cols) or_return

    free_cells := false
    cells_inited := 0
    defer if free_cells {
        for &cell in cells[:cells_inited] do cell_destroy(&cell)
        delete(cells)
    }

    for &cell, i in cells {
        builder : strings.Builder
        _, err := strings.builder_init_none(&builder)
        if err != nil {
            free_cells = true
            return
        }
        cell = Cell{ grapheme = builder }
        cells_inited = i
    }

    return Screen{
        rows = rows,
        cols = cols,
        cells = cells,
        cursor_visible = true,
        fg_color = rgba_table[.white],
        bg_color = rgba_table[.black],
        graphics = {.line_wrapping}
    }, nil
}

screen_destroy :: proc(screen: ^Screen) {
    for &cell in screen.cells do cell_destroy(&cell)
    delete(screen.cells)
}

cell_destroy :: proc(cell: ^Cell) {
    strings.builder_destroy(&cell.grapheme)
}

screen_set_cell :: proc(screen: ^Screen, bytes: []byte) -> (runes_size: int) {
    cell_index := one_dim_index(screen.cursor_row , screen.cursor_col, screen.cols)
    if bytes[0] == '\n' {
        screen.cursor_row = min(screen.cursor_row + 1, screen.rows)
        screen.cursor_col = 0
    } else if .line_wrapping in screen.graphics {
        if screen.cursor_col == screen.cols {
            // FIXME: This will cause out of bounds indexing
            screen.cursor_row = min(screen.cursor_row + 1, screen.rows)
            screen.cursor_col = 0
        } else {
            screen.cursor_col += 1
        }
    } else if .line_wrapping not_in screen.graphics {
        if screen.cursor_col >= screen.cols {
            return
        } else if screen.cursor_col < screen.cols {
            screen.cursor_col += 1
        }
    }

    { // setting the cell
        if cell_index >= len(screen.cells) do return

        cell := &screen.cells[cell_index]
        strings.builder_reset(&cell.grapheme)

        ch : rune
        ch, runes_size = utf8.decode_rune(bytes)
        strings.write_rune(&cell.grapheme, ch)
        cell.fg_color = screen.fg_color
        cell.bg_color = screen.bg_color
        cell.graphics = screen.graphics
    }

    return
}

update_screen :: proc(state: State, screen: ^Screen) {
    buf: [512]byte
    buf_size, err := read_from_fd(state.pt_fd, buf[:])

    row, col : int
    i : int
    for i < buf_size {
        for i < buf_size && buf[i] != ESCAPE {
            i += screen_set_cell(screen, buf[i:])
        }

        loop: for i < buf_size {
            parser := parser_init(buf[i:buf_size])
            cmd, seq_len, err := parser_parse(&parser)

            switch err {
            case nil:
                apply_command(screen, cmd)
                i += seq_len
                break loop
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
            case .EOF:
                break loop
            }
        }
    }
}

@(private)
apply_command :: proc(screen: ^Screen, cmd: Command) {
    switch &data in cmd {
    case Command_Clear_Screen: log.error("Unimplemented command 'clear'")
    case Command_Move_Row_Col: log.error("Unimplemented command 'Command_Move_Row_Col'")
    case Command_Move: log.error("Unimplemented command 'Command_Move'")
    case Command_Move_Offset:
        switch data.wise {
        case .row:
            screen.cursor_row += data.offset
            // TOOO: check if I'm meant to bounds the value or scroll
            screen.cursor_row = max(screen.cursor_row, 0)
            screen.cursor_row = min(screen.cursor_row, screen.rows)
        case .col:
            screen.cursor_col += data.offset
            // TOOO: check if I'm meant to bounds the value or scroll
            screen.cursor_col = max(screen.cursor_col, 0)
            screen.cursor_col = min(screen.cursor_col, screen.cols)
        }

        if data.scroll {
            log.error("Unimplemented in command 'Command_Move_Offset.scroll'")
        }

        if data.begining_of_line {
            screen.cursor_col = 0
        }

    case Command_Set_Cursor_Visible:
        screen.cursor_visible = true
    case Command_Set_Cursor_Invisible:
        screen.cursor_visible = false

    case Command_Colors_Graphics:
        set_colors(screen, &data.colors)
    case Command_Color_Array:
        set_colors(screen, &data)
    case Command_Graphics:
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
