#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for off-screen draw clipping.
#
# Regression coverage for REPORT.md finding #1 / #1b:
#   - A draw that extends past the bottom of the physical screen must not
#     trip `set -e` (compat.sh enables `set -euf`) and abort the redraw.
#   - The trailing SGR reset must still be emitted so colors do not leak,
#     and the clip flag must be left clean for the next primitive.
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
# trailing markers reach stdout — and only if nothing aborted along the way.
_probe=$(
	{ printf '%s\n' \
		". \"$SRC/compat.sh\"" \
		". \"$SRC/ord.sh\"" \
		". \"$SRC/tui.sh\"" \
		". \"$SRC/term.sh\"" \
		". \"$SRC/str.sh\"" \
		". \"$SRC/draw.sh\"" \
		'TUISH_LINES=5; TUISH_COLUMNS=40; TUISH_VIEW_COLS=40' \
		'TUISH_VIEW_TOP=1; _tuish_wrap=0; _tuish_clipped=0' \
		'tuish_begin' \
		'tuish_draw_box 1 1 10 8 fg=2 bg=4' \
		'_boxbuf="$_tuish_buf"; _clip="$_tuish_clipped"' \
		'_tuish_clipped=0; tuish_begin' \
		'tuish_draw_vline 1 1 12 fg=3' \
		'tuish_draw_hline 9 1 10' \
		'tuish_draw_text 9 1 hi fg=1' \
		'tuish_draw_hdiv 9 1 10' \
		'tuish_draw_vdiv 1 1 12' \
		'tuish_clear_region 1 1 4 9' \
		'tuish_print_at 9 1 x' \
		'printf "%s@@CLIP=%s@@DONE" "$_boxbuf" "$_clip"' \
	; } | sh 2>/dev/null
) || :

# ─── #1: nothing aborted — the trailing marker survived ──────────
case "$_probe" in
	*DONE) _reached=yes;;
	*)     _reached=no;;
esac
assert_eq "$_reached" "yes" "box/vline/hline/text/hdiv/vdiv/clear_region/print_at past bottom: no errexit abort"

# ─── #1b: the off-bottom box's trailing SGR reset was still emitted ─
case "$_probe" in
	*'\033[0m@@CLIP='*) _ends_reset=yes;;
	*)                  _ends_reset=no;;
esac
assert_eq "$_ends_reset" "yes" "box past bottom: buffer ends with SGR reset (no color leak)"

# ─── #1b: the clip flag was left clean for the next primitive ──────
case "$_probe" in
	*'@@CLIP=0@@'*) _clip_clean=yes;;
	*)             _clip_clean=no;;
esac
assert_eq "$_clip_clean" "yes" "box past bottom: clip flag reset on exit"

# ─── Sanity: a fully on-screen colored box still ends with a reset ──
# (In-process is safe here: nothing clips, so no abort is possible.)
. "$SRC/compat.sh"; . "$SRC/ord.sh"; . "$SRC/tui.sh"
. "$SRC/term.sh";   . "$SRC/str.sh"; . "$SRC/draw.sh"
TUISH_LINES=24; TUISH_COLUMNS=80; TUISH_VIEW_COLS=80
TUISH_VIEW_TOP=1; _tuish_wrap=0; _tuish_clipped=0
tuish_begin
tuish_draw_box 1 1 6 3 fg=2 bg=4
_cap="$_tuish_buf"; _tuish_buf=''; _tuish_buffering=0
case "$_cap" in
	*'\033[0m') _ok=yes;;
	*)          _ok=no;;
esac
assert_eq "$_ok" "yes" "on-screen box: still ends with SGR reset"

test_summary
