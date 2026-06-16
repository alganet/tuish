#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for viewport transitions and tuish_fini cleanup

set -uf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"
. "$TESTS_DIR/../src/viewport.sh"

printf 'Unit tests: viewport transitions\n'

# ─── Capture infrastructure ──────────────────────────────────────
# Mock terminal primitives to capture output sequences.

_vp_out=''
_tuish_write () { _vp_out="${_vp_out}$*"; }
_tuish_out ()   { _vp_out="${_vp_out}$*"; }
tuish_move ()            { _tuish_cursor_abs_row=$1; _vp_out="${_vp_out}[M$1,$2]"; }
tuish_vmove ()           { local _abs=$((TUISH_VIEW_TOP + $1 - 1)); if test $_abs -gt $TUISH_LINES; then return 1; fi; _tuish_cursor_abs_row=$_abs; _vp_out="${_vp_out}[VM$1,$2]"; }
tuish_clear_line ()      { _vp_out="${_vp_out}[CL]"; }
tuish_clear_screen ()    { _vp_out="${_vp_out}[CS]"; }
tuish_altscreen_on ()    { _vp_out="${_vp_out}[ALTON]"; }
tuish_altscreen_off ()   { _vp_out="${_vp_out}[ALTOFF]"; }
tuish_save_cursor ()     { _vp_out="${_vp_out}[SC]"; }
tuish_restore_cursor ()  { _vp_out="${_vp_out}[RC]"; }
tuish_reset_scroll ()    { _vp_out="${_vp_out}[RS]"; }
tuish_scroll_region ()   { _vp_out="${_vp_out}[SR$1,$2]"; }
tuish_show_cursor ()     { _vp_out="${_vp_out}[SHOW]"; }
tuish_hide_cursor ()     { :; }
tuish_sgr_reset ()       { :; }

# Stub stty (not available in unit tests)
stty () { :; }

# ─── Helper ──────────────────────────────────────────────────────

assert_not_contains () {
	_test_total=$((_test_total + 1))
	case "$1" in
		*"$2"*)
			_test_fail=$((_test_fail + 1))
			printf '  FAIL: %s (output should not contain "%s")\n' "$3" "$2"
			;;
		*)
			_test_pass=$((_test_pass + 1))
			printf '  PASS: %s\n' "$3"
			;;
	esac
}

_vp_setup ()
{
	_vp_out=''
	TUISH_INIT_ROW=1
	TUISH_LINES=24
	TUISH_COLUMNS=80
	TUISH_VIEW_TOP=1
	TUISH_VIEW_ROWS=0
	TUISH_VIEW_COLS=80
	TUISH_FINI_OFFSET=0
	TUISH_PROTOCOL='vt'
	_tuish_view_mode=''
	_tuish_view_max=15
	_tuish_view_origin=1
	_tuish_view_anchor=0
	_tuish_view_saved_origin=0
	_tuish_view_saved_anchor=0
	_tuish_view_altscreen=0
	_tuish_view_grow_phase=0
	_tuish_view_grow_count=0
	_tuish_mouse=0
	_tuish_wrap=0
	_tuish_quit=''
	_tuish_quit_mode=''
	_tuish_initialized=1
	_tuish_cursor_abs_row=0
	_tuish_view_phys=0
	_tuish_buffering=0
	_tuish_buf=''
}

# ─── Tests: fullscreen fini ──────────────────────────────────────

# Fullscreen + quit: should turn off alt screen
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_quit_mode=''
_vp_out=''
tuish_fini
assert_contains "$_vp_out" "[ALTOFF]" "fullscreen quit: alt screen off"
assert_contains "$_vp_out" "[M1,1]" "fullscreen quit: cursor at init row"

# Fullscreen + quit_main: should turn off alt screen, no viewport artifact
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_quit_mode='main'
_vp_out=''
tuish_fini
assert_contains "$_vp_out" "[ALTOFF]" "fullscreen quit_main: alt screen off"
assert_not_contains "$_vp_out" "[ALTON]" "fullscreen quit_main: no re-enter alt screen"
assert_not_contains "$_vp_out" "[SR" "fullscreen quit_main: no scroll region set"

