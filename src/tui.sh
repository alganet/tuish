#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# src/tui.sh - Terminal UI core: setup, teardown, traps, IO stubs
# Source compat.sh and ord.sh first, then this file.  Do not execute directly.
#
# Provides:
#   tuish_init             - set up terminal for TUI (raw mode, protocol detection)
#   tuish_fini             - restore terminal to previous state
#   tuish_quit             - signal event loop to stop
#   tuish_quit_main        - quit, leave viewport content visible, cursor below
#   tuish_quit_clear       - quit, clear viewport, restore cursor position
#   tuish_update_size      - refresh TUISH_LINES / TUISH_COLUMNS
#   tuish_begin            - start output buffering
#   tuish_end              - flush buffer and stop buffering
#   tuish_flush            - flush buffer (keep buffering active)
#   tuish_show_cursor      - show cursor
#   tuish_hide_cursor      - hide cursor
#   tuish_save_cursor      - save cursor position (DECSC)
#   tuish_restore_cursor   - restore cursor position (DECRC)
#   tuish_reset_scroll     - reset scroll region to full screen
#
# Variables (set after tuish_init):
#   TUISH_LINES            - terminal height
#   TUISH_COLUMNS          - terminal width
#   TUISH_INIT_ROW         - cursor row when init was called
#   TUISH_PROTOCOL         - keyboard protocol: "vt" or "kitty"
#   TUISH_TIMING           - timeout resolution: "sub" or "second"
#   TUISH_TICK_US          - idle interval in microseconds (for time-based animation)
#
# Configuration (set before tuish_init):
#   TUISH_TABSIZE          - tab stop interval (default: 4)
#   TUISH_FINI_OFFSET      - lines below init position to place cursor after fini (default: 0)
#   TUISH_IDLE_TIMEOUT     - idle event interval in seconds (default: 0.26, or 1 for second timing)
#   TUISH_ESC_TIMEOUT      - max wait (seconds) for an escape sequence to continue
#                            (default: 0.02, or 1 for second timing). Well-formed
#                            CSI/SS3 sequences dispatch on their final byte without
#                            waiting; this only bounds a lone ESC or an Alt-<key>.

# ─── Dependencies ─────────────────────────────────────────────────
# Source compat.sh before this file.  It provides:
#   _tuish_printf, _tuish_out(), alias local=typeset (ksh93)

# ─── Load guard ──────────────────────────────────────────────────
# Sourcing tui.sh twice would reset all state and re-stub the overridable
# functions, silently clobbering any optional module sourced in between.
if test -n "${_tuish_tui_loaded:-}"; then return 0; fi
_tuish_tui_loaded=1

# ─── IO stubs (overridden by term.sh) ────────────────────────────
# Minimal buffered-write and cursor primitives used by init/fini
# and event.sh.  term.sh redefines these with the same behavior
# plus full drawing primitives, colors, and style.

_tuish_buf=''
_tuish_buffering=0

_tuish_write ()
{
	if test $_tuish_buffering -eq 1
	then
		_tuish_buf="${_tuish_buf}${1:-}"
	else
		_tuish_out "${1:-}"
	fi
}

tuish_begin ()          { _tuish_buffering=1; _tuish_buf=''; }
tuish_end ()            { test -n "$_tuish_buf" && _tuish_out "$_tuish_buf"; _tuish_buf=''; _tuish_buffering=0; }
tuish_flush ()          { test -n "$_tuish_buf" && _tuish_out "$_tuish_buf"; _tuish_buf=''; }

# Repeat string $1 exactly $2 times into _tuish_rep. O(log n) via doubling.
# Shared primitive in the base module: str.sh (tuish_str_repeat) and term.sh
# (tuish_clear_region) both build repeated strings and depend only on tui.sh,
# so this lets them share one implementation instead of each inlining the loop.
_tuish_repeat ()
{
	local _rp_s="$1" _rp_n=$2
	_tuish_rep=''
	while test $_rp_n -gt 0
	do
		test $((_rp_n & 1)) -ne 0 && _tuish_rep="${_tuish_rep}${_rp_s}"
		_rp_s="${_rp_s}${_rp_s}"
		_rp_n=$((_rp_n >> 1))
	done
}

# DECSC/DECRC are ESC followed by a digit. Emit a literal ESC byte (from
# the ord table) rather than a backslash escape, because no single escape
# form survives every shell's printf/echo: `\x1b7` reads as hex 0x1b7 on
# ksh93, and `\0337` reads as octal 337 on mksh — both swallow the digit.
tuish_save_cursor ()    { _tuish_write "${_tuish_chr_27}7"; }
tuish_restore_cursor () { _tuish_write "${_tuish_chr_27}8"; }
tuish_show_cursor ()    { _tuish_write '\033[?25h'; }
tuish_hide_cursor ()    { _tuish_write '\033[?25l'; }
tuish_cursor ()         { :; }
tuish_reset_scroll ()   { _tuish_write '\033[r'; }

# ─── HID state defaults (ABI seam) ───────────────────────────────
# event.sh reads these on the per-event hot path, so they live in the base and
# must exist even when hid.sh is not sourced. Keeping them as plain globals (vs.
# a hid.sh predicate call per event) is a deliberate hot-path choice. Toggle
# functions and teardown (_tuish_hid_fini) are provided by hid.sh.

_tuish_mouse=0
_tuish_detailed=0
_tuish_modkeys=0
_tuish_wrap=0
_tuish_kitty_raw='letter'

# Whether mouse-tracking escapes are currently active ON THE TERMINAL. This is
# DEVICE state (the terminal is singular), so — unlike _tuish_mouse, which is a
# per-context "does THIS app want mouse events" flag — it is NOT registered as a
# context field. A child that enables mouse sets this; at final teardown, fini
# reads THIS (not the by-then-inactive child's _tuish_mouse) to know it must emit
# the mouse-off escape. Without it, a child that enabled mouse leaks tracking
# into the shell after exit (the root context's _tuish_mouse is still 0).
_tuish_mouse_dev=0

# ─── Control ────────────────────────────────────────────────────────

_tuish_quit=''
_tuish_quit_mode=''

tuish_quit ()       { _tuish_quit=yes; _tuish_quit_mode=''; }
tuish_quit_main ()  { _tuish_quit=yes; _tuish_quit_mode=main; }
tuish_quit_clear () { _tuish_quit=yes; _tuish_quit_mode=clear; }

# ─── Internal state ─────────────────────────────────────────────────

_tuish_byte=''
_tuish_signal=''
_tuish_precols=''
_tuish_previous_stty=''
_tuish_stty=''
_tuish_esc_timeout=''
_tuish_idle_timeout=''
_tuish_idle_chunk='-t0.03'
_tuish_idle_chunks=1
_tuish_interval_s='0.26'   # the interval (seconds string) the active context runs at
TUISH_TICK_US=260000       # _tuish_interval_s in µs; real value derived at tuish_init
_tuish_pending_byte=''
_tuish_initialized=0

