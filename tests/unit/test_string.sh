#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for tuish_str_* string utilities

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/str.sh"

_tuish_write () { :; }
tuish_on_event () { :; }

printf 'Unit tests: tuish_str_* string utilities\n'

# --- tuish_str_len ---
_t='hello'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "5" "str_len: hello"

_t=''
tuish_str_len _t
assert_eq "$TUISH_SLEN" "0" "str_len: empty"

_t='a'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "1" "str_len: single char"

_t='hello world'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "11" "str_len: with space"

_t='abc/def.txt'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "11" "str_len: with special chars"

# --- tuish_str_left ---
_t='hello world'
tuish_str_left _t 5
assert_eq "$TUISH_SLEFT" "hello" "str_left: first 5"

_t='hello'
tuish_str_left _t 0
assert_eq "$TUISH_SLEFT" "" "str_left: 0 chars"

_t='abc'
tuish_str_left _t 3
assert_eq "$TUISH_SLEFT" "abc" "str_left: full string"

_t='abc'
tuish_str_left _t 1
assert_eq "$TUISH_SLEFT" "a" "str_left: 1 char"

# --- tuish_str_right ---
_t='hello world'
tuish_str_right _t 6
assert_eq "$TUISH_SRIGHT" "world" "str_right: offset 6"

_t='hello'
tuish_str_right _t 0
assert_eq "$TUISH_SRIGHT" "hello" "str_right: offset 0"

_t='hello'
tuish_str_right _t 5
assert_eq "$TUISH_SRIGHT" "" "str_right: past end"

_t='abcdef'
tuish_str_right _t 3
assert_eq "$TUISH_SRIGHT" "def" "str_right: offset 3"

# --- tuish_str_char ---
_t='hello'
tuish_str_char _t 0
assert_eq "$TUISH_SCHAR" "h" "str_char: first"

_t='hello'
tuish_str_char _t 4
assert_eq "$TUISH_SCHAR" "o" "str_char: last"

_t='hello'
tuish_str_char _t 2
assert_eq "$TUISH_SCHAR" "l" "str_char: middle"

_t='a'
tuish_str_char _t 0
assert_eq "$TUISH_SCHAR" "a" "str_char: single char string"

# ─── Byte-mode ASCII fast path tests ─────────────────────────────
# Under LC_ALL=C (byte mode), pure ASCII strings should produce the
# same results as mixed UTF-8 strings.  These tests exercise both
# the fast path (printable ASCII) and slow path (non-ASCII bytes).

# Long ASCII string — exercises fast path for all operations
_t='abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "62" "fast path: len of long ASCII"

tuish_str_left _t 10
assert_eq "$TUISH_SLEFT" "abcdefghij" "fast path: left 10 of long ASCII"

tuish_str_right _t 52
assert_eq "$TUISH_SRIGHT" "QRSTUVWXYZ" "fast path: right 52 of long ASCII"

tuish_str_char _t 26
assert_eq "$TUISH_SCHAR" "0" "fast path: char at 26 of long ASCII"

# String with tab (non-printable, triggers slow path)
_tab="$(printf '\t')"
_t="ab${_tab}cd"
tuish_str_len _t
assert_eq "$TUISH_SLEN" "5" "slow path: len with tab"

tuish_str_left _t 3
assert_eq "$TUISH_SLEFT" "ab${_tab}" "slow path: left 3 with tab"

tuish_str_right _t 3
assert_eq "$TUISH_SRIGHT" "cd" "slow path: right 3 with tab"

tuish_str_char _t 2
assert_eq "$TUISH_SCHAR" "${_tab}" "slow path: char at tab position"

# ASCII string with only printable chars and spaces
_t='hello world 12345 !@#'
tuish_str_len _t
assert_eq "$TUISH_SLEN" "21" "fast path: len with punctuation"

tuish_str_left _t 12
assert_eq "$TUISH_SLEFT" "hello world " "fast path: left 12 with spaces"

tuish_str_right _t 18
assert_eq "$TUISH_SRIGHT" "!@#" "fast path: right past spaces"

# Edge: empty string (fast path, trivial)
_t=''
tuish_str_len _t
assert_eq "$TUISH_SLEN" "0" "fast path: len of empty"

tuish_str_left _t 0
assert_eq "$TUISH_SLEFT" "" "fast path: left 0 of empty"

tuish_str_right _t 0
assert_eq "$TUISH_SRIGHT" "" "fast path: right 0 of empty"

# Edge: single char at boundary (printable vs non-printable)
_t='~'   # 0x7E, last printable ASCII
tuish_str_len _t
assert_eq "$TUISH_SLEN" "1" "fast path: tilde len"

tuish_str_char _t 0
assert_eq "$TUISH_SCHAR" "~" "fast path: tilde char"

# --- tuish_str_window (horizontal column-window) ---
# ASCII (fast path): column offset == byte offset.
_t='abcdefgh'
tuish_str_window _t 0 4;  assert_eq "$TUISH_SWINDOW" "abcd"     "window: ascii from start"
tuish_str_window _t 2 4;  assert_eq "$TUISH_SWINDOW" "cdef"     "window: ascii offset"
tuish_str_window _t 4 10; assert_eq "$TUISH_SWINDOW" "efgh"     "window: width past end -> tail"
tuish_str_window _t 8 4;  assert_eq "$TUISH_SWINDOW" ""         "window: offset == width -> empty"
tuish_str_window _t 10 4; assert_eq "$TUISH_SWINDOW" ""         "window: offset past end -> empty"
tuish_str_window _t 0 0;  assert_eq "$TUISH_SWINDOW" ""         "window: zero width -> empty"
tuish_str_window _t 0 8;  assert_eq "$TUISH_SWINDOW" "abcdefgh" "window: whole string"
tuish_str_window _t 1 3;  assert_eq "$TUISH_SWINDOW" "bcd"     "window: interior offset"

_t=''
tuish_str_window _t 0 5;  assert_eq "$TUISH_SWINDOW" ""         "window: empty string"

# Wide chars: 'a中b中c' -> columns a=0, 中=1-2, b=3, 中=4-5, c=6 (total width 7).
_t='a中b中c'
tuish_str_window _t 0 3;  assert_eq "$TUISH_SWINDOW" "a中"      "window: wide fully inside"
tuish_str_window _t 1 2;  assert_eq "$TUISH_SWINDOW" "中"       "window: wide aligned to edges"
tuish_str_window _t 0 2;  assert_eq "$TUISH_SWINDOW" "a"        "window: right-straddle wide dropped (result narrower)"
tuish_str_window _t 2 3;  assert_eq "$TUISH_SWINDOW" " b"       "window: left-straddle wide -> leading space"
tuish_str_window _t 3 2;  assert_eq "$TUISH_SWINDOW" "b"        "window: trailing wide right-straddle dropped"

# Combining mark (zero width) follows its visible base, dropped when base off-screen.
# 'a' + U+20DB combining, then 'bc' -> a=col0 (+mark), b=col1, c=col2.
_t='a⃛bc'
tuish_str_window _t 0 2;  assert_eq "$TUISH_SWINDOW" "a⃛b"      "window: combining mark kept with visible base"
tuish_str_window _t 1 2;  assert_eq "$TUISH_SWINDOW" "bc"       "window: combining mark dropped when base scrolled off"

test_summary
