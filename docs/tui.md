<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Core (tui.sh)

Terminal setup, teardown, traps, and IO stubs. This is the required core
module that manages the terminal lifecycle. Source `compat.sh` and `ord.sh`
before this file.

```sh
. ./src/compat.sh
. ./src/ord.sh
. ./src/tui.sh
```

## Lifecycle

| Function            | Description                                                                                                                                 |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------------------|
| `tuish_init`        | Set up terminal for TUI (raw mode, keyboard protocol detection)                                                                             |
| `tuish_fini`        | Restore terminal to previous state                                                                                                          |
| `tuish_quit`        | Signal the event loop to stop (call from inside `tuish_on_event`)                                                                           |
| `tuish_quit_main`   | Quit and leave viewport content visible (cursor below output) -- use for tools like `fzf` where the selected result should remain on screen |
| `tuish_quit_clear`  | Quit, clear viewport output, and restore cursor position -- use for transient UI that should leave no trace                                 |
| `tuish_update_size` | Refresh `TUISH_LINES` and `TUISH_COLUMNS` from the terminal                                                                                 |

## Buffering

| Function      | Description                         |
|---------------|-------------------------------------|
| `tuish_begin` | Start output buffering              |
| `tuish_end`   | Flush buffer and stop buffering     |
| `tuish_flush` | Flush buffer, keep buffering active |

Buffering is automatic inside `tuish_on_event` -- all output is coalesced
and flushed after the handler returns.

`tuish_flush` can also be called **inside** `tuish_on_event` to send output
to the terminal immediately, before the deferred redraw check runs. This
is useful for latency-sensitive updates (see [event.md](event.md#immediate-rendering)).

## Cursor Basics

| Function               | Description                        |
|------------------------|------------------------------------|
| `tuish_show_cursor`    | Show cursor                        |
| `tuish_hide_cursor`    | Hide cursor                        |
| `tuish_save_cursor`    | Save cursor position (DECSC)       |
| `tuish_restore_cursor` | Restore cursor position (DECRC)    |
| `tuish_reset_scroll`   | Reset scroll region to full screen |

For full cursor movement, shapes, and drawing primitives, see [term.md](term.md).

## Terminal Variables

Available after `tuish_init`:

| Variable         | Description                                       |
|------------------|---------------------------------------------------|
| `TUISH_LINES`    | Terminal height in rows                           |
| `TUISH_COLUMNS`  | Terminal width in columns                         |
| `TUISH_INIT_ROW` | Cursor row when `tuish_init` was called           |
| `TUISH_PROTOCOL` | Keyboard protocol: `vt` or `kitty`                |
| `TUISH_TIMING`   | Timeout resolution: `sub` (subsecond) or `second` |

## Configuration

Set these before calling `tuish_init`:

| Variable             | Default | Description                                                       |
|----------------------|---------|-------------------------------------------------------------------|
| `TUISH_TABSIZE`      | `4`     | Tab stop interval                                                 |
| `TUISH_FINI_OFFSET`  | `0`     | Lines below init position to place cursor after fini              |
| `TUISH_IDLE_TIMEOUT` | `0.26`  | Idle event interval in seconds (clamped to `1` for second timing) |

## Terminal Setup

tui.sh configures the terminal at startup and restores it on exit:

| Feature            | Enable sequence      | Purpose                                           |
|--------------------|----------------------|---------------------------------------------------|
| Raw mode           | `stty raw -isig ...` | Byte-by-byte input, no signal generation          |
| Bracketed paste    | `ESC[?2004h`         | Paste start/end markers                           |
| Application cursor | `ESC[?1h`            | SS3 arrow keys                                    |
| Focus events       | `ESC[?1004h`         | Focus in/out reporting                            |
| Kitty keyboard     | `ESC[>9u`            | CSI u key events (flags: disambiguate + all keys) |

All modes are disabled on exit, and `stty` is restored to its previous state.