# Fullscreen + quit_clear: should turn off alt screen
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_quit_mode='clear'
_vp_out=''
tuish_fini
assert_contains "$_vp_out" "[ALTOFF]" "fullscreen quit_clear: alt screen off"
assert_not_contains "$_vp_out" "[ALTON]" "fullscreen quit_clear: no re-enter alt screen"

# ─── Tests: fixed→fullscreen clears viewport ─────────────────────

# Switching from fixed to fullscreen should clear the fixed viewport
_vp_setup
_tuish_view_mode='fixed'
_tuish_view_origin=1
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
_vp_out=''
tuish_viewport fullscreen
# Should contain clear-line calls for the old fixed viewport (physical rows)
assert_contains "$_vp_out" "[M1,1][CL]" "fixed→fullscreen: clears row 1"
assert_contains "$_vp_out" "[M10,1][CL]" "fixed→fullscreen: clears last row"
assert_contains "$_vp_out" "[ALTON]" "fixed→fullscreen: enters alt screen"

# ─── Tests: pure fullscreen has no stale clear ───────────────────

# Entering fullscreen from no mode should not produce clear-line calls
_vp_setup
_tuish_view_mode=''
_vp_out=''
tuish_viewport fullscreen
assert_not_contains "$_vp_out" "[CL]" "none→fullscreen: no viewport clear"
assert_contains "$_vp_out" "[ALTON]" "none→fullscreen: enters alt screen"

# ─── Tests: fullscreen fini clears screen before alt off ─────────

# quit_clear in fullscreen: must clear screen before switching off alt screen
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_quit_mode='clear'
_vp_out=''
tuish_fini
assert_contains "$_vp_out" "[CS][ALTOFF]" "fullscreen quit_clear: clear screen before alt off"

# plain quit in fullscreen: same — clear screen then alt off
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_quit_mode=''
_vp_out=''
tuish_fini
assert_contains "$_vp_out" "[CS][ALTOFF]" "fullscreen quit: clear screen before alt off"

# quit_main in fullscreen: still clears (can't preserve alt screen content)
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_quit_mode='main'
_vp_out=''
tuish_fini
assert_contains "$_vp_out" "[CS][ALTOFF]" "fullscreen quit_main: clear screen before alt off"

# ─── Tests: fini escape sequence correctness ─────────────────────

# Verify the mode 777 reset has a proper final byte (not malformed)
_vp_setup
_tuish_view_mode=''
_vp_out=''
tuish_fini
# The output should contain "777l" (proper CSI final byte), not bare "777"
assert_contains "$_vp_out" "777l" "fini: mode 777 reset has final byte"

# ─── Tests: viewport bypasses output buffering ───────────────────

# tuish_viewport must flush buffer and write directly, not into the
# event-handler buffer (which gets discarded by the rAF redraw path).

# altscreen_off during buffered fullscreen→fixed reaches terminal
_vp_setup
_tuish_view_mode='fixed'
_tuish_view_origin=1
TUISH_VIEW_ROWS=10
tuish_viewport fullscreen
_vp_out=''
_tuish_buffering=1   # simulate event handler buffering (tuish_begin)
_tuish_buf='DISCARD'
tuish_viewport fixed 10
# The viewport sequences should be in _vp_out (written directly),
# not lost in the discarded buffer.
assert_contains "$_vp_out" "[ALTOFF]" "buffered fullscreen→fixed: altscreen off reaches terminal"
assert_contains "$_vp_out" "[SR" "buffered fullscreen→fixed: scroll region set"
# Buffering state should be restored
assert_eq "$_tuish_buffering" "1" "buffered fullscreen→fixed: buffering restored"

