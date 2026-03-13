#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for tuish_str_width display width

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/str.sh"

_tuish_write () { :; }
tuish_on_event () { :; }

printf 'Unit tests: tuish_str_width display width\n'

# --- ASCII ---
_t='hello'
tuish_str_width _t
assert_eq "$_tuish_swidth" "5" "width: ASCII hello"

_t=''
tuish_str_width _t
assert_eq "$_tuish_swidth" "0" "width: empty string"

_t='a'
tuish_str_width _t
assert_eq "$_tuish_swidth" "1" "width: single ASCII"

_t='hello world'
tuish_str_width _t
assert_eq "$_tuish_swidth" "11" "width: ASCII with space"

_t='@#%^&()+='
tuish_str_width _t
assert_eq "$_tuish_swidth" "9" "width: ASCII punctuation"

# --- CJK ideographs (each 2 columns) ---
_t='中'
tuish_str_width _t
assert_eq "$_tuish_swidth" "2" "width: single CJK"

_t='中文'
tuish_str_width _t
assert_eq "$_tuish_swidth" "4" "width: two CJK"

_t='日本語'
tuish_str_width _t
assert_eq "$_tuish_swidth" "6" "width: three CJK (Japanese)"

# --- Mixed ASCII + CJK ---
_t='hi中文'
tuish_str_width _t
assert_eq "$_tuish_swidth" "6" "width: mixed ASCII+CJK"

_t='中a文b'
tuish_str_width _t
assert_eq "$_tuish_swidth" "6" "width: interleaved CJK+ASCII"

# --- Fullwidth Latin (U+FF01-U+FF60) ---
_t='Ａ'
tuish_str_width _t
assert_eq "$_tuish_swidth" "2" "width: fullwidth A"

# --- Hangul ---
_t='한'
tuish_str_width _t
assert_eq "$_tuish_swidth" "2" "width: Hangul syllable"

_t='한글'
tuish_str_width _t
assert_eq "$_tuish_swidth" "4" "width: two Hangul syllables"

# --- Latin accented (1 column each) ---
_t='café'
tuish_str_width _t
assert_eq "$_tuish_swidth" "4" "width: Latin accented"

_t='über'
tuish_str_width _t
assert_eq "$_tuish_swidth" "4" "width: Latin umlaut"

test_summary
