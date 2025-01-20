package main

import "core:strings"
import "core:fmt"
import "core:mem"
import "core:unicode/utf8"
import "core:log"
import sa "core:container/small_array"

Scroll_Dir :: enum {
    down,
    up
}

rgba_table := [Color_Kind]Color {
    .black = {0x00, 0x00, 0x00, 0xFF},
    .red = {0xFF, 0x00, 0x00, 0xFF},
    .green = {0x00, 0xFF, 0x00, 0xFF},
    .yellow = {0xFF, 0xFF, 0x00, 0xFF},
    .blue = {0x00, 0x00, 0xFF, 0xFF},
    .magenta = {0xFF, 0x00, 0xFF, 0xFF},
    .cyan = {0x00, 0xFF, 0xFF, 0xFF},
    .white = {0xFF, 0xFF, 0xFF, 0xFF},
    .default = {0x00, 0x00, 0x00, 0xFF},
    .reset = {0x00, 0x00, 0x00, 0x00},
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
    auto_scroll, // should we scroll if we reach the end of the screen
    line_wrap, // should the cursor wrap to the next line
}

Graphics_Set :: bit_set[Graphics_Kind]

Cell :: struct {
    // TODO: Use a grapheme datatype instead of a string
    grapheme : strings.Builder,
    graphics: Graphics_Set,
    bg_color: Color,
    fg_color: Color,
}