# Set by the EXIT trap (device-global, NOT a context field) so tuish_fini can
# tell "the process is exiting" from "a host is unmounting a child". On a real
# exit with a child context still active, the device MUST be restored (stty,
# alt-screen, mouse, traps) — the child-unmount path deliberately skips that, so
# without this flag a signal mid-embed leaves the terminal wedged.
_tuish_exiting=0

# Set to 1 by tuish_ctx_dispatch while a cooperatively-driven child processes an
# event (device-global, not a context field). The out-of-region-click handler
# (event.sh) reads it to suppress its self-quit for driven children — see
# tuish_ctx_dispatch.
_tuish_driven=0

# Default byte reader (overridden by tuish_init with shell-specific version)
_tuish_get_byte () { return 1; }
_tuish_idle_wait () { return 1; }
_tuish_peek_byte () { return 1; }

# Overridable hooks declared in the base so the override arrow always points
# base -> optional module: each module below just redefines its hook. Declaring
# them in a sibling optional module instead risked a re-source resetting one
# after another module had already overridden it.
_tuish_resolve_event ()      { :; }        # hid.sh
_tuish_viewport_on_resize () { :; }        # viewport.sh
tuish_dispatch ()            { return 1; } # keybind.sh
_tuish_hid_fini ()           { :; }        # hid.sh (mouse/kitty teardown)

TUISH_EVENT=''
TUISH_EVENT_KIND=''
TUISH_MOUSE_X=0
TUISH_MOUSE_Y=0
TUISH_RAW=''
TUISH_LINES=0
TUISH_COLUMNS=0
TUISH_INIT_ROW=0
_tuish_cursor_abs_row=0
_tuish_cursor_vrow=0
_tuish_cursor_vcol=0
TUISH_PROTOCOL=''
TUISH_TIMING="${TUISH_TIMING:-}"   # preserve a launcher-declared value (fast-path)
TUISH_TABSIZE="${TUISH_TABSIZE:-4}"
TUISH_FINI_OFFSET="${TUISH_FINI_OFFSET:-0}"
TUISH_MOUSE_ABS_Y=0

# ─── Viewport defaults (ABI seam) ────────────────────────────────
# TUISH_VIEW_TOP / TUISH_VIEW_COLS / _tuish_view_mode are read by term.sh
# (vmove, draw clipping), event.sh and hid.sh on hot paths, so they default
# here and must exist even when viewport.sh is not sourced. viewport.sh updates
# them; _tuish_on_fini is its teardown hook.

TUISH_VIEW_MODE=''
TUISH_VIEW_ROWS=0
TUISH_VIEW_COLS=0
TUISH_VIEW_TOP=1
# Column origin of the viewport (0-based), mirror of TUISH_VIEW_TOP for rows.
# 0 for the root (viewport starts at column 1); a hosted child gets the absolute
# column of its region, so its logical column 1 lands at the region's left edge.
TUISH_VIEW_LEFT=0

_tuish_view_mode=''
_tuish_fini_push_gap=0
_tuish_on_fini () { :; }

# Per-context APP fini handler, referenced by name (same model as the render/
# event handlers in event.sh). An app that changes device state mid-run (cursor
# shape, a draw backend, ...) registers its restore here; tuish_fini runs it on
# EVERY exit path — standalone teardown, modal return, and cooperative unmount —
# so the cleanup an app used to place after tuish_run (which a driven app never
# reaches) has a first-class home.
# Setter only (unlike the polymorphic tuish_on_redraw / tuish_on_event, which the
# framework also CALLS as a fallback — this one is never called, only registered).
# Not to be confused with _tuish_on_fini, the framework's internal viewport-teardown
# hook one underscore away.
_tuish_fini_fn=''
tuish_on_fini () { _tuish_fini_fn="${1:-}"; }

# ─── Transform state (the tuish_vmove origin/scale/clip) ─────────
# tuish_vmove maps a logical (row,col) onto an absolute terminal cell through a
# single affine+clip transform. The default below is the viewport identity: no
# column shift, unit cells, and a clip only at the physical bottom. canvas.sh
# overwrites _tx_* to address a bounded sub-region (4-edge clipped, optionally
# CWxCH-scaled). The row origin folds in TUISH_VIEW_TOP live (read in vmove), so
# the transform survives a resize.

_tx_off_r=0
_tx_off_c=0
_tx_ch=1
_tx_cw=1
_tx_lrmin=-99999
_tx_lrmax=99999
_tx_lcmin=-99999
_tx_lcmax=99999

# Base clip that _tuish_tx_reset returns to (i.e. what "canvas off" means). For
# the root this is the whole screen (the historical constants); a hosted child's
# context seeds these to its region bounds, so its tuish_canvas_off falls back to
# the region rather than escaping to the full terminal.
_tuish_base_lrmin=-99999
_tuish_base_lrmax=99999
_tuish_base_lcmin=-99999
_tuish_base_lcmax=99999

# Reset the transform to the context's base region (canvas off).
_tuish_tx_reset ()
{
	_tx_off_r=0; _tx_off_c=0; _tx_ch=1; _tx_cw=1
	_tx_lrmin=$_tuish_base_lrmin; _tx_lrmax=$_tuish_base_lrmax
	_tx_lcmin=$_tuish_base_lcmin; _tx_lcmax=$_tuish_base_lcmax
}

# ─── Canvas state (public flags; geometry lives in _tx_* above) ──
TUISH_CANVAS=0
TUISH_CANVAS_W=0
TUISH_CANVAS_H=0
TUISH_CANVAS_CW=1
TUISH_CANVAS_CH=1

_tuish_canvas_on=0
_tuish_canvas_r=1
_tuish_canvas_c=1

# ─── Context / instance management ───────────────────────────────
# tuish's logical state is owned by per-app CONTEXTS, so multiple apps can
# coexist in one process (a host running another app inside a region of itself).
# The active context's fields live in the plain working globals declared above
# (the "registers", read on the hot paths); inactive contexts are spilled to
# namespaced _tuish_ctx_<id>_<field> vars (the "saved frames"). A context switch
# marshals a fixed, registered field list and happens only at modal boundaries
# (a host entering/leaving a child) — never per byte or per frame — so the hot
# paths pay nothing. The terminal DEVICE (stty, traps, byte reader, size,
# protocol, ord tables) is singular and is NOT part of any context.

_tuish_ctx_active=''
_tuish_ctx_next=0
TUISH_CTX=0
TUISH_CTX_ROOT=0
_tuish_ctx_parent=''
_tuish_ctx_names=''

# A context's region: the absolute terminal rectangle it draws inside. The root
# is not hosted — its region is the whole screen (rows/cols 0 mean "use
# TUISH_LINES/COLUMNS"). A child seeded by tuish_ctx_create_region gets _hosted=1
# and its rectangle, so a hosted "fullscreen" fills the region instead of the
# terminal (and never touches the alt-screen).
_tuish_hosted=0
_tuish_rgn_top=1
_tuish_rgn_left=0
_tuish_rgn_rows=0
_tuish_rgn_cols=0

