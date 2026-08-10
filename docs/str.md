<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# String Utilities (str.sh)

Character-level string operations and Unicode display width calculation.
Source after `ord.sh`.

```sh
. ./src/ord.sh
. ./src/str.sh
```

## Functions

All string functions take a **variable name** (not value) to avoid subshell
overhead. Results are stored in output variables.

| Function                     | Output Variable                     | Description                                   |
|------------------------------|-------------------------------------|-----------------------------------------------|
| `tuish_str_len VAR`          | `TUISH_SLEN`                        | Length of string in VAR, in characters        |
| `tuish_str_left VAR N`       | `TUISH_SLEFT`                       | First N characters                            |
| `tuish_str_right VAR N`      | `TUISH_SRIGHT`                      | Characters from offset N to end               |
| `tuish_str_char VAR N`       | `TUISH_SCHAR`                       | Single character at offset N                  |
| `tuish_str_width VAR`        | `TUISH_SWIDTH`                      | Display width in terminal columns             |
| `tuish_str_window VAR OFF W` | `TUISH_SWINDOW`, `TUISH_SWINDOW_W`  | The slice visible in a W-column window at OFF |
| `tuish_str_pad VAR W`        | `TUISH_SPADDED`                     | VAR fitted to exactly W display columns       |
| `tuish_str_repeat S N`       | `TUISH_SREPEATED`                   | S repeated N times                            |

`tuish_str_window` also reports `TUISH_SWINDOW_W`, the slice's display width. That is
not recoverable by measuring the result: the slice may carry SGR runs (arbitrary
bytes, zero columns), and a wide glyph that would have crossed the right edge is
dropped rather than split, leaving the slice a column short of `W`. A caller padding
the slice out to a field needs the number the slicer already knows.

Offsets are 0-based. These use `${var:off:len}` syntax (bash/zsh/ksh93/mksh).

### Characters are not columns

`tuish_str_len`, `tuish_str_left`, `tuish_str_right` and `tuish_str_char` count
**characters**. `tuish_str_width` and `tuish_str_window` count **display columns**.
For ASCII the two agree, which is exactly what makes the confusion survive testing:

```sh
cjk='日本語'
tuish_str_left  cjk 2        # TUISH_SLEFT   = '日本'   — 2 characters, 4 COLUMNS
tuish_str_window cjk 0 2     # TUISH_SWINDOW = '日'     — 2 columns
```

If you are clipping to fit a region, a box, or any other geometry, you want columns,
so you want `tuish_str_window`. Using `tuish_str_left` for that job is how wide text
used to run straight through a hosted region's right border.

### tuish_str_pad VAR W

`VAR`'s value fitted to exactly `W` display columns in `TUISH_SPADDED`: space-padded
when it is narrower, sliced when it is wider.

```sh
name='hi';   tuish_str_pad name 5     # TUISH_SPADDED = 'hi   '
name='日本'; tuish_str_pad name 6     # TUISH_SPADDED = '日本  '  — 4 columns + 2
```

It goes through `tuish_str_window`, so `W` is columns: a wide glyph that would
straddle the cut is dropped rather than split, and the pad then makes up the missing
column, so the result is `W` columns either way.

This is the string counterpart of `tuish_text ... width=N`
([term.md](term.md#widthn--fields-and-why-not-to-erase-first)). Use `tuish_text` when
the field is the whole write; use this when a row is assembled from several pieces
and printed as a unit.

## Display Width

`tuish_str_width` computes how many terminal columns a string occupies.
ASCII characters are 1 column, CJK ideographs and fullwidth characters are
2 columns, and combining marks / zero-width characters are 0 columns.

```sh
text="hello world"
tuish_str_len text           # TUISH_SLEN = 11
tuish_str_left text 5        # TUISH_SLEFT = "hello"
tuish_str_right text 6       # TUISH_SRIGHT = "world"
tuish_str_char text 0        # TUISH_SCHAR = "h"

cjk="中文hi"
tuish_str_width cjk          # TUISH_SWIDTH = 6  (2+2+1+1)
```

## UTF-8 Internals

These internal functions handle byte-level UTF-8 processing under `LC_ALL=C`:

| Function                     | Description                            |
|------------------------------|----------------------------------------|
| `_tuish_byte_val VAR OFF`    | Unsigned byte value at offset          |
| `_tuish_utf8_len`            | UTF-8 byte length from lead byte       |
| `_tuish_utf8_decode`         | Decode UTF-8 codepoint                 |
| `_tuish_char_byte_off VAR N` | Byte offset of character index N       |
| `_tuish_char_width`          | Codepoint → display width (0, 1, or 2) |

## Shell Compatibility

The `tuish_str_*` functions require `${var:off:len}` parameter expansion,
supported by bash, zsh, ksh93, and mksh. Availability on busybox sh
depends on the build configuration.
