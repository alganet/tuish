#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for the canvas: tuish_canvas / tuish_canvas_off and the canvas
# branch of tuish_vmove. We mock _tuish_write (one layer below the REAL vmove)
# and assert the exact cursor-move escape it emits, plus the 4-edge clip and the
# no-canvas hot-path parity.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/canvas.sh"

# Capture the move escape instead of writing to a terminal.
_emit=''
_tuish_write () { _emit="$1"; }

TUISH_LINES=50          # generous: physical-bottom clip won't interfere
TUISH_VIEW_TOP=1

printf 'Unit tests: canvas (tuish_canvas + tuish_vmove canvas branch)\n'

# move that should succeed: assert the emitted escape
vmove_eq () { _emit=''; tuish_vmove "$1" "$2" || :; assert_eq "$_emit" "$3" "$4"; }
# move that should clip: assert nothing emitted + clip flag set
vmove_clip () {
	_emit='__none__'
	if tuish_vmove "$1" "$2"; then :; fi
	assert_eq "$_emit" '__none__' "$3 (suppressed)"
	assert_eq "$_tuish_clipped" '1' "$3 (clip flag)"
}
# assert haystack contains needle
assert_in () { case "$1" in *"$2"*) assert_eq 1 1 "$3";; *) assert_eq "missing:$2" "present" "$3";; esac; }

# ─── Hot-path parity: no canvas active = unchanged behavior ───────
tuish_canvas_off
vmove_eq 1 1 '\033[1;1H' "parity: vmove 1 1 @ VIEW_TOP=1"
vmove_eq 3 5 '\033[3;5H' "parity: vmove 3 5 @ VIEW_TOP=1"
TUISH_VIEW_TOP=5
vmove_eq 1 1 '\033[5;1H' "parity: vmove 1 1 @ VIEW_TOP=5"
vmove_eq 2 4 '\033[6;4H' "parity: vmove 2 4 @ VIEW_TOP=5"
TUISH_VIEW_TOP=1
# bottom clip (physical) still works with no canvas
TUISH_LINES=10
vmove_clip 11 1 "parity: row past TUISH_LINES clips"
TUISH_LINES=50

# ─── Canvas identity (R=1,C=1,W=10,H=5,1x1) == viewport coords ────
tuish_canvas 1 1 10 5
assert_eq "$TUISH_CANVAS"    '1'  "canvas: TUISH_CANVAS=1 when active"
assert_eq "$TUISH_CANVAS_W"  '10' "canvas: TUISH_CANVAS_W"
assert_eq "$TUISH_CANVAS_H"  '5'  "canvas: TUISH_CANVAS_H"
assert_eq "$TUISH_CANVAS_CW" '1'  "canvas: default cell width 1"
vmove_eq 1 1  '\033[1;1H'   "canvas identity: top-left"
vmove_eq 5 10 '\033[5;10H'  "canvas identity: bottom-right cell"

# ─── Nested origin (R=3,C=5) ─────────────────────────────────────
tuish_canvas 3 5 4 3
vmove_eq 1 1 '\033[3;5H' "canvas origin: local (1,1) -> viewport (3,5)"
vmove_eq 3 4 '\033[5;8H' "canvas origin: local (3,4) -> (5,8)"

# ─── Origin composes with a fixed viewport (VIEW_TOP=5) ───────────
TUISH_VIEW_TOP=5
tuish_canvas 2 1 4 3
vmove_eq 1 1 '\033[6;1H' "canvas+viewport: local (1,1) -> absolute row 6"
vmove_eq 3 4 '\033[8;4H' "canvas+viewport: local (3,4) -> absolute (8,4)"
TUISH_VIEW_TOP=1

# ─── Cell scaling: CW=2 (emoji grid) ─────────────────────────────
tuish_canvas 1 1 5 3 2
assert_eq "$TUISH_CANVAS_CW" '2' "canvas: cell width 2 recorded"
vmove_eq 1 1 '\033[1;1H' "cell cw=2: col 1 -> term 1"
vmove_eq 1 3 '\033[1;5H' "cell cw=2: col 3 -> term 5"
vmove_eq 2 5 '\033[2;9H' "cell cw=2: (2,5) -> (2,9)"

# ─── Cell scaling: CH=2 ──────────────────────────────────────────
tuish_canvas 1 1 3 3 1 2
vmove_eq 2 1 '\033[3;1H' "cell ch=2: row 2 -> term row 3"
vmove_eq 3 2 '\033[5;2H' "cell ch=2: row 3 -> term row 5"

# ─── 4-edge clipping (R=1,C=1,W=10,H=5) ──────────────────────────
tuish_canvas 1 1 10 5
vmove_clip 0  1  "clip top: row 0"
vmove_clip -1 1  "clip top: row -1"
vmove_clip 6  1  "clip bottom: row > H"
vmove_clip 1  0  "clip left: col 0"
vmove_clip 1  11 "clip right: col > W"
vmove_eq   5 10 '\033[5;10H' "edge: last in-bounds cell is NOT clipped"

# ─── Clip-guard interaction with tuish_print suppression ─────────
# A clipped move sets _tuish_clipped=1 so the following write is dropped.
if tuish_vmove 99 1; then :; fi
assert_eq "$_tuish_clipped" '1' "guard: out-of-bounds move sets clip flag"
tuish_vmove 1 1 || :
assert_eq "$_tuish_clipped" '0' "guard: in-bounds move clears clip flag"

# ─── canvas_off returns to plain viewport coordinates ────────────
tuish_canvas_off
assert_eq "$TUISH_CANVAS" '0' "canvas_off: TUISH_CANVAS=0"
vmove_eq 3 5 '\033[3;5H' "canvas_off: plain viewport coords restored"

# ─── tuish_canvas_clear: wipes the canvas region, re-arms the canvas ──
# Canvas at viewport (2,3), 4x3 cells, CW=2 -> an 8-col x 3-row region. Clearing
# must move to viewport rows 2,3,4 at col 3 (canvas off, so plain coords) and
# emit W*CW=8 spaces per row, then leave the canvas active again.
_clearlog=''
_tuish_write () { _clearlog="${_clearlog}${1}"; }
tuish_canvas 2 3 4 3 2
tuish_canvas_clear
assert_eq "$_tuish_canvas_on" '1'        "canvas_clear: canvas re-armed afterward"
assert_in "$_clearlog" '\033[2;3H'       "canvas_clear: clears top row (vp 2, col 3)"
assert_in "$_clearlog" '\033[4;3H'       "canvas_clear: clears bottom row (vp 4, col 3)"
assert_in "$_clearlog" '        '        "canvas_clear: emits W*CW=8 spaces per row"
_tuish_write () { _emit="$1"; }

test_summary