# Register working vars as marshalled context fields. Each field's DEFAULT is
# captured live from its current value, so a register call must follow the var's
# own declaration (no default is duplicated here). Optional modules register
# their own fields the same way; only sourced modules contribute, so the marshal
# never references an unset var under set -u.
tuish_ctx_register ()
{
	local _n
	for _n in "$@"
	do
		_tuish_ctx_names="${_tuish_ctx_names} ${_n}"
	done
	_tuish_ctx_recapture "$@"
}

# Capture the default of already-registered fields from their CURRENT values — the
# second half of tuish_ctx_register, on its own because some state only takes its
# real value at device init (the idle timing). Re-running it after init refreshes
# those defaults, so contexts created later inherit the live host value instead of
# the pre-init placeholder captured at source time.
_tuish_ctx_recapture ()
{
	local _n
	for _n in "$@"
	do
		eval "_tuish_ctx_dflt_${_n}=\$${_n}"
	done
}

# Reset every registered working var to its captured default. Straight per-field
# loop in a helper (its control var is local and dies on return) — safe under the
# event.sh zsh loop-var invariant, which concerns tuish_run's own frame only.
_tuish_ctx_defaults ()
{
	local _f
	for _f in $_tuish_ctx_names
	do
		eval "${_f}=\$_tuish_ctx_dflt_${_f}"
	done
}

# Spill the active working set into frame $1 / fill the working set from frame $1.
_tuish_ctx_save ()
{
	local _f
	for _f in $_tuish_ctx_names
	do
		eval "_tuish_ctx_${1}_${_f}=\$${_f}"
	done
}
_tuish_ctx_load ()
{
	local _f
	for _f in $_tuish_ctx_names
	do
		eval "${_f}=\$_tuish_ctx_${1}_${_f}"
	done
}

# Allocate a fresh context seeded with default field values; its id lands in
# TUISH_CTX. Does not change which context is active.
tuish_ctx_create ()
{
	_tuish_ctx_next=$(( _tuish_ctx_next + 1 ))
	TUISH_CTX=$_tuish_ctx_next
	local _prev="$_tuish_ctx_active"
	test -n "$_prev" && _tuish_ctx_save "$_prev"
	_tuish_ctx_defaults
	_tuish_ctx_parent="$_prev"
	# Give each context its own bind-table namespace so coexisting apps can't
	# collide. The first context (the root) keeps the empty prefix, so its keys
	# are byte-identical to the historical flat table.
	if test -n "${_tuish_kb_ns+x}"
	then
		if test "$TUISH_CTX" -eq 1
		then _tuish_kb_ns=''
		else _tuish_kb_ns="c${TUISH_CTX}_"
		fi
	fi
	_tuish_ctx_save "$TUISH_CTX"
	test -n "$_prev" && _tuish_ctx_load "$_prev"
	return 0
}

# Seat the ACTIVE context into the absolute rectangle (abs_row, abs_col, W, H) — the
# one place that knows which fields a region is made of. Shared by
# tuish_ctx_create_region (first seating) and tuish_ctx_reseat (re-seating) so the
# field list is never duplicated; hosts used to hand-copy this block.
#
# A region is THREE independent things, and keeping them apart is what lets a host
# scroll a live child under the edge of a pane:
#
#   layout size  TUISH_VIEW_ROWS/COLS  — how big the child THINKS it is. The child
#                                        lays out to fill this, so it must not change
#                                        just because part of the child is off-screen,
#                                        or the child reflows instead of sliding.
#   origin       TUISH_VIEW_TOP/LEFT   — where the child's logical (1,1) lands. May be
#                                        OUTSIDE the visible pane (even above row 1):
#                                        that is a child scrolled partly out of view.
#   visible clip _tuish_base_l*        — what may actually reach the terminal. Cells
#                                        outside it are dropped by tuish_vmove.
#
# $5..$8 give the clip window in ABSOLUTE cells (row, 0-based col, W, H); omitted, it
# is the region itself, which is the historical behaviour every existing caller gets.
_tuish_ctx_seat ()   # $1=abs_row $2=abs_col0 $3=W $4=H [$5=clip_row $6=clip_col0 $7=clip_w $8=clip_h]
{
	TUISH_VIEW_TOP=$1
	TUISH_VIEW_LEFT=$2
	TUISH_VIEW_ROWS=$4
	TUISH_VIEW_COLS=$3
	_tuish_hosted=1
	_tuish_rgn_top=$1
	_tuish_rgn_left=$2
	_tuish_rgn_rows=$4
	_tuish_rgn_cols=$3

	if test $# -ge 8
	then
		# Express the clip window in the CHILD's logical cells (the inverse of the
		# tuish_vmove map: row = abs - VIEW_TOP + 1, col = abs - VIEW_LEFT), then
		# intersect with the child's own extent. An empty intersection is fine — the
		# child is entirely off-pane and simply draws nothing.
		local _r0=$(( $5 - $1 + 1 ))          # first visible logical row
		local _r1=$(( $5 + $8 - 1 - $1 + 1 )) # last  visible logical row
		local _c0=$(( $6 + 1 - $2 ))          # first visible logical col
		local _c1=$(( $6 + $7 - $2 ))         # last  visible logical col
		test $_r0 -lt 1 && _r0=1
		test $_c0 -lt 1 && _c0=1
		test $_r1 -gt $4 && _r1=$4
		test $_c1 -gt $3 && _c1=$3
		_tuish_base_lrmin=$_r0; _tuish_base_lrmax=$_r1
		_tuish_base_lcmin=$_c0; _tuish_base_lcmax=$_c1
	else
		_tuish_base_lrmin=1; _tuish_base_lrmax=$4
		_tuish_base_lcmin=1; _tuish_base_lcmax=$3
	fi
	_tuish_tx_reset
}

# Create AND activate a child context bound to a region of the CURRENTLY ACTIVE
# (parent) context: R C are the region's top-left in the parent's logical coords,
# W H its size. The parent's live transform resolves the origin to absolute cells,
# so regions compose to any depth (page > example > overlay). The child's logical
# (1,1) is the region's top-left; its drawing clips to the region; a hosted
# "fullscreen" fills the region. On return the id is in TUISH_CTX; the caller runs
# the child, then tuish_ctx_activate <parent> + tuish_ctx_destroy <child>.
tuish_ctx_create_region ()
{
	local _abs_r=$(( TUISH_VIEW_TOP + _tx_off_r + ($1 - 1) * _tx_ch ))
	local _abs_c=$(( TUISH_VIEW_LEFT + _tx_off_c + ($2 - 1) * _tx_cw ))
	tuish_ctx_create
	tuish_ctx_activate "$TUISH_CTX"
	_tuish_ctx_seat "$_abs_r" "$_abs_c" "$3" "$4"
	return 0
}

