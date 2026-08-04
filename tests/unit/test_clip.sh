#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for off-screen draw clipping.
#
# A draw that extends past the bottom of the physical screen must not trip
# `set -e` (compat.sh enables `set -euf`) and abort the redraw, and the trailing
# SGR reset must still be emitted so colors do not leak. Each draw primitive
# guards its writes on tuish_vmove's return (vmove emits nothing and returns
# non-zero when a row is off-screen); there is no global suppression flag.
#
# `set -e` only triggers on a *bare* top-level command, and shells disable it
# inside if/while/&&/|| conditions — so the off-screen scenario cannot be
# observed reliably in-process. Instead we run it as bare statements in a
# child shell (where compat.sh re-arms `set -euf`) and inspect what reaches
# stdout: a finished run prints the trailing marker; an aborted one does not.

set -uf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

SRC="$TESTS_DIR/../src"

printf 'Unit tests: off-screen clipping (errexit + SGR reset)\n'

# Drive every drawing primitive past the bottom of a fake 5-row screen, as
# bare statements under `set -euf`. Output is buffered, so only the explicit
# trailing marker reaches stdout — and only if nothing aborted along the way.
_probe=$(
	{ printf '%s\n' \
		". \"$SRC/compat.sh\"" \
		". \"$SRC/ord.sh\"" \
		". \"$SRC/tui.sh\"" \
		". \"$SRC/term.sh\"" \
		". \"$SRC/str.sh\"" \
		". \"$SRC/draw.sh\"" \
		'TUISH_LINES=5; TUISH_COLUMNS=40; TUISH_VIEW_COLS=40' \
		'TUISH_VIEW_TOP=1; _tuish_wrap=0' \
		'tuish_begin' \
		'tuish_draw_box 1 1 10 8 fg=2 bg=4' \
		'_boxbuf="$_tuish_buf"' \
		'tuish_begin' \
		'tuish_draw_vline 1 1 12 fg=3' \
		'tuish_draw_hline 9 1 10' \
		'tuish_draw_text 9 1 hi fg=1' \
		'tuish_draw_hdiv 9 1 10' \
		'tuish_draw_vdiv 1 1 12' \
		'tuish_clear_region 1 1 4 9' \
		'tuish_print_at 9 1 x' \
		'printf "%s@@DONE" "$_boxbuf"' \
	; } | sh 2>/dev/null
) || :

# ─── Nothing aborted — the trailing marker survived ──────────────
case "$_probe" in
	*DONE) _reached=yes;;
	*)     _reached=no;;
esac
assert_eq "$_reached" "yes" "box/vline/hline/text/hdiv/vdiv/clear_region/print_at past bottom: no errexit abort"

# ─── The off-bottom box's trailing SGR reset was still emitted ────
case "$_probe" in
	*'\033[0m@@DONE') _ends_reset=yes;;
	*)                _ends_reset=no;;
esac
assert_eq "$_ends_reset" "yes" "box past bottom: buffer ends with SGR reset (no color leak)"

# ─── Sanity: a fully on-screen colored box still ends with a reset ──
# (In-process is safe here: nothing clips, so no abort is possible.)
. "$SRC/compat.sh"; . "$SRC/ord.sh"; . "$SRC/tui.sh"
. "$SRC/term.sh";   . "$SRC/str.sh"; . "$SRC/draw.sh"
TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=80
TUISH_VIEW_TOP=1; _tuish_wrap=0
tuish_begin
tuish_draw_box 1 1 6 3 fg=2 bg=4
_cap="$_tuish_buf"; _tuish_buf=''; _tuish_buffering=0
case "$_cap" in
	*'\033[0m') _ok=yes;;
	*)          _ok=no;;
esac
assert_eq "$_ok" "yes" "on-screen box: still ends with SGR reset"

# ─── A clipped vmove emits nothing and returns non-zero ──────────
tuish_begin
tuish_vmove 999 1 && _vc=0 || _vc=1
assert_eq "$_vc" "1" "off-bottom vmove returns non-zero"
tuish_print 'X'
# The print after a clipped vmove is NOT suppressed (no global guard) — the
# caller decides via the return value; print on its own always writes.
case "$_tuish_buf" in *X*) _wrote=yes;; *) _wrote=no;; esac
assert_eq "$_wrote" "yes" "print after clipped vmove writes (no implicit suppression)"
_tuish_buf=''; _tuish_buffering=0

