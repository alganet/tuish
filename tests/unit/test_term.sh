#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for term.sh output primitives that are sensitive to how each
# shell's printf/echo parses escape sequences.
#
# Regression coverage for REPORT.md finding #8: DECSC/DECRC are ESC
# followed by a digit, and no single backslash escape survives every
# shell — `\x1b7` becomes hex 0x1b7 on ksh93, `\0337` becomes octal 337
# on mksh, both swallowing the digit. The fix emits a literal ESC byte.
# Run under every target shell to catch a per-shell regression.

set -uf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"

printf 'Unit tests: term.sh output primitives\n'

# Independent reference ESC byte (not via the ord table the code uses).
_esc=$(printf '\033')

# ─── DECSC: ESC 7 ────────────────────────────────────────────────
_out=$( _tuish_buffering=0; tuish_save_cursor )
assert_eq "$_out" "${_esc}7" "save_cursor emits ESC 7 (DECSC)"

# ─── DECRC: ESC 8 ────────────────────────────────────────────────
_out=$( _tuish_buffering=0; tuish_restore_cursor )
assert_eq "$_out" "${_esc}8" "restore_cursor emits ESC 8 (DECRC)"

# ─── Same through the output buffer (begin/flush) ────────────────
# The buffer is flushed with one printf/echo, so the digit must still
# survive when the ESC byte is concatenated with later sequences.
tuish_begin
tuish_save_cursor
_tuish_write '\033[2K'
tuish_restore_cursor
_out=$( tuish_end )
assert_eq "$_out" "${_esc}7${_esc}[2K${_esc}8" "buffered save/clear/restore round-trips"

# ─── Sequence builders: build into TUISH_SEQ (literal ESC), write nothing ──
# The batched-render helpers must (a) use a raw ESC byte so the sequence can be
# embedded in a tuish_print row string, and (b) emit nothing themselves.
tuish_fg_seq 4;            assert_eq "$TUISH_SEQ" "${_esc}[34m"     "fg_seq 4 -> ESC[34m"
tuish_bg_seq 4;            assert_eq "$TUISH_SEQ" "${_esc}[44m"     "bg_seq 4 -> ESC[44m"
tuish_sgr_seq 7;           assert_eq "$TUISH_SEQ" "${_esc}[7m"      "sgr_seq 7 -> ESC[7m"
tuish_sgr_reset_seq;       assert_eq "$TUISH_SEQ" "${_esc}[0m"      "sgr_reset_seq -> ESC[0m"
tuish_style_seq bold fg=1; assert_eq "$TUISH_SEQ" "${_esc}[0;1;31m" "style_seq bold fg=1"
# The plain writer delegates to tuish_style_seq — same bytes, but written out.
_out=$( _tuish_buffering=0; tuish_style bold fg=1 )
assert_eq "$_out" "${_esc}[0;1;31m" "style (writer) emits the style_seq bytes"
_out=$( _tuish_buffering=0; tuish_fg_seq 4 )
assert_eq "$_out" "" "fg_seq writes nothing (only sets TUISH_SEQ)"

# The linchpin: an embedded seq + %-bearing text round-trips through tuish_print
# — the text's % is escaped for the flush printf while the raw-ESC seq passes
# through verbatim (so a batched row of colour + arbitrary text is correct).
tuish_fg_seq 2
_row="${TUISH_SEQ}50%done"
_out=$( _tuish_buffering=0; tuish_print "$_row" )
assert_eq "$_out" "${_esc}[32m50%done" "embedded seq + % text survives tuish_print"

# ─── tuish_put_at: place then print, no width computation ────────
TUISH_LINES=24
_out=$( _tuish_buffering=0; tuish_put_at 1 1 'hi' )
assert_eq "$_out" "${_esc}[1;1Hhi" "put_at places (vmove) then prints"

test_summary