# Move mounted child $1 to a new region of the CURRENTLY ACTIVE (host) context —
# R C W H in the host's logical coords, same frame as tuish_ctx_create_region. A
# host calls this from its resize handler so the child relayouts into the moved
# rectangle instead of stale geometry; the child then re-renders on the resize
# event it is forwarded. The host stays active on return.
#
# CR CC CW CH (optional, same coordinate frame) is the WINDOW the child may draw
# through — "here is your rectangle, and here is the hole you are seen through".
# Omitted, it is the region itself. This is what lets a host SCROLL a live child:
# pass a region whose top is above the pane (R may be <= 0) and the pane as the clip
# window, and the child slides under the pane's edge, clipped per cell. Its layout
# size stays W x H throughout, so it never reflows — it is genuinely occluded, not
# resized. See _tuish_ctx_seat.
tuish_ctx_reseat ()   # $1=ctx $2=R $3=C $4=W $5=H [$6=CR $7=CC $8=CW $9=CH]
{
	local _abs_r=$(( TUISH_VIEW_TOP + _tx_off_r + ($2 - 1) * _tx_ch ))
	local _abs_c=$(( TUISH_VIEW_LEFT + _tx_off_c + ($3 - 1) * _tx_cw ))
	local _host=$_tuish_ctx_active
	if test $# -ge 9
	then
		local _cab_r=$(( TUISH_VIEW_TOP + _tx_off_r + ($6 - 1) * _tx_ch ))
		local _cab_c=$(( TUISH_VIEW_LEFT + _tx_off_c + ($7 - 1) * _tx_cw ))
		tuish_ctx_activate "$1"
		_tuish_ctx_seat "$_abs_r" "$_abs_c" "$4" "$5" "$_cab_r" "$_cab_c" "$8" "$9"
		tuish_ctx_activate "$_host"
		return 0
	fi
	tuish_ctx_activate "$1"
	_tuish_ctx_seat "$_abs_r" "$_abs_c" "$4" "$5"
	tuish_ctx_activate "$_host"
	return 0
}

# Make context $1 active: spill the current one, fill from $1's frame.
tuish_ctx_activate ()
{
	test -n "$_tuish_ctx_active" && _tuish_ctx_save "$_tuish_ctx_active"
	_tuish_ctx_load "$1"
	_tuish_ctx_active="$1"
}

# Destroy context $1: free its bindings, then unset its saved frame.
tuish_ctx_destroy ()
{
	# Bindings first, while the frame still holds the context's namespace and its
	# list of bound keys (shell cannot unset by glob, so we unset each explicitly).
	local _ns='' _keys='' _k
	eval "_ns=\${_tuish_ctx_${1}__tuish_kb_ns:-}"
	eval "_keys=\${_tuish_ctx_${1}__tuish_kb_keys:-}"
	for _k in $_keys
	do
		eval "unset _tuish_kb_${_ns}${_k} 2>/dev/null" || :
	done

	local _f
	for _f in $_tuish_ctx_names
	do
		eval "unset _tuish_ctx_${1}_${_f} 2>/dev/null" || :
	done
}

# ─── Cooperative driving (non-modal hosting) ─────────────────────
# A host keeps its single tuish_run loop and DRIVES mounted children one event at
# a time, instead of each child running its own (blocking) tuish_run. When a child
# context is active the whole event pipeline already targets it — hid.sh decodes
# mouse into the child's region-local frame, tuish_dispatch uses the child's bind
# table, and the render path calls the child's handler — so driving a child is just
# "activate it, feed it the raw event, restore the host". Modal hosting (the child
# owning a nested tuish_run) still works; this is the alternative for live host
# chrome + simultaneous widgets.

# Set by tuish_ctx_dispatch to 1 when the child it just drove requested quit
# (the dispatched event ran the child's own tuish_quit / tuish_quit_clear — e.g.
# its bound 'q' or ctrl-w). Device-global, NOT a context field: it is the host's
# signal to unmount a child that ended ITSELF. This is the non-fragile
# cooperative-quit model — a driven app quits by its own means and the host
# detects it, instead of the host having to intercept the app's quit key (which a
# terminal or browser may reserve, e.g. Ctrl+W). A host checks it after each
# tuish_ctx_dispatch and calls tuish_ctx_unmount when set.
TUISH_CTX_QUIT=0

# Did the child ACT on the event we just handed it? Copied out of TUISH_HANDLED
# (event.sh) by _tuish_ctx_drive. A host uses it to CHAIN an event the child
# declined: the wheel over an inline widget that has nothing left to scroll should
# scroll the page, not vanish into the widget.
TUISH_CTX_HANDLED=0

# Feed raw descriptor $1 to the ALREADY-ACTIVE child and record whether it quit.
# The shared core of tuish_ctx_dispatch and tuish_ctx_tick.
#
# _tuish_driven marks "this child is being cooperatively driven, not running its own
# loop". The out-of-region-click handler (event.sh) uses it to stay quiet: in MODAL
# hosting an outside click self-quits the child to hand control back, but a DRIVEN
# child's host already routes out-of-region clicks itself (it only forwards what
# lands inside), so the child self-quitting would be a spurious quit — which
# TUISH_CTX_QUIT would then read as "the app ended" and unmount it.
_tuish_ctx_drive ()
{
	_tuish_driven=1
	_tuish_parse_event "$1"
	_tuish_driven=0
	TUISH_CTX_HANDLED=${TUISH_HANDLED:-0}
	# Surface a child-initiated quit to the host. The child is still active here, so
	# _tuish_quit is its value (its own quit binding set it to 'yes'); once we restore
	# the host it lives in the child's saved frame. The host reads TUISH_CTX_QUIT.
	if test "$_tuish_quit" = 'yes'
	then TUISH_CTX_QUIT=1
	else TUISH_CTX_QUIT=0
	fi
}

# Drive mounted child $1 with the event currently decoded in the active (host)
# context: TUISH_RAW holds the raw descriptor (event.sh:_tuish_parse_event), which
# the child re-resolves in its own region and dispatches/renders. Buffering and the
# redraw scheduler are per-context registers, so the child's tuish_begin/end and
# rAF render stay isolated from the host's. Requires event.sh (a cooperative host
# always sources it). No loop variable here — the zsh loop-var invariant is intact.
#
# Use this for INPUT (keys, mouse, resize). For idle, use tuish_ctx_tick, which
# honours each child's own tick rate instead of firing on every host tick.
tuish_ctx_dispatch ()
{
	local _host=$_tuish_ctx_active _raw=$TUISH_RAW
	tuish_ctx_activate "$1"
	_tuish_ctx_drive "$_raw"
	tuish_ctx_activate "$_host"
}

# Repaint mounted child $1 NOW: run its registered render handler at level -1 (full)
# inside its own context, so its transform and clip apply. A cooperative host calls
# this straight after tuish_ctx_reseat, so a child that just MOVED redraws into its new
# rectangle immediately instead of waiting for its next idle tick — at a lazy interval
# that would leave a visibly stale or torn widget on screen for a whole tick while the
# user scrolls. Requires event.sh (the render-handler indirection lives there).
tuish_ctx_render ()
{
	local _host=$_tuish_ctx_active
	tuish_ctx_activate "$1"
	tuish_begin
	"${_tuish_render_fn:-tuish_on_redraw}" -1
	tuish_end
	tuish_ctx_activate "$_host"
	return 0
}

