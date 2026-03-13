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
assert_eq "$_tuish_slen" "5" "str_len: hello"

_t=''
tuish_str_len _t
assert_eq "$_tuish_slen" "0" "str_len: empty"

_t='a'
tuish_str_len _t
assert_eq "$_tuish_slen" "1" "str_len: single char"

_t='hello world'
tuish_str_len _t
assert_eq "$_tuish_slen" "11" "str_len: with space"

_t='abc/def.txt'
tuish_str_len _t
assert_eq "$_tuish_slen" "11" "str_len: with special chars"

# --- tuish_str_left ---
_t='hello world'
tuish_str_left _t 5
assert_eq "$_tuish_sleft" "hello" "str_left: first 5"

_t='hello'
tuish_str_left _t 0
assert_eq "$_tuish_sleft" "" "str_left: 0 chars"

_t='abc'
tuish_str_left _t 3
assert_eq "$_tuish_sleft" "abc" "str_left: full string"

_t='abc'
tuish_str_left _t 1
assert_eq "$_tuish_sleft" "a" "str_left: 1 char"

# --- tuish_str_right ---
_t='hello world'
tuish_str_right _t 6
assert_eq "$_tuish_sright" "world" "str_right: offset 6"

_t='hello'
tuish_str_right _t 0
assert_eq "$_tuish_sright" "hello" "str_right: offset 0"

_t='hello'
tuish_str_right _t 5
assert_eq "$_tuish_sright" "" "str_right: past end"

_t='abcdef'
tuish_str_right _t 3
assert_eq "$_tuish_sright" "def" "str_right: offset 3"

# --- tuish_str_char ---
_t='hello'
tuish_str_char _t 0
assert_eq "$_tuish_schar" "h" "str_char: first"

_t='hello'
tuish_str_char _t 4
assert_eq "$_tuish_schar" "o" "str_char: last"

_t='hello'
tuish_str_char _t 2
assert_eq "$_tuish_schar" "l" "str_char: middle"

_t='a'
tuish_str_char _t 0
assert_eq "$_tuish_schar" "a" "str_char: single char string"

# ─── Byte-mode ASCII fast path tests ─────────────────────────────
# Under LC_ALL=C (byte mode), pure ASCII strings should produce the
# same results as mixed UTF-8 strings.  These tests exercise both
# the fast path (printable ASCII) and slow path (non-ASCII bytes).

# Long ASCII string — exercises fast path for all operations
_t='abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
tuish_str_len _t
assert_eq "$_tuish_slen" "62" "fast path: len of long ASCII"

tuish_str_left _t 10
assert_eq "$_tuish_sleft" "abcdefghij" "fast path: left 10 of long ASCII"

tuish_str_right _t 52
assert_eq "$_tuish_sright" "QRSTUVWXYZ" "fast path: right 52 of long ASCII"

tuish_str_char _t 26
assert_eq "$_tuish_schar" "0" "fast path: char at 26 of long ASCII"

# String with tab (non-printable, triggers slow path)
_tab="$(printf '\t')"
_t="ab${_tab}cd"
tuish_str_len _t
assert_eq "$_tuish_slen" "5" "slow path: len with tab"

tuish_str_left _t 3
assert_eq "$_tuish_sleft" "ab${_tab}" "slow path: left 3 with tab"

tuish_str_right _t 3
assert_eq "$_tuish_sright" "cd" "slow path: right 3 with tab"

tuish_str_char _t 2
assert_eq "$_tuish_schar" "${_tab}" "slow path: char at tab position"

# ASCII string with only printable chars and spaces
_t='hello world 12345 !@#'
tuish_str_len _t
assert_eq "$_tuish_slen" "21" "fast path: len with punctuation"

tuish_str_left _t 12
assert_eq "$_tuish_sleft" "hello world " "fast path: left 12 with spaces"

tuish_str_right _t 18
assert_eq "$_tuish_sright" "!@#" "fast path: right past spaces"

# Edge: empty string (fast path, trivial)
_t=''
tuish_str_len _t
assert_eq "$_tuish_slen" "0" "fast path: len of empty"

tuish_str_left _t 0
assert_eq "$_tuish_sleft" "" "fast path: left 0 of empty"

tuish_str_right _t 0
assert_eq "$_tuish_sright" "" "fast path: right 0 of empty"

# Edge: single char at boundary (printable vs non-printable)
_t='~'   # 0x7E, last printable ASCII
tuish_str_len _t
assert_eq "$_tuish_slen" "1" "fast path: tilde len"

tuish_str_char _t 0
assert_eq "$_tuish_schar" "~" "fast path: tilde char"

test_summary
