package main

import "core:log"
import "core:strings"
import "core:fmt"
import "core:mem"
import "core:io"
import "core:strconv"
import "core:slice"
import sa "core:container/small_array"

@(private="file")
Byte_SA :: sa.Small_Array(256, byte)
Bytes_SA :: sa.Small_Array(256, []byte)

colors_standard_table := map[string]Command_Color {
"0" = { kind = .reset, layer = .fg },

"30" = { kind = .black, layer = .fg },
"31" = { kind = .red, layer = .fg },
"32" = { kind = .green, layer = .fg },
"33" = { kind = .yellow, layer = .fg },
"34" = { kind = .blue, layer = .fg },
"35" = { kind = .magenta, layer = .fg },
"36" = { kind = .cyan, layer = .fg },
"37" = { kind = .white, layer = .fg },

"39" = { kind = .default, layer = .fg },

"40" = { kind = .black, layer = .bg },
"41" = { kind = .red, layer = .bg },
"42" = { kind = .green, layer = .bg },
"43" = { kind = .yellow, layer = .bg },
"44" = { kind = .blue, layer = .bg },
"45" = { kind = .magenta, layer = .bg },
"46" = { kind = .cyan, layer = .bg },
"47" = { kind = .white, layer = .bg },

"49" = { kind = .default, layer = .bg },
}

colors_256_table := map[string]Command_Color{
"0" = { kind = .black, bright = false},
"1" = { kind = .red, bright = false},
"2" = { kind = .green, bright = false},
"3" = { kind = .yellow, bright = false},
"4" = { kind = .blue, bright = false},
"5" = { kind = .magenta, bright = false},
"6" = { kind = .cyan, bright = false},
"7" = { kind = .white, bright = false},

"8" = { kind = .black, bright = true},
"9" = { kind = .red, bright = true},
"10" = { kind = .green, bright = true},
"11" = { kind = .yellow, bright = true},
"12" = { kind = .blue, bright = true},
"13" = { kind = .magenta, bright = true},
"14" = { kind = .cyan, bright = true},
"15" = { kind = .white, bright = true},
}

graphics_table := map[string]Graphics_Kind{
"0" = .reset,
"1" = .bold,
"2" = .dim,
"3" = .italic,
"4" = .underline,
"5" = .blinking,
"9" = .strike_through,
}



ParseError :: enum {
    Incomplete_Sequence,
    Invalid_Sequence,
    Unknown_Sequence,
    EOF,
}

Error :: union {
    ParseError,
    mem.Allocator_Error,
}

Parser :: struct {
    data: []byte,
    offset: int,
    char: byte,
}

parser_init :: proc(bytes: []byte) -> Parser {
    assert(len(bytes) > 0)
    return Parser{
        data = bytes,
        offset = 0,
        char = bytes[0],
    }
}

parser_advance :: proc(parser: ^Parser) {
    parser.offset += 1
    if parser.offset >= len(parser.data) {
        parser.char = 0
        return
    }
    parser.char = parser.data[parser.offset]
}

parser_peek_rune :: proc(parser: Parser) -> (ch: byte, err: Error) {
    p := parser
    parser_advance(&p)
    if p.char == 0 do err = .EOF
    return p.char, err
}

parser_parse :: proc(parser: ^Parser) -> (cmd: Command, seq_length: int, error: Error) {
    switch ch := parser.char; ch {
    case ESCAPE: {
        parser_advance(parser)
        switch parser.char {
        case '[':
            err : Error = nil
            cmd, err = parse_csi(parser)
            if err != nil do return {}, parser.offset, err
        case ']':
            safe_log_sequence(parser.data)
            return {}, parser.offset, ParseError.Unknown_Sequence
        case:
            safe_log_sequence(parser.data)
            return {}, parser.offset, ParseError.Unknown_Sequence
        }
    }

    case: return {}, parser.offset, ParseError.Invalid_Sequence
    }

    seq_length = parser.offset
    return
}