# ─── Idle-tick negotiation ───────────────────────────────────────
# Children can want different clocks: a game at 50Hz next to a clock at 1Hz. Two
# rules make that work, and they pull in opposite directions:
#
#   the fast child must not be SLOWED  -> the host loop runs at the FASTEST tick
#                                         among itself and its children
#                                         (tuish_ctx_sync_interval)
#   the slow child must not be SPED UP -> each child accumulates the host's tick
#                                         and only fires an idle once ITS OWN
#                                         interval has elapsed (tuish_ctx_tick)
#
# So the host polls fast enough for the fastest child, and divides that down per
# child. A 50Hz game and a 1Hz clock hosted together each animate at their own
# rate, in one loop, with no forks and no wall-clock reads.
#
# Accumulated host-tick time (µs) since this context's last idle. Per-context.
_tuish_tick_acc=0

# Deliver an idle tick to mounted child $1 AT ITS OWN RATE. Call it where a
# cooperative host would otherwise tuish_ctx_dispatch an idle event: it adds the
# host's tick to the child's accumulator and only drives the child once the child's
# own interval (TUISH_TICK_US, set by its tuish_idle_interval) has elapsed.
tuish_ctx_tick ()   # $1 = ctx
{
	local _host=$_tuish_ctx_active _host_us=$TUISH_TICK_US _raw=$TUISH_RAW
	tuish_ctx_activate "$1"
	_tuish_tick_acc=$(( _tuish_tick_acc + _host_us ))
	if test "$_tuish_tick_acc" -ge "$TUISH_TICK_US"
	then
		_tuish_tick_acc=$(( _tuish_tick_acc - TUISH_TICK_US ))
		# Never bank more than one interval of credit: if the host tick is coarser
		# than the child's (the child asked for a rate the host cannot poll at), the
		# child runs as fast as the host can go rather than firing a catch-up burst.
		test "$_tuish_tick_acc" -ge "$TUISH_TICK_US" && _tuish_tick_acc=0
		_tuish_ctx_drive "$_raw"
	else
		TUISH_CTX_QUIT=0
	fi
	tuish_ctx_activate "$_host"
}

# Set the ACTIVE (host) loop to the fastest tick among itself and children $@, so no
# child is starved by a host that idles lazily. Each child is still ticked at its own
# rate by tuish_ctx_tick, so the slower ones do not speed up. Call it once, after
# mounting. Reads the children's saved frames directly — no activation round-trips.
tuish_ctx_sync_interval ()   # $@ = child ctx ids
{
	local _c _cu _min=$TUISH_TICK_US _s=''
	for _c in "$@"
	do
		eval "_cu=\${_tuish_ctx_${_c}_TUISH_TICK_US:-0}"
		if test "$_cu" -gt 0 && test "$_cu" -lt "$_min"
		then
			_min=$_cu
			eval "_s=\${_tuish_ctx_${_c}__tuish_interval_s:-}"
		fi
	done
	test -n "$_s" && tuish_idle_interval "$_s"
	return 0
}

# Mount a child in a region and run its (non-blocking) setup, leaving the host
# active. $1..$4 = region R C W H in the host's logical coords; $5 = the child's
# setup function (everything an example's _main does EXCEPT tuish_run/tuish_fini);
# $6.. = extra args passed to it. On return the child id is in TUISH_CTX. The child's
# setup calls tuish_init, which adopts the context created here (device already up),
# so the example is unchanged.
#
# The child's chosen tick (its tuish_idle_interval) is left in its own frame; after
# mounting all children, the host calls tuish_ctx_sync_interval to adopt the fastest.
# Optional clip window ("R C W H", the host's logical coords) for the NEXT
# tuish_ctx_mount. Set it when the child must be clipped from its VERY FIRST paint:
# a mount is not just bookkeeping, it runs the child's setup and paints it, so a
# child mounted partly outside its host's pane would draw over the host's chrome once
# before any tuish_ctx_reseat could bound it. Consumed and cleared by tuish_ctx_mount.
TUISH_MOUNT_CLIP=''

tuish_ctx_mount ()
{
	local _r=$1 _c=$2 _w=$3 _h=$4 _fn=$5
	shift 5
	local _host=$_tuish_ctx_active

	# Resolve the clip window in the HOST's frame — it has to happen here, before
	# create_region switches us into the child's.
	local _clip=0 _cab_r=0 _cab_c=0 _ccw=0 _cch=0
	if test -n "$TUISH_MOUNT_CLIP"
	then
		local _q="$TUISH_MOUNT_CLIP" _qr _qc
		_qr="${_q%% *}"; _q="${_q#* }"
		_qc="${_q%% *}"; _q="${_q#* }"
		_ccw="${_q%% *}"; _cch="${_q##* }"
		_cab_r=$(( TUISH_VIEW_TOP + _tx_off_r + (_qr - 1) * _tx_ch ))
		_cab_c=$(( TUISH_VIEW_LEFT + _tx_off_c + (_qc - 1) * _tx_cw ))
		_clip=1
	fi
	TUISH_MOUNT_CLIP=''

	tuish_ctx_create_region "$_r" "$_c" "$_w" "$_h"
	local _child=$TUISH_CTX
	test "$_clip" -eq 1 && _tuish_ctx_seat \
		"$TUISH_VIEW_TOP" "$TUISH_VIEW_LEFT" "$_w" "$_h" \
		"$_cab_r" "$_cab_c" "$_ccw" "$_cch"
	"$_fn" "$@"
	# Bootstrap idle: the exact first event tuish_run gives a standalone app, so
	# an idle-first app (one that paints on its first idle) renders NOW, at mount,
	# instead of waiting for the host's next idle tick. The child is still active,
	# so the paint lands in its region.
	_tuish_parse_event "F"
	tuish_ctx_activate "$_host"
	TUISH_CTX=$_child
	return 0
}

# Unmount a mounted child: fold its viewport and drop its context, resuming the
# host. tuish_fini's nested-child branch does exactly this (it never touches the
# shared device), and reactivates the parent (the host) on return.
tuish_ctx_unmount ()
{
	tuish_ctx_activate "$1"
	tuish_fini
}

