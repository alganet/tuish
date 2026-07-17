<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: ISC
-->

# Hosting and Contexts (tui.sh)

One tuish app can run **another tuish app inside a region of itself** -- in the
same process, with no forks, over the same keyboard. A page can open an example
in its content box; a dashboard can drive a clock and a text editor side by side.

Two shapes:

| Shape           | Who owns the event loop         | Use it when                                            |
|-----------------|---------------------------------|--------------------------------------------------------|
| **Modal**       | the child (a nested `tuish_run`) | the child takes over until it quits, then the host resumes |
| **Cooperative** | the host (one loop, always)      | several children must stay live at once                |

Cooperative is the more general of the two: because the host keeps its loop, its
own chrome stays interactive and any number of children stay live simultaneously.

## Contexts

A **context** is one app's logical state: its viewport, transform, bindings,
render/event handlers, redraw scheduler, canvas, and idle tick.

The active context's fields live in plain shell globals -- the "registers" that
the hot paths read. Inactive contexts are spilled to namespaced saved frames. A
switch marshals a fixed, registered field list and only ever happens at app
boundaries, never per byte or per frame, so the render path pays nothing for it.

The terminal **device** -- raw mode, traps, the byte reader, the screen size, the
keyboard protocol -- is singular and is *not* part of any context. `tuish_init`
brings the device up exactly once per process; a nested app's `tuish_init` simply
adopts the context its host created for it.

| Function                          | Purpose                                                             |
|-----------------------------------|---------------------------------------------------------------------|
| `tuish_ctx_create`                | Allocate a context seeded with default field values; id in `TUISH_CTX` |
| `tuish_ctx_create_region R C W H` | Create **and activate** a child bound to a region of the active context |
| `tuish_ctx_activate CTX`          | Spill the current context, fill the working set from `CTX`            |
| `tuish_ctx_reseat CTX R C W H`    | Move a child's rectangle (call from the host's resize handler)        |
| `tuish_ctx_destroy CTX`           | Free a context's bindings and drop its saved frame                    |
| `tuish_ctx_register NAME...`      | Register working vars as marshalled context fields (for modules)      |

