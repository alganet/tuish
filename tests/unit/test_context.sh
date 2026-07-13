#!/bin/sh

# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: ISC

# Unit tests for the context system (src/tui.sh): region seating, the region-safe
# erase, and the cooperative idle-tick negotiation.
#
# These run WITHOUT a terminal: tuish_init is never called, so no device comes up.
# We build contexts by hand (tuish_ctx_create + _tuish_ctx_seat via
# tuish_ctx_create_region) and drive the marshalling directly. The negotiation math
# is pure integer arithmetic on per-context registers, which is exactly what we want
# pinned — the live behaviour is covered by tests/integration/test_cooperative.sh.

set -euf

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$TESTS_DIR/lib/test_framework.sh"

. "$TESTS_DIR/../src/compat.sh"
. "$TESTS_DIR/../src/ord.sh"
. "$TESTS_DIR/../src/tui.sh"
. "$TESTS_DIR/../src/term.sh"
. "$TESTS_DIR/../src/event.sh"
. "$TESTS_DIR/../src/hid.sh"
. "$TESTS_DIR/../src/viewport.sh"
. "$TESTS_DIR/../src/str.sh"
. "$TESTS_DIR/../src/keybind.sh"

printf 'Unit tests: contexts, regions, idle negotiation\n'

TUISH_LINES=30
TUISH_COLUMNS=100

# The root context, without bringing up the device.
tuish_ctx_create
TUISH_CTX_ROOT=$TUISH_CTX
tuish_ctx_activate "$TUISH_CTX_ROOT"
tuish_viewport fullscreen >/dev/null 2>&1 || :

# --- Region seating ----------------------------------------------------------
# A child seated at row 5, col 20, 30x10 gets its own origin and bounds; the root
# is untouched. Column origin is 0-based (TUISH_VIEW_LEFT), row origin 1-based.
tuish_ctx_create_region 5 20 30 10
_child=$TUISH_CTX
assert_eq "$TUISH_VIEW_TOP"  "5"  "region: view top is the region row"
assert_eq "$TUISH_VIEW_LEFT" "19" "region: view left is the 0-based region column"
assert_eq "$TUISH_VIEW_COLS" "30" "region: view cols is the region width"
assert_eq "$TUISH_VIEW_ROWS" "10" "region: view rows is the region height"
assert_eq "$_tuish_hosted"   "1"  "region: child is marked hosted"

tuish_ctx_activate "$TUISH_CTX_ROOT"
assert_eq "$_tuish_hosted"   "0"  "region: the root is NOT hosted"
assert_eq "$TUISH_VIEW_LEFT" "0"  "region: the root keeps column origin 0"

# --- Re-seating (tuish_ctx_reseat) -------------------------------------------
# The host moves the child's rectangle (a resize relayout). Formerly every host
# hand-copied this field poking; it now lives in the library.
tuish_ctx_reseat "$_child" 8 40 12 6
assert_eq "$_tuish_ctx_active" "$TUISH_CTX_ROOT" "reseat: the host stays active"
tuish_ctx_activate "$_child"
assert_eq "$TUISH_VIEW_TOP"  "8"  "reseat: new row origin"
assert_eq "$TUISH_VIEW_LEFT" "39" "reseat: new column origin"
assert_eq "$TUISH_VIEW_COLS" "12" "reseat: new width"
assert_eq "$TUISH_VIEW_ROWS" "6"  "reseat: new height"
assert_eq "$_tuish_rgn_cols" "12" "reseat: region width tracks the viewport"
tuish_ctx_activate "$TUISH_CTX_ROOT"

# --- Region-safe erase (tuish_clear_to_edge) ---------------------------------
# tuish_clear_to_eol emits ESC[K, which erases to the end of the PHYSICAL line and
# therefore punches out of a hosted region into the host's chrome. tuish_clear_to_edge
# is bounded by the drawable width. Capture what each one writes.
tuish_ctx_activate "$_child"      # a 12-wide region at column 40
_tuish_buffering=1; _tuish_buf=''
tuish_clear_to_eol
assert_eq "$_tuish_buf" '\033[K' "clear_to_eol: still the raw ESC[K (unbounded)"

_tuish_buf=''
tuish_clear_to_edge 1
# Expect: position at the region's first cell, then exactly VIEW_COLS spaces.
_spaces='            '                     # 12
assert_eq "$_tuish_buf" "\\033[8;40H${_spaces}" \
	"clear_to_edge: writes exactly VIEW_COLS spaces inside the region (no ESC[K)"

_tuish_buf=''
tuish_clear_to_edge 1 5
_spaces8='        '                        # 12 - 5 + 1 = 8
assert_eq "$_tuish_buf" "\\033[8;44H${_spaces8}" \
	"clear_to_edge: honours a start column, still bounded by the region"
_tuish_buffering=0; _tuish_buf=''
tuish_ctx_activate "$TUISH_CTX_ROOT"

# --- Idle-tick negotiation ---------------------------------------------------
# The rules: the host must poll at the FASTEST child's rate (so the fast child is not
# slowed), and each child must only be driven once ITS OWN interval has elapsed (so
# the slow child is not sped up).
TUISH_TIMING=sub

_fast_n=0
_slow_n=0
_mk () { tuish_idle_interval "$1"; tuish_bind 'idle' "$2"; tuish_bind '*' ':'; }

tuish_ctx_create_region 1 1 10 5
_fast=$TUISH_CTX
_mk 0.02 '_fast_n=$((_fast_n + 1))'          # a 50Hz game
tuish_ctx_activate "$TUISH_CTX_ROOT"

tuish_ctx_create_region 1 20 10 5
_slow=$TUISH_CTX
_mk 1 '_slow_n=$((_slow_n + 1))'             # a 1Hz clock
tuish_ctx_activate "$TUISH_CTX_ROOT"

eval "_fu=\$_tuish_ctx_${_fast}_TUISH_TICK_US"
eval "_su=\$_tuish_ctx_${_slow}_TUISH_TICK_US"
assert_eq "$_fu" "20000"   "negotiation: the fast child asked for 20ms"
assert_eq "$_su" "1000000" "negotiation: the slow child asked for 1s"

tuish_idle_interval 0.26                     # the host's own lazy default
tuish_ctx_sync_interval "$_fast" "$_slow"
assert_eq "$TUISH_TICK_US" "20000" \
	"negotiation: the host adopts the FASTEST child's tick (not its own, not the slowest)"

# Drive 100 host ticks = 2.0s of virtual time at the negotiated 20ms.
_i=0
while test $_i -lt 100
do
	TUISH_RAW='F'; TUISH_EVENT='idle'; TUISH_EVENT_KIND='idle'
	tuish_ctx_tick "$_fast"
	tuish_ctx_tick "$_slow"
	_i=$((_i + 1))
done
assert_eq "$_fast_n" "100" \
	"negotiation: the fast child fires every host tick (not slowed by a slow sibling)"
assert_eq "$_slow_n" "2" \
	"negotiation: the slow child fires once per second (not sped up by a fast sibling)"

test_summary