# altscreen_on during buffered fixed→fullscreen reaches terminal
_vp_setup
_tuish_view_mode='fixed'
_tuish_view_origin=5
_tuish_view_anchor=5
TUISH_VIEW_ROWS=10
_tuish_buffering=1
_tuish_buf='DISCARD'
_vp_out=''
tuish_viewport fullscreen
assert_contains "$_vp_out" "[ALTON]" "buffered fixed→fullscreen: altscreen on reaches terminal"
assert_eq "$_tuish_buffering" "1" "buffered fixed→fullscreen: buffering restored"

# tuish_fini clears buffering state
_vp_setup
_tuish_buffering=1
_tuish_buf='stale'
_vp_out=''
tuish_fini
assert_eq "$_tuish_buffering" "0" "fini: buffering disabled"

# ─── Tests: saved origin round-trip ──────────────────────────────

# fixed→fullscreen saves origin; fullscreen→fixed restores it
_vp_setup
TUISH_INIT_ROW=5
_tuish_view_mode='fixed'
_tuish_view_origin=3   # simulate a pushed origin (< TUISH_INIT_ROW)
_tuish_view_anchor=3
TUISH_VIEW_ROWS=10
_vp_out=''
tuish_viewport fullscreen
assert_eq "$_tuish_view_saved_origin" "3" "fixed→fullscreen: origin saved"

_vp_out=''
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "3" "fullscreen→fixed: origin restored"
assert_eq "$_tuish_view_saved_origin" "0" "fullscreen→fixed: saved origin consumed"

# No origin saved when switching fixed→fixed (not going through fullscreen)
_vp_setup
_tuish_view_mode='fixed'
_tuish_view_origin=3
_tuish_view_anchor=3
TUISH_VIEW_ROWS=10
_vp_out=''
tuish_viewport fixed 10
assert_eq "$_tuish_view_saved_origin" "0" "fixed→fixed: no origin saved"
assert_eq "$_tuish_view_origin" "1" "fixed→fixed: origin reset to TUISH_INIT_ROW"

# ─── Tests: no double push on round-trip ─────────────────────────

# reserve_space should NOT run when returning from fullscreen with
# a saved origin (origin != TUISH_INIT_ROW).  We detect this by
# checking that no newlines are emitted (reserve_space emits \n).
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=25
_tuish_view_mode='fixed'
_tuish_view_origin=16   # pushed origin
_tuish_view_anchor=16
TUISH_VIEW_ROWS=10
_vp_out=''
tuish_viewport fullscreen

_vp_out=''
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "16" "round-trip: origin stays at 16 (no re-push)"
assert_not_contains "$_vp_out" '\n' "round-trip: no newlines emitted (reserve_space skipped)"

# Multiple round-trips: origin must not drift
_vp_out=''
tuish_viewport fullscreen
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "16" "double round-trip: origin stable at 16"
_vp_out=''
tuish_viewport fullscreen
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "16" "triple round-trip: origin stable at 16"

# ─── Tests: viewport clears full area before altscreen ───────────

# When fixed viewport was pushed (origin < INIT_ROW), all viewport
# rows must be cleared before entering alt screen.
_vp_setup
TUISH_INIT_ROW=20
_tuish_view_mode='fixed'
_tuish_view_origin=16
_tuish_view_anchor=16
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
_vp_out=''
tuish_viewport fullscreen
assert_contains "$_vp_out" "[M16,1][CL]" "pushed fixed→fullscreen: clears from origin"
assert_contains "$_vp_out" "[M25,1][CL]" "pushed fixed→fullscreen: clears to last row"

# ─── Tests: fini idempotency ─────────────────────────────────────

# Double fini: second call is a no-op
_vp_setup
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
tuish_fini
_vp_out=''
tuish_fini
assert_eq "$_vp_out" "" "double fini: second call is no-op"

# ─── Tests: fini cursor adjustment for pushed viewport ─────────

# quit_main with pushed viewport: cursor does NOT move up
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=24
_tuish_view_mode='fixed'
_tuish_view_origin=15
TUISH_VIEW_ROWS=10
_tuish_quit_mode='main'
_vp_out=''
tuish_fini
assert_not_contains "$_vp_out" 'A' "quit_main pushed: no cursor up"

