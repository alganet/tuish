#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for redraw scheduling (tuish_request_redraw, tuish_on_redraw)

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"

_captured=''
_tuish_out () { _captured="${_captured}${1:-}"; }
_event_log=''
_redraw_count=0
_redraw_level=''

tuish_on_event () { _event_log="${_event_log}E"; }
tuish_on_redraw () { _redraw_count=$((_redraw_count + 1)); _redraw_level="$1"; _event_log="${_event_log}R"; }

reset_state () {
	TUISH_EVENT=''
	TUISH_EVENT_KIND=''
	TUISH_RAW=''
	TUISH_MOUSE_X=0
	TUISH_MOUSE_Y=0
	_tuish_held=''
	_tuish_redraw_requested=0
	_tuish_redraw_level=0
	_tuish_pending_byte=''
	_event_log=''
	_redraw_count=0
	_redraw_level=''
	_captured=''
}

printf 'Unit tests: redraw scheduling\n'

# --- tuish_request_redraw sets flag ---
reset_state
tuish_request_redraw
assert_eq "$_tuish_redraw_requested" "1" "request_redraw sets flag"

# --- tuish_request_redraw defaults to level -1 ---
reset_state
tuish_request_redraw
assert_eq "$_tuish_redraw_level" "-1" "request_redraw defaults to level -1"

# --- tuish_request_redraw with explicit level ---
reset_state
tuish_request_redraw 2
assert_eq "$_tuish_redraw_requested" "1" "request_redraw 2 sets flag"
assert_eq "$_tuish_redraw_level" "2" "request_redraw 2 sets level"

# --- tuish_request_redraw 0 is a no-op ---
reset_state
tuish_request_redraw 0
assert_eq "$_tuish_redraw_requested" "0" "request_redraw 0 does not set flag"
assert_eq "$_tuish_redraw_level" "0" "request_redraw 0 does not set level"

# --- Level coalescing: higher positive wins ---
reset_state
tuish_request_redraw 1
tuish_request_redraw 3
tuish_request_redraw 2
assert_eq "$_tuish_redraw_level" "3" "higher positive level wins"

# --- Level coalescing: -1 always wins ---
reset_state
tuish_request_redraw 2
tuish_request_redraw
assert_eq "$_tuish_redraw_level" "-1" "-1 wins over positive"

# --- Level coalescing: positive after -1 stays -1 ---
reset_state
tuish_request_redraw
tuish_request_redraw 2
assert_eq "$_tuish_redraw_level" "-1" "-1 sticky over positive"

# --- tuish_cancel_redraw clears flag and level ---
reset_state
tuish_request_redraw 3
tuish_cancel_redraw
assert_eq "$_tuish_redraw_requested" "0" "cancel_redraw clears flag"
assert_eq "$_tuish_redraw_level" "0" "cancel_redraw clears level"

# --- Event without request_redraw flushes normally ---
reset_state
tuish_on_event () { tuish_print "hello"; }
_tuish_parse_event "C a"
assert_contains "$_captured" "hello" "normal event flushes output"

# --- Event with request_redraw: no pending input -> immediate redraw ---
reset_state
_redraw_count=0
tuish_on_event () { tuish_request_redraw; }
tuish_on_redraw () {
	_redraw_count=$((_redraw_count + 1))
	_redraw_level="$1"
	tuish_print "redrawn"
}
_tuish_parse_event "C a"
assert_eq "$_redraw_count" "1" "redraw fires when no pending input"
assert_contains "$_captured" "redrawn" "redraw output is flushed"
assert_eq "$_redraw_level" "-1" "redraw receives level -1"

# --- Redraw level is passed to tuish_on_redraw ---
reset_state
_redraw_level=''
tuish_on_event () { tuish_request_redraw 2; }
tuish_on_redraw () { _redraw_level="$1"; }
_tuish_parse_event "C a"
assert_eq "$_redraw_level" "2" "redraw receives level 2"

# --- Event handler output is discarded when redraw requested ---
reset_state
_captured=''
tuish_on_event () { tuish_print "discard_me"; tuish_request_redraw; }
tuish_on_redraw () { tuish_print "kept"; }
_tuish_parse_event "C a"
# "discard_me" should NOT appear in output, "kept" should
case "$_captured" in
	*discard_me*) assert_eq "found" "not_found" "handler output discarded when redraw requested";;
	*kept*) assert_eq "1" "1" "handler output discarded when redraw requested";;
	*) assert_eq "empty" "kept" "handler output discarded when redraw requested";;
esac

# --- Level resets after redraw fires ---
reset_state
tuish_on_event () { tuish_request_redraw 3; }
tuish_on_redraw () { :; }
_tuish_parse_event "C a"
assert_eq "$_tuish_redraw_level" "0" "level resets after redraw fires"
assert_eq "$_tuish_redraw_requested" "0" "flag resets after redraw fires"

# --- tuish_has_pending_input returns 1 when no input ---
reset_state
if tuish_has_pending_input
then
	assert_eq "pending" "none" "has_pending_input with no input"
else
	assert_eq "1" "1" "has_pending_input returns false when no input"
fi

# --- pending_byte is consumed in loop condition ---
reset_state
_tuish_pending_byte='x'
# Simulate what the loop condition does
if test -n "${_tuish_pending_byte}"
then
	_tuish_byte="$_tuish_pending_byte"
	_tuish_pending_byte=''
fi
assert_eq "$_tuish_byte" "x" "pending byte consumed correctly"
assert_eq "$_tuish_pending_byte" "" "pending byte cleared after consume"

# --- Flushed output survives rAF discard ---
# When tuish_flush is called inside the event handler, that output
# reaches the terminal even though rAF discards the remaining buffer.
reset_state
_captured=''
tuish_on_event () {
	tuish_print "immediate"
	tuish_flush
	tuish_print "deferred"
	tuish_request_redraw 1
}
tuish_on_redraw () { tuish_print "redraw"; }
_tuish_parse_event "C a"
# "immediate" should be in the output (flushed before rAF discard)
assert_contains "$_captured" "immediate" "flush: flushed output survives rAF discard"
# "deferred" should NOT be in the output (written after flush, discarded by rAF)
case "$_captured" in
	*deferred*) assert_eq "found" "not_found" "flush: post-flush output discarded by rAF";;
	*) assert_eq "1" "1" "flush: post-flush output discarded by rAF";;
esac
# "redraw" should be in the output (on_redraw fires after discard)
assert_contains "$_captured" "redraw" "flush: on_redraw still fires after flush"

# --- Flush without redraw request passes all output through ---
reset_state
_captured=''
tuish_on_event () {
	tuish_print "part1"
	tuish_flush
	tuish_print "part2"
}
tuish_on_redraw () { :; }
_tuish_parse_event "C a"
assert_contains "$_captured" "part1" "flush no-rAF: flushed part present"
assert_contains "$_captured" "part2" "flush no-rAF: post-flush part present"

# --- Flush + redraw level 1: level preserved through to on_redraw ---
reset_state
_captured=''
_redraw_level=''
tuish_on_event () {
	tuish_flush
	tuish_request_redraw 2
}
tuish_on_redraw () { _redraw_level="$1"; }
_tuish_parse_event "C a"
assert_eq "$_redraw_level" "2" "flush: redraw level preserved after flush"

test_summary
