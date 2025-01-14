package main

import rl "vendor:raylib"
import "core:strings"
import "core:fmt"
import "core:c"

render_screen :: proc(state: State, screen: ^Screen, buffered_input: string) {
    font_size : c.int = 20
    cell_width := rl.MeasureText("M", font_size)
    cell_height := font_size

    width := screen.cols * int(cell_width)
    height := screen.rows * int(cell_height)
    rl.SetWindowSize(c.int(width), c.int(height))

    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)

    if screen.cursor_visible {
        x := c.int(screen.cursor_col) * cell_width
        y := c.int(screen.cursor_row) * cell_height

        for ch in buffered_input {
            pos := [2]f32{f32(x),f32(y)}
            rl.DrawTextCodepoint(rl.GetFontDefault(), ch, pos, f32(font_size), rl.Color(screen.fg_color))
            x += cell_width
        }

        rl.DrawRectangle(x, y, cell_width, cell_height, rl.Color(screen.fg_color))
    }

    y : c.int
    x : c.int
    for row in 0..<screen.rows {
        for col in 0..<screen.cols {

            index := one_dim_index(row, col, screen.cols)
            cell := screen.cells[index]

            grid_color := rl.GRAY; grid_color.a = 0x0F;
            rl.DrawRectangleLines(x, y, cell_width, cell_height, grid_color)
            rl.DrawRectangle(x, y, cell_width, cell_height, rl.Color(cell.bg_color))
            if strings.builder_len(cell.grapheme) > 0 {
                cstr := strings.clone_to_cstring(
                    strings.to_string(cell.grapheme),
                    context.temp_allocator
                )

                if cstr != " " && cstr != "\n" && cstr != "\r" {
                    rl.DrawText(cstr, x,y, font_size, rl.Color(cell.fg_color))
                }
            }

            x += cell_width
        }

        y += cell_height
        x = 0
    }
    rl.EndDrawing()
}

one_dim_index :: proc(row, col, max_cols: int) -> int {
    return row * max_cols + col
}

two_dim_index :: proc(index, max_cols: int) -> (int, int) {
    row := index / max_cols
    col := index % max_cols
    return row, col
}