# quit_clear without push: no cursor adjustment
_vp_setup
TUISH_INIT_ROW=5
_tuish_view_mode='fixed'
_tuish_view_origin=5
TUISH_VIEW_ROWS=10
_tuish_quit_mode='clear'
_vp_out=''
tuish_fini
assert_not_contains "$_vp_out" 'A' "quit_clear no push: no cursor up"

# fullscreen fini without saved origin: no cursor adjustment
# (check for specific CUU escape since [ALTOFF] mock contains 'A')
_vp_setup
TUISH_INIT_ROW=5
_tuish_view_mode='fullscreen'
_tuish_view_altscreen=1
_tuish_view_saved_origin=0
_tuish_quit_mode='clear'
_vp_out=''
tuish_fini
assert_not_contains "$_vp_out" '[5A' "fullscreen quit_clear no push: no cursor up"

# ─── Tests: reserve_space push count ───────────────────────────

# Helper: count occurrences of \n in _vp_out (reserve_space emits literal \n)
_count_newlines () {
	local _s="$1" _c=0
	while :
	do
		case "$_s" in
			*'\n'*) _c=$((_c + 1)); _s="${_s#*\\n}";;
			*) break;;
		esac
	done
	echo $_c
}

# Cursor at bottom: push = VIEW_ROWS - 1 (all scrolls, no cursor-to-bottom)
_vp_setup
TUISH_INIT_ROW=24
TUISH_LINES=24
_tuish_view_mode=''
_vp_out=''
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "15" "reserve bottom: origin pinned to 15"
# 9 newlines emitted (VIEW_ROWS - 1)
assert_eq "$(_count_newlines "$_vp_out")" "9" "reserve bottom: 9 newlines"

# Cursor in middle: push = VIEW_ROWS - 1 (cursor-to-bottom + scrolls)
_vp_setup
TUISH_INIT_ROW=18
TUISH_LINES=24
_tuish_view_mode=''
_vp_out=''
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "15" "reserve middle: origin pinned to 15"
assert_eq "$(_count_newlines "$_vp_out")" "9" "reserve middle: 9 newlines"

# No push needed: viewport fits below cursor
_vp_setup
TUISH_INIT_ROW=5
TUISH_LINES=24
_tuish_view_mode=''
_vp_out=''
tuish_viewport fixed 10
assert_eq "$_tuish_view_origin" "5" "reserve fits: origin stays at INIT_ROW"
assert_eq "$(_count_newlines "$_vp_out")" "0" "reserve fits: no newlines"

# Full screen viewport: clips to LINES-1 to preserve invocation line
_vp_setup
TUISH_INIT_ROW=24
TUISH_LINES=24
_tuish_view_mode=''
_vp_out=''
tuish_viewport fixed 24
assert_eq "$_tuish_view_origin" "2" "reserve fullscreen: origin at 2"
assert_eq "$(_count_newlines "$_vp_out")" "22" "reserve fullscreen: 22 newlines"

# ─── Tests: resize behaviour ─────────────────────────────────────

# Helper: simulate a resize.  Set _new_lines/_new_cols before
# calling _tuish_viewport_on_resize; the stub tuish_update_size
# applies them (mirroring what stty would do in real life).
_new_lines=0
_new_cols=0
tuish_update_size () { TUISH_LINES=$_new_lines; TUISH_COLUMNS=$_new_cols; }

# Fixed: shrink pins viewport to row 2 (preserving invocation line)
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=20
_tuish_view_anchor=20
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=20
_tuish_cursor_abs_row=25
# Simulate shrink to 15 lines
_new_lines=15; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
assert_eq "$_tuish_view_origin" "2" "fixed shrink: origin pins to 2"
assert_eq "$_tuish_view_anchor" "2" "fixed shrink: anchor pins to 2"
assert_eq "$TUISH_VIEW_ROWS" "10" "fixed shrink: rows fit (max 10, avail 14)"