# Register the base (tui.sh) context fields. Optional modules add their own.
tuish_ctx_register \
	_tuish_quit _tuish_quit_mode \
	_tuish_buf _tuish_buffering \
	_tx_off_r _tx_off_c _tx_ch _tx_cw \
	_tx_lrmin _tx_lrmax _tx_lcmin _tx_lcmax \
	TUISH_VIEW_MODE TUISH_VIEW_ROWS TUISH_VIEW_COLS TUISH_VIEW_TOP TUISH_VIEW_LEFT \
	_tuish_base_lrmin _tuish_base_lrmax _tuish_base_lcmin _tuish_base_lcmax \
	_tuish_view_mode _tuish_fini_push_gap TUISH_FINI_OFFSET _tuish_fini_fn \
	TUISH_CANVAS TUISH_CANVAS_W TUISH_CANVAS_H TUISH_CANVAS_CW TUISH_CANVAS_CH \
	_tuish_canvas_on _tuish_canvas_r _tuish_canvas_c \
	_tuish_mouse _tuish_detailed _tuish_modkeys _tuish_wrap \
	_tuish_cursor_abs_row _tuish_cursor_vrow _tuish_cursor_vcol \
	TUISH_EVENT TUISH_EVENT_KIND TUISH_RAW \
	TUISH_MOUSE_X TUISH_MOUSE_Y TUISH_MOUSE_ABS_Y \
	_tuish_hosted _tuish_rgn_top _tuish_rgn_left _tuish_rgn_rows _tuish_rgn_cols \
	_tuish_idle_timeout _tuish_idle_chunk _tuish_idle_chunks TUISH_TICK_US _tuish_tick_acc \
	_tuish_interval_s \
	_tuish_ctx_parent

# ─── Size management ────────────────────────────────────────────────

tuish_update_size ()
{
	local _ts
	_ts="$(stty size 2>/dev/null)"
	# `stty size` returns "ROWS COLS" on a normal tty, but some WASIX/browser ttys
	# report nothing (no TIOCGWINSZ), leaving both fields empty. Empty values then
	# feed the many unquoted numeric tests downstream (the tab-stop loop below,
	# viewport.sh, …) as `test -lt` with a missing operand — "argument expected",
	# and init collapses. Guard it: only accept a real "<int> <int>", else fall
	# back to $LINES/$COLUMNS (a launcher can export the terminal's real size) and
	# finally a sane 24x80. Native is unaffected (stty size matches the first arm).
	case "$_ts" in
		*[0-9]" "[0-9]*)
			TUISH_LINES="${_ts%% *}"
			TUISH_COLUMNS="${_ts##* }" ;;
		*)
			TUISH_LINES="${LINES:-24}"
			TUISH_COLUMNS="${COLUMNS:-80}" ;;
	esac
	# Never leave a non-numeric value in place.
	case "$TUISH_LINES"   in ''|*[!0-9]*) TUISH_LINES=24;;   esac
	case "$TUISH_COLUMNS" in ''|*[!0-9]*) TUISH_COLUMNS=80;;  esac
}

# ─── Timeout parsing ─────────────────────────────────────────────────
# _tuish_timeout_us TIMEOUT -> _tuish_tick_us
# Convert a seconds timeout string ("0.02", "0.26", "1", "0.5") to integer
# microseconds. The single parser behind both TUISH_TICK_US (animation clock)
# and the zsh idle-chunk count. Fractional part is read to 6 digits (µs); the
# whole and fraction are forced base-10 (10#) so leading-zero fractions like
# "020" are not misread as octal. Zero/empty falls back to ~60 Hz.
_tuish_timeout_us ()
{
	case "$1" in
		*.*) local _w="${1%.*}" _f="${1#*.}000000"
		     _f="${_f%"${_f#??????}"}"
		     _tuish_tick_us=$(( ${_w:-0} * 1000000 + 10#$_f ));;
		*)   _tuish_tick_us=$(( ${1:-0} * 1000000 ));;
	esac
	test "$_tuish_tick_us" -le 0 && _tuish_tick_us=16667
	return 0
}

# ─── Lifecycle ──────────────────────────────────────────────────────

# Detect the shell's byte-reading capability and define the input primitives
# (_tuish_get_byte / _tuish_idle_wait / _tuish_peek_byte) accordingly. Returns 1
# if the shell supports neither read -k (zsh) nor read -n (bash/ksh/busybox).
_tuish_init_io ()
{
	# Detect byte-reading capability. Both probes are fed from a heredoc (fd 9),
	# NOT a pipe: a pipe forks a subshell, and on fork-constrained runtimes
	# (browser/WASIX wasm, where fork is stubbed) that aborts init before raw
	# mode. A heredoc's data is in place with no fork, and detection is identical
	# (does the shell accept read -k / read -n). Native behaviour is unchanged.
	if { read -s -k1 -u9 2>/dev/null ;} 9<<'_TUISH_RK'
1
_TUISH_RK
	then
		_tuish_get_byte ()
		{
			IFS= read -r -k1 -u0 ${@:-} _tuish_byte 2>/dev/null || return 1
		}
		# Poll for input up to TUISH_IDLE_TIMEOUT, in <=30ms chunks: zsh defers
		# signals (traps) inside the read builtin, so each chunk boundary is a
		# delivery point and the trailing subshell fork forces any pending trap
		# to run. The chunk COUNT is derived from TUISH_IDLE_TIMEOUT in init
		# (_tuish_idle_chunks/_tuish_idle_chunk), so the idle interval honors the
		# configured timeout instead of a fixed 270ms.
		_tuish_idle_wait ()
		{
			local _i=$_tuish_idle_chunks
			while test $_i -gt 0
			do
				IFS= read -r -k1 -u0 $_tuish_idle_chunk _tuish_byte 2>/dev/null && return 0
				_i=$((_i - 1))
			done
			eval "$(:)" 2>/dev/null
			return 1
		}
		# zsh read -t0 reads a byte when one is available (unlike bash which
		# only checks). One call is enough to peek at the next pending byte.
		_tuish_peek_byte () { _tuish_get_byte -t0; }
	elif { read -r -t'0.1' -n 1 -u9 2>/dev/null ;} 9<<'_TUISH_RN'
1
_TUISH_RN
	then
		_tuish_get_byte ()
		{
			IFS= read -r -d '' -n 1 ${@:-} _tuish_byte 2>/dev/null || return 1
		}
		_tuish_idle_wait ()
		{
			_tuish_get_byte "$_tuish_idle_timeout"
		}
		# read -t0 semantics differ: bash/busybox only check availability
		# and need a second read to consume; ksh93/mksh consume the byte
		# on the spot (like zsh). Assuming the wrong one either loses
		# every other byte and blocks mid-burst (ksh93/mksh) or leaks
		# sequence bytes (zsh, see 258e6a4).
		#
		# ksh93 and mksh both set KSH_VERSION and both consume on -t0, so
		# select by shell identity. A runtime probe is unreliable here:
		# mksh's own `read -d '' -n 1 -t0` on a heredoc is non-deterministic
		# (it intermittently reports no data), which would sometimes pick the
		# two-read variant and then drop one byte on every peek that finds
		# input — the source of mksh's burst-event flakiness.
		if test -n "${KSH_VERSION:-}"
		then
			_tuish_peek_byte () { _tuish_get_byte -t0; }
		else
			# bash/busybox: probe with a heredoc — its data is in place
			# before read runs, so a zero timeout can't race the writer
			# the way a pipeline would. (Stable: both report no data, so
			# both take the two-read consume path.)
			_tuish_probe=''
			if { IFS= read -r -d '' -n 1 -t0 -u9 _tuish_probe 2>/dev/null &&
				test -n "${_tuish_probe}" ;} 9<<_tuish_heredoc
1
_tuish_heredoc
			then
				_tuish_peek_byte () { _tuish_get_byte -t0; }
			else
				_tuish_peek_byte () { _tuish_get_byte -t0 && _tuish_get_byte; }
			fi
		fi
	else
		echo 'Shell does not support interactive features (requires read -n or read -k)' 1>&2
		return 1
	fi
	return 0
}

# Derive the idle timeout, the zsh idle-chunk count, and TUISH_TICK_US (the µs
# per idle tick, used as the time-based-animation clock) from $1 (interval in
# seconds; empty = the timing-based default) and the already-detected
# TUISH_TIMING. Split out of _tuish_init_timing so it can be re-run at runtime by
# tuish_idle_interval — these values are per-context, so a hosted app can pick its
# own tick rate without disturbing its host. Takes the interval as a PARAMETER:
# TUISH_IDLE_TIMEOUT is pure launcher config, read once at init and never written
# by the framework (writing it back leaked one context's tick choice into the
# `${TUISH_IDLE_TIMEOUT:-...}` defaults of apps mounted later).
_tuish_derive_idle ()
{
	local _default='0.26'
	test "$TUISH_TIMING" = 'second' && _default='1'
	_tuish_interval_s="${1:-$_default}"
	_tuish_idle_timeout="-t${_tuish_interval_s}"

	# The idle interval in microseconds: the wall-time one idle tick spans.
	_tuish_timeout_us "$_tuish_interval_s"
	TUISH_TICK_US=$_tuish_tick_us

	# Chunked idle wait (zsh): poll in slices of at most 30ms up to the full
	# timeout so the idle interval tracks TUISH_IDLE_TIMEOUT. One read when it is
	# already <=30ms; otherwise ceil(timeout/30ms) slices of 30ms.
	_tuish_idle_chunk="$_tuish_idle_timeout"
	_tuish_idle_chunks=1
	if test "$TUISH_TIMING" != 'second'
	then
		local _itms=$(( TUISH_TICK_US / 1000 ))
		if test "$_itms" -gt 30
		then
			_tuish_idle_chunk='-t0.03'
			_tuish_idle_chunks=$(( (_itms + 29) / 30 ))
		fi
	fi
}

# Change the idle interval (the animation/tick clock) at runtime for the ACTIVE
# context — e.g. a hosted real-time app that wants a fast tick regardless of its
# host's. Per-context, so it is restored to the host's on return. SECS is a
# seconds value like 0.02 (sub-second needs a sub-timing terminal). Never touches
# TUISH_IDLE_TIMEOUT — that is launcher config, not state.
tuish_idle_interval ()
{
	_tuish_derive_idle "$1"
}

# Detect the timer resolution and derive the escape/idle timeouts and the zsh
# idle-chunk count from TUISH_IDLE_TIMEOUT.
_tuish_init_timing ()
{
	# Detect timeout resolution — whether `read -t` honors sub-second values. A
	# launcher can declare it (TUISH_TIMING=sub|second) to skip these two extra
	# pipe-forks; unset falls through to the probe, so native behaviour is unchanged.
	case "${TUISH_TIMING:-}" in
		sub|second) : ;;
		*)
			TUISH_TIMING='second'
			if { echo 1 | read -r -t'0.01' -n 1 2>/dev/null ;} ||
			   { echo 1 | read -r -t'0.01' -k1 -u0 2>/dev/null ;}
			then
				TUISH_TIMING='sub'
			fi ;;
	esac

	_tuish_esc_timeout="-t${TUISH_ESC_TIMEOUT:-0.02}"
	test "$TUISH_TIMING" = 'second' && _tuish_esc_timeout="-t${TUISH_ESC_TIMEOUT:-1}"
	_tuish_derive_idle "${TUISH_IDLE_TIMEOUT:-}"
	return 0
}

