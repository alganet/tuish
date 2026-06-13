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
_out=$( _tuish_buffering=0; _tuish_clipped=0; tuish_save_cursor )
assert_eq "$_out" "${_esc}7" "save_cursor emits ESC 7 (DECSC)"

# ─── DECRC: ESC 8 ────────────────────────────────────────────────
_out=$( _tuish_buffering=0; _tuish_clipped=0; tuish_restore_cursor )
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

test_summary