# Fixed: shrink clips viewport when terminal very small
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=20
_tuish_view_anchor=20
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=20
_tuish_cursor_abs_row=25
_new_lines=5; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
assert_eq "$_tuish_view_origin" "1" "fixed tiny shrink: origin at 1"
assert_eq "$TUISH_VIEW_ROWS" "10" "fixed tiny shrink: logical rows stay at max"
assert_eq "$_tuish_view_phys" "5" "fixed tiny shrink: physical rows fill screen"

# Fixed: shrink to 1 line uses row 1
_vp_setup
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=20
_tuish_view_anchor=20
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=20
_new_lines=1; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
assert_eq "$_tuish_view_origin" "1" "fixed shrink to 1: origin at 1"
assert_eq "$TUISH_VIEW_ROWS" "10" "fixed shrink to 1: logical rows stay at max"
assert_eq "$_tuish_view_phys" "1" "fixed shrink to 1: 1 physical row visible"

# Fixed: grow does NOT move origin (stays at anchor)
_vp_setup
TUISH_LINES=15
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=2
_tuish_view_anchor=2
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=2
_tuish_cursor_abs_row=8
# Simulate grow to 30
_new_lines=30; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
assert_eq "$_tuish_view_origin" "2" "fixed grow: origin stays at 2"
assert_eq "$TUISH_VIEW_ROWS" "10" "fixed grow: rows restored to max"

# Fixed: shrink+grow cycle keeps viewport stable
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=20
_tuish_view_anchor=20
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=20
_tuish_cursor_abs_row=25
# Shrink
_new_lines=12; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
# Grow back
_new_lines=30; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
assert_eq "$_tuish_view_origin" "2" "fixed shrink+grow: origin stable at 2"
assert_eq "$TUISH_VIEW_ROWS" "10" "fixed shrink+grow: rows restored"

# Fixed: width-only change does not pin to top
_vp_setup
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=15
_tuish_view_anchor=15
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=15
_tuish_precols=80
_new_lines=30; _new_cols=120
_vp_out=''
_tuish_viewport_on_resize
assert_eq "$_tuish_view_origin" "15" "width change: origin unchanged"
assert_eq "$TUISH_VIEW_ROWS" "10" "width change: rows unchanged"

# ─── Tests: overflow control (DECAWM) ────────────────────────────

# fini always restores DECAWM (auto-wrap on)
_vp_setup
_tuish_wrap=0
_vp_out=''
tuish_fini
assert_contains "$_vp_out" '?7h' "fini: restores DECAWM (auto-wrap on)"

# ─── Tests: invocation line preservation on resize ───────────────
# The invocation line sits at terminal row 1.  Resize-down must
# never move the cursor to row 1 or clear it — row 1 is outside
# the viewport and must remain untouched.

# Helper: assert output contains no move to row 1
_assert_no_row1 () {
	_test_total=$((_test_total + 1))
	case "$1" in
		*'[M1,'*)
			_test_fail=$((_test_fail + 1))
			printf '  FAIL: %s (tuish_move to row 1 found)\n' "$2"
			return;;
	esac
	_test_pass=$((_test_pass + 1))
	printf '  PASS: %s\n' "$2"
}

# Fixed shrink: no access to row 1
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=20
_tuish_view_anchor=20
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=20
_tuish_cursor_abs_row=25
_new_lines=15; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
_assert_no_row1 "$_vp_out" "fixed shrink: no row 1 access"
assert_contains "$_vp_out" "[RS]" "fixed shrink: reset scroll at start"
assert_contains "$_vp_out" "[SR2," "fixed shrink: scroll region starts at 2"

# Fixed shrink does NOT clear viewport rows (render handles it)
assert_not_contains "$_vp_out" "[M2,1][CL]" "fixed shrink: no clear at viewport top"

# Fixed tiny shrink: no access to row 1
_vp_setup
TUISH_INIT_ROW=20
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=20
_tuish_view_anchor=20
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=20
_new_lines=5; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
_assert_no_row1 "$_vp_out" "fixed tiny shrink: no row 1 access"

