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

| Function                | Output Variable   | Description                       |
|-------------------------|-------------------|-----------------------------------|
| `tuish_str_len VAR`     | `TUISH_SLEN`      | Length of string in VAR           |
| `tuish_str_left VAR N`  | `TUISH_SLEFT`     | First N characters                |
| `tuish_str_right VAR N` | `TUISH_SRIGHT`    | Characters from offset N to end   |
| `tuish_str_char VAR N`  | `TUISH_SCHAR`     | Single character at offset N      |
| `tuish_str_width VAR`   | `TUISH_SWIDTH`    | Display width in terminal columns |
| `tuish_str_repeat S N`  | `TUISH_SREPEATED` | S repeated N times                |

Offsets are 0-based. These use `${var:off:len}` syntax (bash/zsh/ksh93/mksh).

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