# ─── Right-edge clip: content stops at the visible region edge, not the screen ──
# The bleed bug: writes clamped to TUISH_VIEW_COLS (region full width) or not at all,
# so a hosted child's over-wide row ran to the physical screen edge. Now every
# region-aware write clips to min(TUISH_VIEW_COLS, _tx_lcmax) via _tuish_clip_avail.
_count_char () {   # $1 string $2 char -> _cc = occurrences of char in string
	_cc=0; _s=$1
	while case "$_s" in *"$2"*) true;; *) false;; esac
	do _s=${_s#*"$2"}; _cc=$((_cc + 1)); done
}
ESC=$(printf '\033')
_sixtyA=''; _i=0; while test $_i -lt 60; do _sixtyA="${_sixtyA}A"; _i=$((_i + 1)); done

TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=40; TUISH_VIEW_TOP=1; _tuish_wrap=0
_tuish_tx_reset            # no sub-clip: _tx_lcmax defaults wide, so clip == VIEW_COLS

tuish_begin; _tuish_buf=''
tuish_text 1 1 "$_sixtyA"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "40" "tuish_text: 60-col string clipped to region width 40"

tuish_begin; _tuish_buf=''
tuish_clear_region 1 1 60 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "40" "tuish_clear_region: width 60 clamped to region width 40"

# SGR-bearing row: clipped to 40 visible cells (escape bytes not miscounted), and a
# forced trailing reset closes the run whose own reset fell past the cut. tuish emits
# its own escapes as the literal string \033[…m (expanded at flush), so match that.
tuish_begin; _tuish_buf=''
tuish_text 1 1 "${ESC}[31m${_sixtyA}${ESC}[0m"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "40" "tuish_text SGR row: clipped to 40 visible cells (escapes not counted)"
case "$_tuish_buf" in *'\033[0m') _sgr_reset=yes;; *) _sgr_reset=no;; esac
assert_eq "$_sgr_reset" "yes" "tuish_text SGR row: ends with reset (no colour leak into chrome)"

# Scroll-under-pane: a visible clip narrower than the region (_tx_lcmax < VIEW_COLS).
# Previously bled to VIEW_COLS=40; must now stop at the visible window (20).
tuish_begin; _tuish_buf=''; _tx_lcmax=20
tuish_text 1 1 "$_sixtyA"
_count_char "$_tuish_buf" A
assert_eq "$_cc" "20" "tuish_text: clips to the visible window (_tx_lcmax=20), not region 40"

tuish_begin; _tuish_buf=''; _tx_lcmax=20
tuish_clear_region 1 1 60 1
_count_char "$_tuish_buf" ' '
assert_eq "$_cc" "20" "tuish_clear_region: clamps to the visible window (_tx_lcmax=20)"
_tuish_tx_reset
_tuish_buf=''; _tuish_buffering=0

# ─── The SGR path and the plain path clip a scrolled field identically ─────────
# A left-scrolled fixed-width field (COL < 1 plus maxwidth) is the one call shape
# where the two paths could disagree: maxwidth counts from the string's own start,
# so trimming the scrolled-off head has to come out of it. 10 cells of budget minus
# 4 scrolled off the left = 6 drawn — whether or not the row carries colour.
tuish_begin; _tuish_buf=''
tuish_text 1 -3 "$_sixtyA" maxwidth=10
_count_char "$_tuish_buf" A
assert_eq "$_cc" "6" "tuish_text plain: maxwidth counts the head scrolled off the left"

tuish_begin; _tuish_buf=''
tuish_text 1 -3 "${ESC}[31m${_sixtyA}${ESC}[0m" maxwidth=10
_count_char "$_tuish_buf" A
assert_eq "$_cc" "6" "tuish_text SGR: same cells as the plain path for the same call"

# An OSC (ESC ']' … ST) is not a CSI, so it stays on the plain path — which also
# means no forced trailing reset. Keying the escape path on ESC alone would fire it
# here and clobber an attribute the caller set around the call (the `tuish_bold;
# tuish_text …` idiom), for a sequence the CSI-only window cannot skip anyway.
tuish_begin; _tuish_buf=''
tuish_text 1 1 "${ESC}]0;title${ESC}\\ok"
case "$_tuish_buf" in *"0;title"*) _osc=kept;; *) _osc=mangled;; esac
assert_eq "$_osc" "kept" "tuish_text: a non-CSI escape reaches the terminal intact"
case "$_tuish_buf" in *'\033[0m') _osc_reset=yes;; *) _osc_reset=no;; esac
assert_eq "$_osc_reset" "no" "tuish_text: a non-CSI escape forces no trailing reset"
_tuish_buf=''; _tuish_buffering=0

test_summary
