<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Event Loop (event.sh)

Event loop, dispatch, and RequestAnimationFrame-style redraw scheduling.
Source after `tui.sh`.

```sh
. ./src/tui.sh
. ./src/term.sh
. ./src/event.sh
```

## Functions

| Function      | Description                                                        |
|---------------|--------------------------------------------------------------------|
| `tuish_start` | Convenience wrapper: calls `tuish_init`, `tuish_run`, `tuish_fini` |
| `tuish_run`   | Start event loop -- reads input, parses events, dispatches them    |

### Callbacks

| Function                | Default                | Description                                                                                   |
|-------------------------|------------------------|-----------------------------------------------------------------------------------------------|
| `tuish_on_event`        | calls `tuish_dispatch` | Called for every parsed event. Override for pre/post-dispatch logic.                          |
| `tuish_on_redraw LEVEL` | no-op                  | Called when a deferred redraw fires. `LEVEL` is `-1` (full), or a positive integer (partial). |

The default `tuish_on_event` calls `tuish_dispatch`, so apps that use
`tuish_bind` (from `keybind.sh`) don't need to define it at all. Override
`tuish_on_event` when you need logic that wraps dispatch -- e.g., saving
state before dispatch and checking side effects after.

## Event Variables

Set before each event dispatch:

| Variable            | Description                                                        |
|---------------------|--------------------------------------------------------------------|
| `TUISH_EVENT`       | Parsed event name (e.g. `ctrl-w`, `up`, `char x`, `lclik`, `idle`) |
| `TUISH_EVENT_KIND`  | Event category: `key`, `mouse`, `focus`, `paste`, `signal`, `idle` |
| `TUISH_MOUSE_X`     | Mouse column (1-based)                                             |
| `TUISH_MOUSE_Y`     | Mouse row (1-based, viewport-relative when viewport active)        |
| `TUISH_MOUSE_ABS_Y` | Mouse row (1-based, absolute terminal row)                         |
| `TUISH_RAW`         | Raw event data for debugging (see example below)                   |

See [hid.md](hid.md) for the complete list of event names.

### Debugging with TUISH_RAW

```sh
tuish_bind '*' 'tuish_print_at 1 1 "RAW: $TUISH_RAW "'
```

## Event Lifecycle

```
byte arrives (terminal)
    │
    ▼
escape sequence assembled (_tuish_read_seq)
    │
    ▼
_tuish_parse_event        → raw parse: CSI u, SS3, CSI ~, mouse, etc.
    │
    ▼
_tuish_resolve_event      → name resolution: raw codes → event names
    │
    ▼
filters (mouse off? detailed off? modkeys off?)
    │
    ▼
tuish_begin               → start output buffering
    │
    ▼
tuish_on_event            → your callback (default: tuish_dispatch)
    │
    ▼
rAF check / tuish_end    → flush buffer, fire deferred redraw if pending
```

Your `tuish_on_event` or `tuish_bind` callbacks run between `tuish_begin`
and `tuish_end`. All terminal output within that window is buffered and
flushed as a single write.

## Redraw Scheduling

When a user holds down a key, the terminal buffers many keypresses. Without
scheduling, each keypress triggers a full redraw -- the UI keeps updating
after the key is released. `tuish_request_redraw` solves this by coalescing
redraws: state updates happen immediately, but rendering is deferred until
the input queue is drained.

| Function                       | Description                                                    |
|--------------------------------|----------------------------------------------------------------|
| `tuish_request_redraw [LEVEL]` | Schedule a deferred redraw. `LEVEL` defaults to `-1` (full).   |
| `tuish_cancel_redraw`          | Cancel a pending redraw request                                |
| `tuish_has_pending_input`      | Check if more input is queued (returns 0 if pending, 1 if not) |

### Redraw levels

The level argument tells `tuish_on_redraw` how much work to do:

| Level | Meaning                                   |
|-------|-------------------------------------------|
| `-1`  | Full redraw (repaint everything)          |
| `0`   | No-op (ignored by `tuish_request_redraw`) |
| `1`   | Minimal (e.g., status bar only)           |
| `2`   | Partial (e.g., current line + status bar) |
| `N`   | App-defined (higher = more work)          |

When multiple events queue up, the framework tracks the **maximum** level
across all `tuish_request_redraw` calls. Level `-1` always wins. Among
positive levels, the highest wins. The final level is passed to
`tuish_on_redraw`.

### Simple example

This works like the browser's `requestAnimationFrame`: event handlers update
state and call `tuish_request_redraw` instead of drawing. The framework calls
`tuish_on_redraw` once when all queued input has been processed.

```sh
_count=0

_on_next ()
{
    _count=$((_count + 1))
    tuish_request_redraw      # schedule full redraw (default -1)
}

tuish_on_redraw ()
{
    tuish_vmove 1 1
    tuish_print "Count: $_count"
    tuish_clear_to_eol
}

tuish_bind 'char n' '_on_next'
```

No `tuish_on_event` definition is needed -- the default forwards events to
`tuish_dispatch`. If the user holds `n` and 10 keypresses queue up, `_on_next`
runs 10 times (incrementing `_count`), but `tuish_on_redraw` fires only
once -- showing the final value. Single keypresses render immediately with
no added latency.

### Multi-level example

Use levels to skip expensive work when only a cheap update is needed:

```sh
tuish_on_redraw ()
{
    case "$1" in
        -1) _render_all ;;       # full: repaint everything
         2) _render_line         # partial: current line + status
            _render_status ;;
         *) _render_status ;;    # minimal: status bar only
    esac
}

# Typing a character only needs the current line repainted
_on_char () { _insert_char; tuish_request_redraw 2; }

# Scrolling needs a full repaint
_on_scroll () { _scroll_down; tuish_request_redraw; }

# Cursor movement only needs the status bar
_on_move () { _move_right; tuish_request_redraw 1; }
```

If the user types a character (level 2) then immediately scrolls (level -1),
the framework coalesces them into a single `tuish_on_redraw -1`.

### Immediate rendering

For latency-sensitive updates like text editors, deferred redraw adds a
perceptible delay -- characters don't appear until the input queue drains.
Use `tuish_flush` inside the event handler to render critical output
immediately, then schedule a cheap deferred redraw for the rest:

```sh
_on_char ()
{
    _insert_char               # update state
    _render_current_line       # write line to buffer
    tuish_flush                # send to terminal NOW
    tuish_request_redraw 1     # defer status bar to redraw
}

tuish_on_redraw ()
{
    case "$1" in
        -1) _render_all ;;
         *) _render_status ;;  # level 1: just the status bar
    esac
}
```

How it works: `tuish_flush` sends buffered output to the terminal before the
deferred redraw check runs. The rAF logic then discards the (now empty)
buffer and handles the remaining redraw level. Each keystroke appears on
screen instantly, while cheap updates like the status bar are coalesced.