Screen :: struct {
    cells: [][]Cell,
    // range of rows
    scrolling_region: [2]int,

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
        scrolling_region = {1, rows_count},
        cursor_visible = true,
        font_size = font_size,
        cell_width = cell_width,
        cursor_row = 1,
        cursor_col = 1,
        fg_color = rgba_table[.white],
        bg_color = rgba_table[.black],
        graphics = {.auto_scroll}
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

cell_reset :: proc(cell: ^Cell, screen: Screen) {
    strings.builder_reset(&cell.grapheme)
    cell.fg_color = screen.fg_color
    cell.bg_color = screen.bg_color
    cell.graphics = screen.graphics
}

cell_destroy :: proc(cell: ^Cell) {
    strings.builder_destroy(&cell.grapheme)
}

screen_set_cell :: proc(screen: ^Screen, bytes: []byte) -> (runes_size: int) {
    assert(len(bytes) > 0)

    {
        row := screen.cells[screen.cursor_row - 1] // turn to 0-based
        cell := &row[screen.cursor_col - 1] // turn to 0-based
        cell_reset(cell, screen^)
        decode_bytes(bytes, &cell.grapheme)
        runes_size = strings.builder_len(cell.grapheme)
    }

    for byte in bytes[:runes_size] {
        switch byte {
        case '\n': cursor_move(screen, screen.cursor_row + 1, screen.cursor_col)
        case '\r': cursor_move(screen, screen.cursor_row, 1)
        }
    }

    if .line_wrap in screen.graphics {
        if screen.cursor_col == screen_cols(screen^) {
            cursor_move(screen, screen.cursor_row + 1, 1)
        } else {
            cursor_move(screen, screen.cursor_row, screen.cursor_col + 1)
        }
    } else if bytes[0] != '\r' {
        cursor_move(screen, screen.cursor_row, screen.cursor_col + 1)
    }

    if .auto_scroll in screen.graphics {
        if screen.cursor_row > screen_rows(screen^) {
            diff := screen.cursor_row - screen_rows(screen^)
            screen_scroll_whole(screen, .down, diff)
            cursor_move(screen, screen.cursor_row, screen.cursor_col)
        }
    } else {
        cursor_move(screen, screen.cursor_row, screen.cursor_col)
    }

    return
}

screen_scroll_whole :: proc (screen: ^Screen, dir : Scroll_Dir, count: int) {
    start := screen.scrolling_region[0]
    end := screen.scrolling_region[1]
    screen_scroll_region(screen, dir, count, start, end)
}

/* scroll the specified (inclusive) row range. */
screen_scroll_region :: proc(screen: ^Screen, dir: Scroll_Dir, count, start, end: int) {
    end := min(end, screen_rows(screen^))

    assert(end >= start)
    assert(start >= 1)
    assert(count > 0)

    cells := screen.cells[start - 1:end] // to 0-based. Inclusive range

    count := min(count, len(cells))
    deleted := make([dynamic][]Cell, 0, count)
    defer {
        if len(deleted) > 0 do panic("Leaked some rows")
        delete(deleted)
    }

    if end == start {
        screen_erase_rows(screen, start, end)
        return
    }

    switch dir {
    case .down: // screen moves down, text moves up
        // delete top rows
        for row in 0..<count {
            append(&deleted, cells[row])
        }

        offset := len(deleted)
        // move valid rows up
        copy(cells, cells[offset:])

        last_valid_row := len(cells) - offset
        for row in last_valid_row..<len(cells) {
            new_row := pop(&deleted)
            for &cell in new_row do cell_reset(&cell, screen^)
            cells[row] = new_row
        }

    case .up: // screen moves up, text moves down
        // delete bottom rows
        last_valid_row := len(cells) - count
        for row in last_valid_row..<len(cells) {
            append(&deleted, cells[row])
        }

        // move valid rows down
        for i := len(cells) - 1; i - count >= 0; i -= 1 {
            cells[i] = cells[i - count]
        }

        for row in 0..<count {
            new_row := pop(&deleted)
            for &cell in new_row do cell_reset(&cell, screen^)
            cells[row] = new_row
        }
    }
}

update_screen :: proc(state: ^State) -> bool {
    buf: [512]byte
    buf_size, err := read_from_fd(state.pt_fd, buf[:])
    if buf_size == 0 do return false

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

                    // safe_log_sequence(buf[i:buf_size], "Incomplete sequence", .info)
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

    return true
}

/* clear the specified (inclusive) col range. */
screen_erase_cols :: proc(screen: ^Screen, row, start, end: int) {
    assert(end >= start)
    assert(row <= screen_rows(screen^))
    assert(row > 0)
    cols := screen.cells[row - 1]

    for &cell in cols[start-1:end] {
        cell_reset(&cell, screen^)
    }
}


/* clear the specified (inclusive) row range. */
screen_erase_rows :: proc(screen: ^Screen, start, end: int) {
    assert(end >= start)

    for row in start..=end {
        for &cell in screen.cells[row - 1] {
            cell_reset(&cell, screen^)
        }
    }
}

@(private)
apply_command :: proc(state: ^State, screen: ^Screen, cmd: Command) {
    switch &data in cmd {
    case Command_Clear_Screen: log.error("Unimplemented command 'clear'")
    case Command_Move_Row_Col:
        cursor_move(screen, data.row, data.col)
    case Command_Move:
        row := screen.cursor_row
        col := screen.cursor_col
        switch data.wise {
        case .row: row = data.pos
        case .col: col = data.pos
        }

        cursor_move(screen, row, col)
    case Command_Move_Offset:
        row := screen.cursor_row
        col := screen.cursor_col
        switch data.wise {
        case .row: row += data.offset
        case .col: col += data.offset
        }

        cursor_move(screen, row, col)

        if data.scroll {
            if data.offset > 0 {
                screen_scroll_whole(screen, .down, data.offset)
            } else {
                screen_scroll_whole(screen, .up, -data.offset) // make it Positive
            }
        }

        if data.begining_of_line {
            cursor_move(screen, screen.cursor_row, screen.cursor_col)
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
        log.debug("Graphics Before: ", screen.graphics)
        defer log.debug("Graphics Now: ", screen.graphics)
        if data.set {
            for g in sa.slice(&data.graphics) {
                screen.graphics += {g}
                if g == .reset do screen.graphics = {}
            }
        } else {
            for g in sa.slice(&data.graphics) {
                screen.graphics -= {g}
                if g == .reset do screen.graphics = {}
            }
        }

    case Command_Erase:
        start := 1
        end := 1
        switch data.dir {
        case .after:
            start = screen.cursor_row if data.wise == .row else screen.cursor_col
            end = screen_rows(screen^) if data.wise == .row else screen_cols(screen^)
        case .before:
            start = 1
            end = screen.cursor_row if data.wise == .row else screen.cursor_col
        case .all:
            start = 1
            end = screen_rows(screen^) if data.wise == .row else screen_cols(screen^)
        }

        switch data.wise {
        case .row: screen_erase_rows(screen, start, end)
        case .col: screen_erase_cols(screen, screen.cursor_row, start, end)
        }
        

    case Command_Insert_Blank_Lines:
        start := screen.cursor_row
        screen_scroll_region(screen, .up, int(data), start, screen_rows(screen^))

    case Command_Set_Scrolling_Region:
        screen.scrolling_region = data
    } // end of switch

}

decode_bytes :: proc(bytes: []byte, builder: ^strings.Builder) {
    assert(len(bytes) > 0)
    switch bytes[0] {
    case '\r', '\n':
        loop: for byte in bytes {
            switch byte {
            case '\r','\n':
                strings.write_rune(builder, rune(byte))
            case: break loop
            }
        }
    case:
        ch, _ := utf8.decode_rune(bytes)
        strings.write_rune(builder, ch)
    }
}

@(private)
cursor_move :: proc(screen: ^Screen, row, col: int, loc := #caller_location) {
    screen.cursor_row = bound(row, 1, screen_rows(screen^))
    screen.cursor_col = bound(col, 1, screen_cols(screen^))
    log.debug("Cursor moved:", screen.cursor_row, screen.cursor_col, location = loc)
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