| Variable         | Meaning                                                    |
|------------------|------------------------------------------------------------|
| `TUISH_CTX`      | Id of the context just created or mounted                  |
| `TUISH_CTX_ROOT` | Id of the root (top-level app) context                     |
| `TUISH_CTX_QUIT` | Set by `tuish_ctx_dispatch`/`tuish_ctx_tick` when the child it drove quit itself |
| `TUISH_CTX_HANDLED` | Set by `tuish_ctx_dispatch`: 1 if the child acted on the event, 0 if it declined it (see [Scroll chaining](#scroll-chaining)) |

`R C` are the region's top-left in the **host's** logical coordinates and `W H`
its size. The host's live transform resolves that to absolute cells, so regions
compose to any depth.

Inside a child, its region *is* its screen: logical `(1,1)` is the region's
top-left, drawing clips to the region, and `tuish_viewport fullscreen` fills the
region rather than the terminal (it never touches the alternate screen). That is
what lets a full-screen example run unchanged inside a host's content pane.

## Writing a hostable app

An app is hostable when it does two things.

**1. Register handlers by name; never redefine the global hooks.**

```sh
tuish_on_redraw _my_render      # NOT: tuish_on_redraw () { ... }
tuish_on_event  _my_on_event    # NOT: tuish_on_event  () { ... }
tuish_on_fini   _my_fini        # restore anything device-ish you changed
```

Redefining `tuish_on_redraw` as a function still works, but it is process-global:
two apps written that way would fight over the same function. Registration stores
the handler *per context*, so apps compose. See [event.md](event.md).

`tuish_on_fini` matters more than it looks. A cooperatively-driven app never
returns from a `tuish_run` of its own, so cleanup placed after `tuish_run` never
runs. `tuish_fini` invokes the registered hook on **every** exit path -- standalone
teardown, modal return, and cooperative unmount.

**2. Split setup from the event loop.**

Register bindings and handlers *after* `tuish_init`, so they land in whichever
context is active -- the root standalone, the region when hosted -- and put
everything except the loop in a `_setup` function:

```sh
_app_setup ()      # everything but the loop: a cooperative host calls THIS
{
	tuish_init                     # adopts the host's context when nested
	tuish_on_redraw _app_render
	tuish_bind 'char q' '_app_quit'
	tuish_viewport fullscreen      # hosted -> fills our region
	_app_render
}

_app_main ()       # the blocking form: standalone, or a modal host
{
	_app_setup
	tuish_run || :
	tuish_fini
}

# Only bootstrap when we are the top-level program.
if test -z "${_tuish_tui_loaded:-}"
then . ../src/tui.sh; ...; _app_main; fi
```

A host that sources the file gets the definitions without running the app. Every
example in `examples/` is built this way.

Two things to avoid, because they punch out of a region:

- **`tuish_clear_to_eol` / `tuish_clear_line` / `tuish_clear_screen`** act on the
  *physical* terminal line or screen. Use `tuish_clear_to_edge ROW [COL]`, which
  is bounded by the drawable area. See [term.md](term.md).
- **`TUISH_COLUMNS` / `TUISH_LINES`** are the terminal's size. An app's own width
  and height are `TUISH_VIEW_COLS` / `TUISH_VIEW_ROWS`.

## Modal hosting

The host creates a region, calls the child's `_main`, and gets control back when
the child quits:

```sh
_open_example ()
{
	tuish_ctx_create_region 4 3 "$_box_w" "$_box_h"
	_cd_main                      # the child owns the keyboard until it quits
	tuish_request_redraw -1       # repaint our chrome over it
}
```

A click **outside** the child's region ends the child (its loop is the only one
running, so quitting is the only way to hand control back). The click itself is
consumed -- closing the child *is* the response to it.

## Cooperative hosting

The host keeps its single loop and feeds each decoded event to the right child.
No child runs a loop of its own, so every child stays live at once.

| Function                        | Purpose                                                        |
|---------------------------------|----------------------------------------------------------------|
| `tuish_ctx_mount R C W H FN...` | Create a region, run the child's (non-blocking) `FN` setup in it, leave the host active |
| `tuish_ctx_dispatch CTX`        | Drive a child with the currently decoded event (keys, mouse, resize) |
| `tuish_ctx_tick CTX`            | Drive a child with an **idle** tick, at *its own* rate (see below) |
| `tuish_ctx_render CTX`          | Repaint a child now — into the host's frame if one is open (see [One frame, one write](#one-frame-one-write)) |
| `tuish_ctx_sync_interval CTX...`| Adopt the fastest tick among the host and the listed children   |
| `tuish_ctx_unmount CTX`         | Fold a child's viewport and drop its context                    |

```sh
tuish_ctx_mount "$_lr" "$_lc" "$_lw" "$_lh" _clk_setup ; _clk=$TUISH_CTX
tuish_ctx_mount "$_rr" "$_rc" "$_rw" "$_rh" _ed_setup  ; _ed=$TUISH_CTX
tuish_ctx_sync_interval "$_clk" "$_ed"

_on_event ()
{
	case "$TUISH_EVENT_KIND" in
		mouse)  _in_left  && tuish_ctx_dispatch "$_clk"
		        _in_right && tuish_ctx_dispatch "$_ed" ;;
		key)    tuish_ctx_dispatch "$_ed"
		        test "$TUISH_CTX_QUIT" = 1 && tuish_quit_clear ;;
		idle)   tuish_ctx_tick "$_clk"; tuish_ctx_tick "$_ed" ;;
		signal) _relayout
		        tuish_ctx_reseat "$_clk" "$_lr" "$_lc" "$_lw" "$_lh"
		        tuish_ctx_reseat "$_ed"  "$_rr" "$_rc" "$_rw" "$_rh"
		        tuish_ctx_dispatch "$_clk"; tuish_ctx_dispatch "$_ed" ;;
	esac
}
tuish_on_event _on_event
```

When a child context is active the whole pipeline already targets it -- mouse is
decoded into the child's region-local frame, dispatch uses the child's bind table,
and the render path calls the child's handler -- so driving a child is just
"activate it, feed it the event, restore the host".

The host routes; a driven child never sees an event that landed outside its
region, so it has no reason to self-quit.

### Quitting

Let a child quit **by its own means** and detect it, rather than intercepting its
quit key. After each `tuish_ctx_dispatch` / `tuish_ctx_tick`, `TUISH_CTX_QUIT` is 1
if the child ended itself; the host then calls `tuish_ctx_unmount`. This matters
because a terminal or browser may reserve the key an app quits on (Ctrl+W closes a
browser tab), so a host cannot reliably know or intercept it.

It is worth giving the host its own escape hatch too -- `web/site/site.sh` binds
Esc to close whatever example is mounted.

### Scrolling a live child

A child does not have to fit in the pane it is shown through. A region is **three
independent things**, and keeping them apart is what lets a running app scroll under
an edge like any other content:

| | |
|---|---|
| **layout size** (`TUISH_VIEW_ROWS`/`COLS`) | how big the child *thinks* it is. It lays out to fill this, so it must not shrink just because part of it is off-screen — or the child reflows instead of sliding. |
| **origin** (`TUISH_VIEW_TOP`/`LEFT`) | where its logical `(1,1)` lands. May be **outside** the visible pane — even above row 1. That *is* a child scrolled partly out of view. |
| **visible clip** | what may actually reach the terminal. `tuish_vmove` drops any cell outside it. |

So pass `tuish_ctx_reseat` a rectangle whose top is above the pane, plus the pane
itself as the clip window:

```sh
tuish_ctx_reseat "$_ctx"  $(( _pane_r + _line - _scroll ))  "$_pane_c" "$_w" "$_h" \
                          "$_pane_r" "$_pane_c" "$_pane_w" "$_pane_h"
tuish_ctx_render "$_ctx"     # repaint it where it now is
```

The child is **occluded, not resized**. It never learns it is clipped.

`tuish_ctx_render` matters here: a child repaints on its own idle tick, and at a lazy
interval that leaves a visibly torn widget on screen for a whole tick while the user
scrolls. Repaint it yourself, right after you move it.

### One frame, one write

Call `tuish_ctx_render` **inside your own `tuish_begin`/`tuish_end`** and the child's
output is spliced into your frame rather than written on its own:

```sh
tuish_begin
_paint_background
_draw_prose
_render_children      # tuish_ctx_render for each — no writes yet
tuish_end             # ONE write: background, prose, and every child
```

This is not just a byte count. `_tuish_buf` is a *per-context* frame, so a host cannot
buffer "everything that happens" — the moment it activates a child, it is looking at the
child's buffer, and the child's own `tuish_end` goes straight to the terminal. A page
with three widgets therefore emitted four writes, and the terminal drew each: you saw the
prose land at the new scroll offset while the widgets were still at the old one, a frame
at a time. It reads as a shimmer, or a ghost trailing the text.

The child's output enters the buffer at the point you called from, so render children
**last** — after your background fill, or it lands on top of them.

`tuish_ctx_mount` does the same with the child's first paint, so mounting a widget in
response to a click does not flash it onto the screen a frame before the page around it.

**Clip a child from its FIRST paint.** `tuish_ctx_mount` does not merely create a
context — it runs the child's setup *and paints it*. A child mounted while already
partly outside the pane would draw over the host's chrome once, before any reseat
could bound it. Set `TUISH_MOUNT_CLIP` (`"R C W H"`, the host's logical coords) and
`tuish_ctx_mount` applies it before the child's first paint:

```sh
TUISH_MOUNT_CLIP="$_pane_r $_pane_c $_pane_w $_pane_h"
tuish_ctx_mount "$_r" "$_c" "$_w" "$_h" _app_setup
```

**Clipping only holds for drawing that goes through the transform**, which is
everything except the raw escapes. Two rules for an app that may be clipped:

- **Honour `tuish_vmove`'s return value.** It *refuses* a clipped cell. Printing
  anyway drops the text at whatever cell the cursor last sat on — standalone that
  almost never bites (a cell is refused only off-screen), but in a clipped region it
  fires constantly and smears stray text across the host's chrome. Use
  `if tuish_vmove R C; then …; fi`, or the primitives that already do
  (`tuish_text`, `tuish_put_at`, `_tuish_write_at`, the `draw.sh` calls).
  A bounds test is *not* a substitute — `TUISH_VIEW_ROWS` is the layout height, which
  stays full-size while the visible clip shrinks. Only `tuish_vmove` knows.
- Keep off `tuish_clear_screen` / `clear_line` / `clear_to_eol` / `clear_to_bol` and
  `tuish_move`, which address the physical terminal. See [term.md](term.md).

### Scroll chaining

Once a child scrolls *with* the page, the wheel over it is ambiguous. It may be the
child's (an editor with more lines than it can show) or the page's (a widget that
scrolls nothing at all). Routing it purely by position gets this wrong in the way that
matters most: park the pointer over a widget that ignores the wheel and the page stops
scrolling **entirely** -- and it can never recover, because nothing moves the widget
out from under the pointer.

So ask the child first, and take the event back if it did nothing with it:

```sh
tuish_ctx_dispatch "$_ctx"
if test "$TUISH_CTX_HANDLED" -eq 0
then
    case "$TUISH_EVENT" in
        whup|wdown) _scroll_the_page ;;   # the child declined it — it is ours
    esac
fi
```

`TUISH_CTX_HANDLED` is 1 when a binding in the child matched **and acted**. Three ways
it comes back 0:

- the child has no binding for the event;
- the event never reached the child's bindings at all (a child that never called
  `tuish_mouse_on` drops mouse events);
- a binding matched, ran, and called **`tuish_pass`** -- "I looked at this and I am
  not acting on it."

That last one is what makes the end of a scroll continue onto the page, the way a
nested scroller does in a browser. `tuish_dispatch` marks the event handled *before*
running the action, precisely so the action can hand it back:

```sh
_scroll_down ()
{
    test $_top -ge $_max && { tuish_pass; return 0; }   # already at the bottom
    _top=$((_top + 3))
    tuish_request_redraw
}
```

An app that is a *picture* rather than an app -- a rendered snippet, a chart -- should
bind `tuish_pass`, not `:`, as its catch-all. `:` silently eats every event a host
offers it.

A **full-pane** child is the exception: it owns its region and there is nothing behind
it to scroll, so a host should let it consume the wheel unconditionally.

### Idle-tick negotiation

Children can want different clocks: a game at 50Hz next to a clock at 1Hz. One
loop has one poll rate, so two rules pull in opposite directions:

- the **fast** child must not be *slowed* -- so the host polls at the **fastest**
  tick among itself and its children (`tuish_ctx_sync_interval`);
- the **slow** child must not be *sped up* -- so each child accumulates the host's
  tick and is only driven once **its own** interval has elapsed (`tuish_ctx_tick`).

The host therefore polls fast enough for the fastest child and divides that down
per child. A 50Hz game and a 1Hz clock hosted together each animate at their own
rate, in one loop, with no forks and no wall-clock reads.

A child asks for its rate with `tuish_idle_interval SECS` (per-context, so the
host's own tick is restored when the child is unmounted). Its tick in microseconds
is `TUISH_TICK_US` -- the wall-time one idle tick spans, which is what a
time-based animation should integrate against.

`TUISH_IDLE_TIMEOUT` is *launcher* configuration, read once at `tuish_init`. It is
never written by the framework; use `tuish_idle_interval` to change a rate at
runtime.

## See also

- `examples/cooperative.sh` -- one loop driving a live clock and the real editor
- `tests/lib/host_demo.sh` -- the minimal modal host
- `tests/integration/test_cooperative.sh`, `tests/integration/test_hosting.sh`
- `tests/unit/test_context.sh` -- region seating, the region-safe erase, negotiation