# Configure the terminal: variable init, stty + signal traps, setup escape
# sequences, cursor-position query, and tab stops.
_tuish_init_term ()
{
	_tuish_code=''
	_tuish_held=''
	_tuish_noinput=''

	# Save and configure terminal
	_tuish_previous_stty="$(stty -g)"
	_tuish_initialized=1
	trap '[ "${BASH_SUBSHELL:-${ZSH_SUBSHELL:-0}}" -eq 0 ] && { _tuish_exiting=1; tuish_fini; }' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	stty raw -echo -ctlecho -isig -icanon -ixon -ixoff -tostop -ocrnl \
		-icrnl -inlcr -igncr \
		intr undef quit undef werase undef discard undef time 0 2>/dev/null
	_tuish_stty="$(stty -g)"

	trap '_tuish_signal=resize; _tuish_precols=$TUISH_COLUMNS' WINCH 2>/dev/null || :
	trap ':' TSTP 2>/dev/null || :
	trap '_tuish_signal=cont; stty "$_tuish_stty"' CONT 2>/dev/null || :

	# Terminal setup sequences
	tuish_save_cursor
	_tuish_write '\033[?2004h\033[2K'   # bracketed paste, clear line
	_tuish_write '\033[22;0;0t'          # push title
	_tuish_write '\033[?1h'              # application cursor keys
	_tuish_write '\033[20l'              # LNM (ANSI mode 20) reset for the TUI
	tuish_hide_cursor

	# Get terminal size and cursor position via DSR. The CPR reply
	# (\033[<row>;<col>R) can arrive LATE relative to a single read window —
	# markedly so on a slow terminal (busybox under a multiplexer, and the
	# browser/wasm target, where the round-trip crosses a worker boundary). A
	# missed reply is not merely a lost row: the bytes leak into the first event
	# loop iteration, where \033[1;1R decodes as a spurious `f3` key. A line read
	# (`read -d R -t`) can also split the atomic reply across its timeout, dropping
	# it. So drain a byte at a time with the same FSM the mid-run cursor query uses
	# (viewport.sh:_tuish_query_cursor_row): once the reply starts it arrives
	# contiguously, so only the first byte waits; a tty that never answers (a pipe,
	# CI) gives up after one per-byte timeout. Native startup is unchanged.
	tuish_update_size
	local _newx=0 _newy=0
	_tuish_write '\033[6n\r'
	if type _tuish_get_byte >/dev/null 2>&1
	then
		local _cst=0 _crow='' _ccol=''
		while _tuish_get_byte -t0.5
		do
			case $_cst in
				0) _tuish_ord "$_tuish_byte"
				   test $_tuish_code -eq 27 && _cst=1 ;;
				1) case "$_tuish_byte" in '[') _cst=2 ;; *) _cst=0 ;; esac ;;
				2) case "$_tuish_byte" in
				       [0-9]) _crow="${_crow}${_tuish_byte}" ;;
				       ';') _cst=3 ;;
				       *) _cst=0; _crow='' ;;
				   esac ;;
				3) case "$_tuish_byte" in
				       [0-9]) _ccol="${_ccol}${_tuish_byte}" ;;
				       R) test -n "$_crow" && _newx=$_crow; test -n "$_ccol" && _newy=$_ccol; break ;;
				       *) _cst=0; _crow=''; _ccol='' ;;
				   esac ;;
			esac
		done
	fi
	TUISH_INIT_ROW=$_newx

	# Focus events (mouse tracking is off by default; use tuish_mouse_on)
	_tuish_write '\033[?1004h'   # focus events
	_tuish_write '\033[777h'     # ambiguous width
	_tuish_write '\033[?7l'      # DECAWM off: clip at right edge

	TUISH_PROTOCOL='vt'

	# Set tab stops
	_tuish_write '\033[3g'
	local _tcont=0
	while test $_tcont -lt ${TUISH_COLUMNS}
	do
		_tuish_write '\033['"${TUISH_TABSIZE}"'C\033H'
		_tcont=$((_tcont + TUISH_TABSIZE))
	done
	_tuish_write '\r'
}

