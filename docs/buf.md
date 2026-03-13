<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Line Buffer (buf.sh)

Generic line-indexed buffer using variable indirection. Supports multiple
independent named buffers. Source after `compat.sh`.

```sh
. ./src/compat.sh
. ./src/buf.sh
```

## Functions

Lines are 1-based indexed. All functions accept an optional `PREFIX` as the
first argument to operate on an independent named buffer instead of the default.

| Function                               | Description                                      |
|----------------------------------------|--------------------------------------------------|
| `tuish_buf_init [PREFIX]`              | Initialize buffer with one empty line            |
| `tuish_buf_count [PREFIX]`             | Load named buffer's count into `TUISH_BUF_COUNT` |
| `tuish_buf_get [PREFIX] IDX`           | Get line content at index -> `TUISH_BLINE`       |
| `tuish_buf_set [PREFIX] IDX VAL`       | Set line content at index                        |
| `tuish_buf_append [PREFIX] VAL`        | Append a new line to end of buffer               |
| `tuish_buf_insert_at [PREFIX] IDX VAL` | Insert line at index, shifting others down       |
| `tuish_buf_delete_at [PREFIX] IDX`     | Delete line at index, shifting others up         |

## Variables

| Variable          | Description                              |
|-------------------|------------------------------------------|
| `TUISH_BUF_COUNT` | Number of lines in the buffer            |
| `TUISH_BLINE`     | Line content returned by `tuish_buf_get` |

## Example

```sh
# Default buffer
tuish_buf_init                        # TUISH_BUF_COUNT = 1 (one empty line)
tuish_buf_set 1 "first line"
tuish_buf_append "second line"        # TUISH_BUF_COUNT = 2
tuish_buf_get 1                       # TUISH_BLINE = "first line"
tuish_buf_insert_at 2 "inserted"      # shifts "second line" to index 3
tuish_buf_delete_at 3                 # removes "second line"

# Named buffers (independent of each other and the default)
tuish_buf_init log
tuish_buf_append log "error: file not found"
tuish_buf_append log "warning: deprecated API"
tuish_buf_count log                   # TUISH_BUF_COUNT = 3
tuish_buf_get log 2                   # TUISH_BLINE = "error: file not found"
```
