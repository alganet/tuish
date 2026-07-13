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
| `tuish_fini`        | Tear down: restore the terminal, or -- for a hosted child -- fold just that child (see below)                                               |
| `tuish_on_fini`     | Register a per-app teardown function, run on **every** exit path (see [event.md](event.md#callbacks))                                       |
| `tuish_quit`        | Signal the event loop to stop (call from inside `tuish_on_event`)                                                                           |
| `tuish_quit_main`   | Quit and leave viewport content visible (cursor below output) -- use for tools like `fzf` where the selected result should remain on screen |
| `tuish_quit_clear`  | Quit, clear viewport output, and restore cursor position -- use for transient UI that should leave no trace                                 |
| `tuish_update_size` | Refresh `TUISH_LINES` and `TUISH_COLUMNS` from the terminal                                                                                 |

`tuish_init` brings up the terminal **device** (raw mode, traps, timing) exactly
once per process. A nested app's `tuish_init` finds the device already up and
simply adopts the context its host created for it, so an app needs no special
code to be embeddable.

`tuish_fini` mirrors that. At top level it restores the terminal. Called on a
**hosted child** it folds only that child -- runs the child's `tuish_on_fini`
hook, clears its region, drops its context, and resumes the parent -- leaving the
shared device up, because a child must never restore the terminal out from under
its host. (On a real process exit the full device teardown still runs even with a
child active, so a signal mid-embed cannot leave the terminal wedged.)

See [hosting.md](hosting.md) for contexts, regions, and running one app inside
another.

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

| Variable          | Description                                              |
|-------------------|----------------------------------------------------------|
| `TUISH_LINES`     | Terminal height in rows                                  |
| `TUISH_COLUMNS`   | Terminal width in columns                                |
| `TUISH_INIT_ROW`  | Cursor row when `tuish_init` was called                  |
| `TUISH_PROTOCOL`  | Keyboard protocol: `vt` or `kitty`                       |
| `TUISH_TIMING`    | Timeout resolution: `sub` (subsecond) or `second`        |
| `TUISH_TICK_US`   | Idle interval in microseconds -- the wall-time one idle tick spans, and so the `dt` a time-based animation should integrate against |
| `TUISH_CTX`       | Id of the context just created or mounted (see [hosting.md](hosting.md)) |
| `TUISH_CTX_ROOT`  | Id of the root (top-level app) context                   |

`TUISH_LINES` / `TUISH_COLUMNS` are the **terminal's** size. An app's own drawable
size is `TUISH_VIEW_ROWS` / `TUISH_VIEW_COLS` -- the same thing at top level, but
the region's size when the app is hosted. Code that may run embedded should use the
viewport variables. See [viewport.md](viewport.md).

## Configuration

Set these before calling `tuish_init`:

| Variable             | Default | Description                                                       |
|----------------------|---------|-------------------------------------------------------------------|
| `TUISH_TABSIZE`      | `4`     | Tab stop interval                                                 |
| `TUISH_FINI_OFFSET`  | `0`     | Lines below init position to place cursor after fini              |
| `TUISH_IDLE_TIMEOUT` | `0.26`  | Idle event interval in seconds (clamped to `1` for second timing) |

`TUISH_IDLE_TIMEOUT` is *launcher* configuration: it is read once at `tuish_init`
and never written back by the framework. To change the idle interval at runtime --
which a hosted real-time app must do, since it cannot set an environment variable
before its host's `tuish_init` -- call:

| Function                  | Description                                                        |
|---------------------------|--------------------------------------------------------------------|
| `tuish_idle_interval SECS`| Set the idle interval for the **active context** (e.g. `0.02` for 50Hz) |

Being per-context, a child's chosen rate is restored to the host's when the child
is unmounted. A cooperative host reconciles differing rates with
`tuish_ctx_sync_interval` and `tuish_ctx_tick`; see
[hosting.md](hosting.md#idle-tick-negotiation).

## Terminal Setup

tui.sh configures the terminal at startup and restores it on exit:

| Feature            | Enable sequence      | Purpose                                           |
|--------------------|----------------------|---------------------------------------------------|
| Raw mode           | `stty raw -isig ...` | Byte-by-byte input, no signal generation          |
| Bracketed paste    | `ESC[?2004h`         | Paste start/end markers                           |
| Application cursor | `ESC[?1h`            | SS3 arrow keys                                    |
| Focus events       | `ESC[?1004h`         | Focus in/out reporting                            |

All modes are disabled on exit, and `stty` is restored to its previous state.

The kitty keyboard protocol (`ESC[>9u`, CSI u key events) is **not** enabled
at startup — `TUISH_PROTOCOL` defaults to `vt`. Opt in by calling
`tuish_kitty_on` (it probes for support and falls back to VT if absent);
`tuish_kitty_off` and `tuish_fini` restore it.
