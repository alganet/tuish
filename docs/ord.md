<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# ASCII Lookup Tables (ord.sh)

Precomputed ASCII ord/chr tables for codes 1-127. Source after `compat.sh`.

```sh
. ./src/compat.sh
. ./src/ord.sh
```

## What It Does

Builds lookup tables at source time so that character-to-code and
code-to-character conversions don't require subshell forks at runtime.
Used internally by hid.sh (event parsing), keybind.sh (event name
sanitization), and str.sh (UTF-8 byte decoding).

## Internal API

| Symbol         | Description                                                            |
|----------------|------------------------------------------------------------------------|
| `_tuish_ord()` | Character → ASCII code (result in `_tuish_code`)                       |
| `_tuish_chr_N` | Code → character lookup variables (`_tuish_chr_1` .. `_tuish_chr_127`) |

### Shell-Specific Table Generation

| Shell          | Method                         |
|----------------|--------------------------------|
| bash, zsh      | `printf -v` (no subshell)      |
| mksh           | `echo -ne` with hex escapes    |
| ksh93, busybox | Subshell fallback at init time |
