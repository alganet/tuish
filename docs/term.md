<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Terminal Output (term.sh)

Drawing primitives for cursor movement, text output, colors, text attributes,
screen clearing, and scroll regions. Source after `tui.sh`.

```sh
. ./src/tui.sh
. ./src/term.sh
```

## Cursor Positioning

| Function               | Description                                                                                 |
|------------------------|---------------------------------------------------------------------------------------------|
| `tuish_move ROW COL`   | Move cursor to absolute position (1-based)                                                  |
| `tuish_vmove ROW COL`  | Move cursor relative to viewport top (1-based)                                              |
| `tuish_move_up [N]`    | Move cursor up N rows (default: 1)                                                          |
| `tuish_move_down [N]`  | Move cursor down N rows (default: 1)                                                        |
| `tuish_move_right [N]` | Move cursor right N columns (default: 1)                                                    |
| `tuish_move_left [N]`  | Move cursor left N columns (default: 1)                                                     |
| `tuish_cursor ROW COL` | Move to viewport-relative position, show cursor, and record position for rAF cursor-restore |

## Cursor Shape

| Function               | Description                 |
|------------------------|-----------------------------|
| `tuish_cursor_shape N` | Set cursor shape (DECSCUSR) |

| N | Shape              |
|---|--------------------|
| 0 | Terminal default   |
| 1 | Blinking block     |
| 2 | Steady block       |
| 3 | Blinking underline |
| 4 | Steady underline   |
| 5 | Blinking bar       |
| 6 | Steady bar         |

## Output

| Function                      | Description                                                                         |
|-------------------------------|-------------------------------------------------------------------------------------|
| `tuish_print TEXT`            | Print text at cursor position (backslashes and `%` signs are escaped automatically) |
| `tuish_print_at ROW COL TEXT` | Viewport-relative move + print (convenience)                                        |
| `tuish_newline`               | Output newline + carriage return                                                    |

## Erase

| Function                         | Description                                                                                                         |
|----------------------------------|---------------------------------------------------------------------------------------------------------------------|
| `tuish_clear_screen`             | Erase entire screen                                                                                                 |
| `tuish_clear_line`               | Erase entire current line                                                                                           |
| `tuish_clear_to_eol`             | Erase from cursor to end of line                                                                                    |
| `tuish_clear_to_bol`             | Erase from cursor to beginning of line                                                                              |
| `tuish_clear_region ROW COL W H` | Clear a rectangular area by writing spaces (no color; for colored fill see `tuish_draw_fill` in [draw.md](draw.md)) |

## Scrolling

| Function                      | Description                              |
|-------------------------------|------------------------------------------|
| `tuish_scroll_region TOP BOT` | Set scroll region (rows TOP through BOT) |
| `tuish_scroll_up`             | Scroll content up one line               |
| `tuish_scroll_down`           | Scroll content down one line             |
| `tuish_scroll_up_n N`         | Scroll content up N lines                |
| `tuish_scroll_down_n N`       | Scroll content down N lines              |

Reset the scroll region with `tuish_reset_scroll` (defined in tui.sh).

## Alternate Screen

| Function              | Description                              |
|-----------------------|------------------------------------------|
| `tuish_altscreen_on`  | Switch to alternate screen buffer        |
| `tuish_altscreen_off` | Switch back from alternate screen buffer |

## Text Attributes

| Function              | SGR Code | Description                     |
|-----------------------|----------|---------------------------------|
| `tuish_bold`          | 1        | Bold / increased intensity      |
| `tuish_dim`           | 2        | Dim / decreased intensity       |
| `tuish_italic`        | 3        | Italic                          |
| `tuish_underline`     | 4        | Underline                       |
| `tuish_blink`         | 5        | Blink                           |
| `tuish_reverse`       | 7        | Reverse video (swap fg/bg)      |
| `tuish_strikethrough` | 9        | Strikethrough                   |
| `tuish_sgr CODE`      | any      | Set arbitrary SGR attribute     |
| `tuish_sgr_reset`     | 0        | Reset all attributes and colors |

Attributes are cumulative until `tuish_sgr_reset` is called.

### Combined Style

| Function                            | Description                                     |
|-------------------------------------|-------------------------------------------------|
| `tuish_style [attrs] [fg=N] [bg=N]` | Reset + apply attributes and colors in one call |

Accepts any combination of attribute names (`bold`, `dim`, `italic`, `underline`,
`blink`, `reverse`, `strikethrough`) and `fg=`/`bg=` color values. Colors accept
0-7 (basic), 8-15 (bright), 16-255 (256-palette), or `R:G:B` (truecolor).

```sh
tuish_style bold fg=1              # bold red
tuish_style italic underline fg=45 bg=0  # italic underlined magenta on black
tuish_style fg=255:128:0           # truecolor orange foreground
```

## Colors

### Basic Colors (0-7)

| Function            | Description                       |
|---------------------|-----------------------------------|
| `tuish_fg N`        | Set foreground color (0-7)        |
| `tuish_bg N`        | Set background color (0-7)        |
| `tuish_fg_bright N` | Set bright foreground color (0-7) |
| `tuish_bg_bright N` | Set bright background color (0-7) |

| N | Color   |
|---|---------|
| 0 | Black   |
| 1 | Red     |
| 2 | Green   |
| 3 | Yellow  |
| 4 | Blue    |
| 5 | Magenta |
| 6 | Cyan    |
| 7 | White   |

### 256-Color Palette

| Function        | Description            |
|-----------------|------------------------|
| `tuish_fg256 N` | Set foreground (0-255) |
| `tuish_bg256 N` | Set background (0-255) |

| Range   | Description                     |
|---------|---------------------------------|
| 0-7     | Standard colors (same as basic) |
| 8-15    | Bright colors                   |
| 16-231  | 6x6x6 color cube                |
| 232-255 | Grayscale ramp (dark to light)  |

### Truecolor (24-bit RGB)

| Function             | Description                               |
|----------------------|-------------------------------------------|
| `tuish_fg_rgb R G B` | Set foreground to RGB values (0-255 each) |
| `tuish_bg_rgb R G B` | Set background to RGB values (0-255 each) |
| `tuish_fg_default`   | Reset foreground to terminal default      |
| `tuish_bg_default`   | Reset background to terminal default      |

### Composing Styles

Attributes and colors are cumulative. Combine them freely:

```sh
tuish_bold
tuish_fg 1
tuish_print "bold red text"
tuish_sgr_reset

tuish_dim
tuish_fg256 242
tuish_print "dim gray"
tuish_sgr_reset

tuish_reverse
tuish_fg 4
tuish_bg 7
tuish_print " status bar "
tuish_sgr_reset
```

Always call `tuish_sgr_reset` after styled output to avoid leaking styles
into subsequent text.

### Raw SGR Access

For any SGR code not covered by a convenience function:

```sh
tuish_sgr '4;58;2;255;100;0'    # colored underline (if supported)
```