# Bring up the shared terminal DEVICE (raw mode, timing, setup sequences). Runs
# exactly once per process; nested apps skip it (the device is already up).
_tuish_device_init ()
{
	_tuish_init_io || return 1
	_tuish_init_timing
	_tuish_init_term
}

tuish_init ()
{
	if test "$_tuish_initialized" -eq 1
	then
		# Device already up — we are nested inside a host. Adopt the context the
		# host activated for us; create+activate one if the host did not.
		if test -z "$_tuish_ctx_active"
		then
			tuish_ctx_create
			tuish_ctx_activate "$TUISH_CTX"
		fi
		return 0
	fi
	_tuish_device_init || return 1
	# The idle timing only takes its real value here, in device init. Refresh its
	# registered defaults so contexts created later inherit the live host tick
	# (not the source-time placeholder), then build the root context from them.
	_tuish_ctx_recapture _tuish_idle_timeout _tuish_idle_chunk _tuish_idle_chunks TUISH_TICK_US _tuish_interval_s
	tuish_ctx_create
	TUISH_CTX_ROOT=$TUISH_CTX
	tuish_ctx_activate "$TUISH_CTX_ROOT"
	return 0
}

tuish_fini ()
{
	# Nested child being UNMOUNTED by its host (explicit tuish_fini / modal return,
	# not process exit): fold only its own viewport, drop its context, and resume
	# the parent. The shared device (stty/traps) stays up for the host — a child
	# must never restore the terminal out from under its host. But on a real exit
	# (_tuish_exiting, set by the EXIT trap) we fall through to device teardown even
	# with a child active — otherwise a signal mid-embed leaves the terminal in raw
	# mode / alt-screen. The child's own cleanup still runs, below, in the device
	# path (it reads the active context's _tuish_fini_fn, which is the child's).
	if test "${_tuish_exiting:-0}" -eq 0 \
		&& test -n "$_tuish_ctx_active" && test "$_tuish_ctx_active" != "$TUISH_CTX_ROOT"
	then
		_tuish_buffering=0
		_tuish_buf=''
		# The app's own registered cleanup (device state it changed: cursor
		# shape, ...) — the code after a driven app's tuish_run never runs, so
		# this is its one reliable teardown point.
		test -n "$_tuish_fini_fn" && { "$_tuish_fini_fn" || :; }
		_tuish_on_fini
		local _cur="$_tuish_ctx_active" _p="$_tuish_ctx_parent"
		test -n "$_p" && tuish_ctx_activate "$_p"
		tuish_ctx_destroy "$_cur"
		return 0
	fi

	# Idempotent: safe to call from both explicit call and EXIT trap
	test "$_tuish_initialized" -eq 0 && return 0
	_tuish_initialized=0
	trap - EXIT INT TERM HUP 2>/dev/null || :
	trap - WINCH TSTP CONT 2>/dev/null || :

	# Bypass buffering so cleanup sequences reach the terminal
	_tuish_buffering=0
	_tuish_buf=''

	# Hide cursor during cleanup to avoid flicker
	tuish_hide_cursor

	# The app's registered cleanup, then the viewport teardown.
	test -n "${_tuish_fini_fn:-}" && { "$_tuish_fini_fn" || :; }
	_tuish_fini_push_gap=0
	_tuish_on_fini

	# Restore keyboard protocol
	if test "$TUISH_PROTOCOL" = 'kitty'
	then
		_tuish_write '\033[<u'
		_tuish_write '\033[>0u'
		TUISH_PROTOCOL='vt'
	fi

	# Restore terminal
	tuish_reset_scroll
	_tuish_hid_fini              # hid.sh: disable mouse tracking if it was on
	_tuish_write '\033[?1004l'   # focus events off
	_tuish_write '\033[777l'
	_tuish_write '\033[?2004l'   # bracketed paste off
	_tuish_write '\033[?1l'      # normal cursor keys
	_tuish_write '\033>'         # normal keypad
	tuish_restore_cursor
	# DECAWM must be restored AFTER DECRC (tuish_restore_cursor): the viewport
	# teardown's DECSC saved cursor state while autowrap was off (init sets
	# \033[?7l), and on conpty/Windows Terminal DECRC restores DECAWM to that
	# saved-off value — reverting an earlier \033[?7h. (xterm/tmux don't, which
	# is why this only bit some terminals.) Re-assert it here, last.
	_tuish_write '\033[?7h'      # DECAWM on: restore auto-wrap
	if test "${TUISH_FINI_OFFSET:-0}" -gt 0
	then
		_tuish_write '\033['"${TUISH_FINI_OFFSET}"'B'
	fi
	# Move cursor up past empty space left by viewport push
	if test $_tuish_fini_push_gap -gt 0 && test "$_tuish_quit_mode" != 'main'
	then
		_tuish_write '\033['"$_tuish_fini_push_gap"'A'
	fi
	_tuish_write '\033[20h'      # LNM (ANSI mode 20) set: restore newline mode
	_tuish_write '\033[23;0;0t'  # pop title
	_tuish_write '\033[0 q'   # DECSCUSR: restore default cursor shape
	tuish_show_cursor

	# Restore stty: prefer the exact saved state so a faithful snapshot
	# (e.g. IUTF8, and any terminal-specific flags) is preserved. Fall back
	# to sane only if we never captured one (init aborted) or the restore
	# fails — otherwise `stty sane` clobbers the just-restored original.
	if test -n "${_tuish_previous_stty:-}" && stty "$_tuish_previous_stty" 2>/dev/null
	then :
	else stty sane echo icanon 2>/dev/null || :
	fi

	# Drain stdin
	while read -r -t'0.1' 2>/dev/null
	do
		:
	done

	if test "$_tuish_quit_mode" = 'main'
	then
		# Position cursor below last content row
		test $_tuish_fini_push_gap -gt 0 && _tuish_write '\n' || :
	else
		_tuish_write '\r\033[2K'
	fi

	# Drop the root context now that the device is down.
	if test -n "$_tuish_ctx_active"
	then
		tuish_ctx_destroy "$_tuish_ctx_active"
		_tuish_ctx_active=''
	fi
}