# Width change still clears viewport (no terminal scroll on width-only change)
_vp_setup
TUISH_LINES=30
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=15
_tuish_view_anchor=15
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=15
_tuish_precols=80
_new_lines=30; _new_cols=120
_vp_out=''
_tuish_viewport_on_resize
assert_contains "$_vp_out" "[M15,1][CL]" "width change: clears viewport rows"
_assert_no_row1 "$_vp_out" "width change: no row 1 access"

# Grow shrink: no access to row 1
_vp_setup
TUISH_LINES=30
_tuish_view_mode='grow'
_tuish_view_max=10
_tuish_view_origin=15
_tuish_view_anchor=15
_tuish_view_grow_phase=1
_tuish_view_grow_count=8
TUISH_VIEW_ROWS=8
_tuish_view_phys=8
TUISH_VIEW_TOP=16
_new_lines=12; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
_assert_no_row1 "$_vp_out" "grow shrink: no row 1 access"

# Fixed shrink from near-top origin: row 1 still untouched
_vp_setup
TUISH_INIT_ROW=3
TUISH_LINES=24
_tuish_view_mode='fixed'
_tuish_view_max=10
_tuish_view_origin=3
_tuish_view_anchor=3
TUISH_VIEW_ROWS=10
_tuish_view_phys=10
TUISH_VIEW_TOP=3
_new_lines=8; _new_cols=80
_tuish_precols=80
_vp_out=''
_tuish_viewport_on_resize
_assert_no_row1 "$_vp_out" "fixed shrink near-top: no row 1 access"

# ─── tuish_clamp_scroll (scroll-into-view) ───────────────────────
# Window is [origin, origin+span) in any one unit (rows or columns).

# Already-visible positions: origin unchanged.
tuish_clamp_scroll 5 0 10;  assert_eq "$TUISH_SCROLL" "0"  "clamp: pos inside window -> unchanged"
tuish_clamp_scroll 0 0 10;  assert_eq "$TUISH_SCROLL" "0"  "clamp: pos at near edge -> unchanged"
tuish_clamp_scroll 9 0 10;  assert_eq "$TUISH_SCROLL" "0"  "clamp: pos at far edge -> unchanged"

# Past the far edge: pos lands on the last visible unit.
tuish_clamp_scroll 10 0 10; assert_eq "$TUISH_SCROLL" "1"  "clamp: pos just past window -> origin+1"
tuish_clamp_scroll 25 0 10; assert_eq "$TUISH_SCROLL" "16" "clamp: pos far past -> pos-span+1"

# Before the near edge: pos lands on the first visible unit.
tuish_clamp_scroll 3 10 10; assert_eq "$TUISH_SCROLL" "3"  "clamp: pos before window -> pos"

# Floor at 0 (cannot scroll before the start).
tuish_clamp_scroll 0 5 10;  assert_eq "$TUISH_SCROLL" "0"  "clamp: pos near start -> floored at 0"

# MARGIN keeps context between pos and the edge.
tuish_clamp_scroll 12 0 10 2; assert_eq "$TUISH_SCROLL" "5" "clamp: margin past edge -> pos-span+1+margin"
tuish_clamp_scroll 6 10 10 2; assert_eq "$TUISH_SCROLL" "4" "clamp: margin before edge -> pos-margin"
tuish_clamp_scroll 5 0 10 2;  assert_eq "$TUISH_SCROLL" "0" "clamp: pos inside margin band -> unchanged"

# Oversized MARGIN is clamped so the window can still hold pos.
tuish_clamp_scroll 0 5 4 10;  assert_eq "$TUISH_SCROLL" "0" "clamp: oversized margin clamped, no crash"

# SPAN of 1: only pos is visible.
tuish_clamp_scroll 7 3 1;   assert_eq "$TUISH_SCROLL" "7"  "clamp: span 1 -> origin tracks pos"
tuish_clamp_scroll 3 3 1;   assert_eq "$TUISH_SCROLL" "3"  "clamp: span 1, pos==origin -> unchanged"

# ─── Done ────────────────────────────────────────────────────────

test_summary