parse_csi :: proc(parser: ^Parser) -> (cmd: Command, error: Error) {
    assert(parser.char == '[')
    parser_advance(parser)

    // the parsed rest of the sequence
    split : Bytes_SA
    joined : Byte_SA


    // parse args
    swi: switch ch := parser.char; ch {
    case '0'..='9':
        parser_collect_and_slice_args(parser, &split, &joined)

    case '?':
        parser_advance(parser)
        sa.append(&split, transmute([]u8)string("?"))
        sa.append(&joined, '?')
        parser_collect_and_slice_args(parser, &split, &joined)
    }

    // parse commands
    switch ch := parser.char; ch {
    case 0: return {}, .Incomplete_Sequence

    case 'H':
        parser_advance(parser)
        switch sa.len(split) {
        case 0:
            return Command_Move_Row_Col{row=0,col=0}, nil
        case 2:
            row := parse_int(transmute(string)sa.get(split, 0), .Invalid_Sequence) or_return
            col := parse_int(transmute(string)sa.get(split, 1), .Invalid_Sequence) or_return
            return Command_Move_Row_Col{row=row,col=col}, nil
        case:
            safe_log_sequence(parser.data)
            return {}, .Unknown_Sequence
        }

    case 'A'..='G':
        parser_advance(parser)
        if sa.len(split) != 1 { // expect one argument
            return {}, nil
        }

        number := parse_int(transmute(string)sa.get(split, 0), .Invalid_Sequence) or_return
        switch ch {
        case 'A': cmd = Command_Move_Offset{offset=(-number), wise=.row} // up
        case 'B': cmd = Command_Move_Offset{offset=number, wise=.row} // down

        case 'C': cmd = Command_Move_Offset{offset=number, wise=.col} // right
        case 'D': cmd = Command_Move_Offset{offset=(-number), wise=.col} // left

        case 'E': cmd = Command_Move_Offset{offset=number, wise=.row, begining_of_line = true} // down
        case 'F': cmd = Command_Move_Offset{offset=(-number), wise=.row, begining_of_line = true} // up

        case 'G': cmd = Command_Move{pos=number, wise=.col}

        case: panic("We shouldn't be here!")
        }

        error = nil
        return

    case 'm':
        parser_advance(parser)

        joined_str := string(sa.slice(&joined))
        joined_sub := joined_str[:5] if len(joined_str) >= 5 else joined_str
        switch joined_sub {
            case "38;5;", "48;5;":
                key, ok := sa.get_safe(split, 2)
                if !ok {
                    safe_log_sequence(parser.data, "Invalid Sequence")
                    return {}, .Invalid_Sequence
                }

                color, found := colors_256_table[string(key)]
                if !found {
                    safe_log_sequence(parser.data, "Unknown color")
                    return {}, nil
                }

                layer := string(sa.get(split, 0))
                color.layer = .fg if layer == "38" else .bg

                array : Command_Color_Array
                sa.set(&array, 0, color)
                cmd = array
        case:
            result := Command_Colors_Graphics{}
            for arg in sa.slice(&split) {
                key := transmute(string)arg
                if g, ok := graphics_table[key]; ok {
                    sa.append(&result.graphics, g)
                } else if c, ok := colors_standard_table[key]; ok {
                    if !sa.append(&result.colors, c) {
                        log.error("Too many colors")
                    }
                } else {
                    safe_log_sequence(parser.data, "Unknown sequence [Color]")
                }
            }

            cmd = result
        }

        return

    case 'l', 'h':
        parser_advance(parser)

        Table :: struct{key: string, value: Command}
        table : []Table

        switch string(sa.slice(&joined)) {
        case "?7":
            graphics : Command_Graphics_Array
            sa.set(&graphics, 0, Graphics_Kind.line_wrapping)
            set := true if ch == 'l' else false
            cmd = Command_Graphics{ set=set, graphics=graphics }

        case "?25":
            switch ch {
            case 'l':cmd = Command_Set_Cursor_Visible(false)
            case 'h':cmd = Command_Set_Cursor_Visible(true)
            }
        case "?1049":
            switch ch {
            case 'l':cmd = Command_Set_Alternate_Screen(false)
            case 'h':cmd = Command_Set_Alternate_Screen(true)
            }
        case:
            fmt.printfln("%s",sa.slice(&joined))
            safe_log_sequence(parser.data)
            return {}, .Unknown_Sequence
        }

        return
    case:
        safe_log_sequence(parser.data)
    }

    return
}

/* The slices stored in args are taken from parser.data */
parser_collect_and_slice_args :: proc(parser: ^Parser, split: ^Bytes_SA, joined: ^Byte_SA) {
    loop: for {
        switch parser.char {
        case '0'..='9':
            slice := parser_collect_and_slice_digits(parser)
            for b in slice do sa.append(joined, b)
            sa.append(split, slice)
        case ';':
            sa.append(joined, parser.char)
            // TODO: another argument is expected after a semicolon
            // maybe that should be checked?
            parser_advance(parser)
        case: break loop
        }
    }
}

/* The slices stored in args are taken from parser.data */
parser_collect_and_slice_digits :: proc(parser: ^Parser) -> []byte {
    offset := parser.offset
    length := 0
    loop: for {
        switch parser.char {
        case '0'..='9':
            length += 1
            parser_advance(parser)
        case: break loop
        }
    }

    return parser.data[offset:][:length]
}

parse_int :: proc(str: string, error_to_return: Error) -> (int, Error) {
    res, ok := strconv.parse_int(str)
    if !ok do return {}, error_to_return
    return res, nil
}

@(private="file")
equal :: proc(bytes: []byte, str: string) -> bool {
    return slice.equal(bytes, transmute([]byte)str)
}
